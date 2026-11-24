-- QueueFlow BD: core schema, security, concurrency. Run in Supabase SQL editor.

create type business_status as enum ('pending','approved','rejected','suspended');
create type booking_status  as enum ('waiting','called','serving','completed','cancelled','skipped');
create type member_role     as enum ('owner','manager','staff');

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text not null default '',
  phone text,
  is_admin boolean not null default false,   -- only changeable via SQL by a DB owner
  is_suspended boolean not null default false,
  created_at timestamptz not null default now()
);
create table categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);
create table businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id),
  category_id uuid references categories(id),
  name text not null check (char_length(name) between 2 and 100),
  description text, address text, phone text, logo_url text,
  opening_hours jsonb not null default '{}',   -- {"mon":["09:00","18:00"],...}
  status business_status not null default 'pending',
  queue_paused boolean not null default false,
  created_at timestamptz not null default now()
);
create table business_members (
  business_id uuid references businesses(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  role member_role not null,
  primary key (business_id, user_id)
);
create table services (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null, price numeric(10,2) not null check (price >= 0),
  duration_min int not null check (duration_min between 1 and 480),
  is_active boolean not null default true
);
create table counters (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  name text not null, staff_id uuid references profiles(id),
  is_active boolean not null default true
);
create table queue_sequences (               -- one row per business per day: the token counter
  business_id uuid references businesses(id) on delete cascade,
  service_date date not null,
  last_token int not null default 0,
  primary key (business_id, service_date)
);
create table bookings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id),
  service_id uuid not null references services(id),
  customer_id uuid not null references profiles(id),
  counter_id uuid references counters(id),
  token_number int not null,
  service_date date not null default current_date,
  appointment_time time,                      -- null = walk-in queue
  status booking_status not null default 'waiting',
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  called_at timestamptz, started_at timestamptz, completed_at timestamptz,
  unique (business_id, service_date, token_number),      -- no duplicate tokens
  unique (customer_id, idempotency_key)                  -- no duplicate requests
);
-- One ACTIVE booking per appointment slot
create unique index uq_active_slot on bookings (business_id, service_date, appointment_time)
  where appointment_time is not null and status in ('waiting','called','serving');
create index idx_bookings_queue on bookings (business_id, service_date, status, token_number);
create index idx_bookings_customer on bookings (customer_id, created_at desc);

create table queue_events (
  id bigint generated always as identity primary key,
  booking_id uuid not null references bookings(id) on delete cascade,
  business_id uuid not null references businesses(id),
  actor_id uuid, from_status booking_status, to_status booking_status not null,
  created_at timestamptz not null default now()
);
create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null, body text, is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- ============ Helper functions (server-side permission checks) ============
create function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select coalesce((select is_admin and not is_suspended from profiles where id = auth.uid()), false) $$;

create function can_manage(b uuid, roles member_role[] default '{owner,manager,staff}') returns boolean
language sql stable security definer set search_path=public as
$$ select is_admin() or exists (select 1 from business_members
   where business_id = b and user_id = auth.uid() and role = any(roles)) $$;

-- New auth user -> profile. is_admin is NEVER taken from user-supplied metadata.
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as
$$ begin
  insert into profiles(id, full_name) values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''));
  return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Owner automatically becomes a member
create function add_owner_member() returns trigger language plpgsql security definer set search_path=public as
$$ begin insert into business_members values (new.id, new.owner_id, 'owner'); return new; end $$;
create trigger trg_owner_member after insert on businesses for each row execute function add_owner_member();

-- ============ ATOMIC BOOKING (token + idempotency + slot protection) ============
create function create_booking(p_business uuid, p_service uuid, p_idem text, p_time time default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare v_token int; v_row bookings; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id=v_uid and is_suspended) then raise exception 'Account suspended'; end if;
  if p_idem is null or length(p_idem) < 8 then raise exception 'Idempotency key required'; end if;

  -- Repeated request? return the original booking, create nothing.
  select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
  if found then return v_row; end if;

  if not exists (select 1 from businesses where id=p_business and status='approved' and not queue_paused)
    then raise exception 'Business is not accepting bookings'; end if;
  if not exists (select 1 from services where id=p_service and business_id=p_business and is_active)
    then raise exception 'Invalid service'; end if;

  begin  -- sub-transaction: if the slot/idempotency insert fails, the token increment rolls back too
    -- ON CONFLICT DO UPDATE takes a row lock, so concurrent callers are serialized and get distinct tokens.
    insert into queue_sequences(business_id, service_date, last_token) values (p_business, current_date, 1)
      on conflict (business_id, service_date) do update set last_token = queue_sequences.last_token + 1
      returning last_token into v_token;

    insert into bookings(business_id, service_id, customer_id, token_number, appointment_time, idempotency_key)
      values (p_business, p_service, v_uid, v_token, p_time, p_idem) returning * into v_row;
  exception
    when unique_violation then
      select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
      if found then return v_row; end if;          -- lost a race with our own duplicate request
      raise exception 'That appointment slot was just taken' using errcode='23505';
  end;

  insert into queue_events(booking_id,business_id,actor_id,to_status) values (v_row.id,p_business,v_uid,'waiting');
  insert into notifications(user_id,title,body) values (v_uid,'Booking confirmed','Your token is #'||v_token);
  return v_row;
end $$;

-- ============ STATE MACHINE ============
-- actions: call, start, complete, skip, recall, cancel
create function transition_booking(p_booking uuid, p_action text, p_counter uuid default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare b bookings; v_new booking_status; v_old booking_status; v_staff boolean;
begin
  select * into b from bookings where id=p_booking for update;     -- row lock: no conflicting staff actions
  if not found then raise exception 'Booking not found'; end if;
  v_staff := can_manage(b.business_id);
  v_old := b.status;

  v_new := case
    when p_action='call'     and b.status='waiting' then 'called'
    when p_action='start'    and b.status='called'  then 'serving'
    when p_action='complete' and b.status='serving' then 'completed'
    when p_action='skip'     and b.status in ('waiting','called') then 'skipped'
    when p_action='recall'   and b.status='skipped' then 'waiting'
    when p_action='cancel'   and b.status='waiting' then 'cancelled'
    else null end;
  if v_new is null then raise exception 'Invalid transition: % from %', p_action, b.status; end if;

  if p_action='cancel' then
    if not (v_staff or b.customer_id = auth.uid()) then raise exception 'Not allowed'; end if;
  elsif not v_staff then raise exception 'Not allowed'; end if;

  update bookings set status=v_new,
    counter_id = coalesce(p_counter, counter_id),
    called_at    = case when v_new='called'    then now() else called_at end,
    started_at   = case when v_new='serving'   then now() else started_at end,
    completed_at = case when v_new='completed' then now() else completed_at end
  where id=b.id returning * into b;

  insert into queue_events(booking_id,business_id,actor_id,from_status,to_status)
    values (b.id,b.business_id,auth.uid(),v_old,v_new);
  insert into notifications(user_id,title) values (b.customer_id,
    case v_new when 'called' then 'It''s your turn! Token #'||b.token_number
               when 'completed' then 'Service completed' when 'cancelled' then 'Booking cancelled'
               when 'skipped' then 'You were skipped' else 'Status: '||v_new end);
  return b;
end $$;

-- Call the next waiting customer; SKIP LOCKED means two staff never grab the same person.
create function call_next(p_business uuid, p_counter uuid default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not can_manage(p_business) then raise exception 'Not allowed'; end if;
  select id into v_id from bookings where business_id=p_business and service_date=current_date and status='waiting'
    order by token_number limit 1 for update skip locked;
  if v_id is null then raise exception 'No customers waiting'; end if;
  return transition_booking(v_id,'call',p_counter);
end $$;

-- Safe public display data (no private customer info)
create function get_public_queue(p_business uuid) returns json language sql stable security definer set search_path=public as $$
  select json_build_object(
    'business', (select name from businesses where id=p_business and status='approved'),
    'paused',   (select queue_paused from businesses where id=p_business),
    'serving',  (select max(token_number) from bookings where business_id=p_business and service_date=current_date and status in ('called','serving')),
    'next',     (select min(token_number) from bookings where business_id=p_business and service_date=current_date and status='waiting'),
    'waiting',  (select count(*) from bookings where business_id=p_business and service_date=current_date and status='waiting')) $$;

-- ============ ROW LEVEL SECURITY ============
alter table profiles enable row level security;       alter table categories enable row level security;
alter table businesses enable row level security;     alter table business_members enable row level security;
alter table services enable row level security;       alter table counters enable row level security;
alter table bookings enable row level security;       alter table queue_events enable row level security;
alter table notifications enable row level security;  alter table queue_sequences enable row level security;

-- Profiles: see/edit own. Column grants stop users from editing is_admin / is_suspended.
create policy p_self_read   on profiles for select using (id=auth.uid() or is_admin());
create policy p_self_update on profiles for update using (id=auth.uid());
revoke update on profiles from authenticated; grant update (full_name, phone) on profiles to authenticated;
create policy p_admin_update on profiles for update using (is_admin());

create policy cat_read  on categories for select using (true);
create policy cat_admin on categories for all using (is_admin()) with check (is_admin());

-- Businesses: public sees approved; members see theirs; owners edit; admin all.
create policy b_read   on businesses for select using (status='approved' or can_manage(id));
create policy b_insert on businesses for insert with check (owner_id=auth.uid() and status='pending');
create policy b_update on businesses for update using (can_manage(id,'{owner}')) with check (can_manage(id,'{owner}'));
create policy b_admin  on businesses for all using (is_admin()) with check (is_admin());
-- Owners must not self-approve:
create function guard_status() returns trigger language plpgsql as
$$ begin if new.status is distinct from old.status and not is_admin() then raise exception 'Only admins change status'; end if; return new; end $$;
create trigger trg_guard_status before update on businesses for each row execute function guard_status();

create policy m_read  on business_members for select using (user_id=auth.uid() or can_manage(business_id));
create policy m_owner on business_members for all using (can_manage(business_id,'{owner}')) with check (can_manage(business_id,'{owner}'));

create policy s_read  on services for select using (is_active or can_manage(business_id));
create policy s_write on services for all using (can_manage(business_id,'{owner,manager}')) with check (can_manage(business_id,'{owner,manager}'));
create policy c_read  on counters for select using (can_manage(business_id));
create policy c_write on counters for all using (can_manage(business_id,'{owner,manager}')) with check (can_manage(business_id,'{owner,manager}'));

-- Bookings: READ-ONLY from the client. All writes go through the RPCs above.
create policy bk_read on bookings for select using (customer_id=auth.uid() or can_manage(business_id));
create policy ev_read on queue_events for select using (can_manage(business_id));
create policy n_read  on notifications for select using (user_id=auth.uid());
create policy n_mark  on notifications for update using (user_id=auth.uid());
-- queue_sequences: no policies => no client access at all.

revoke all on function create_booking, transition_booking, call_next from public;
grant execute on function create_booking, transition_booking, call_next, get_public_queue to authenticated;
grant execute on function get_public_queue to anon;

-- ============ REALTIME ============
alter publication supabase_realtime add table bookings, notifications, businesses;
