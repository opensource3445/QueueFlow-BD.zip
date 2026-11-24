-- Audit fixes S1,S2,S5,S6,S7,L2,V1. Run after 001-004.

-- V1: explicit grants (newer Supabase projects do not expose tables automatically). RLS still decides row access.
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on businesses, business_members, services, counters, categories to authenticated;
revoke all on queue_sequences from anon, authenticated;       -- internal token counter: never client-visible
revoke update on notifications from authenticated; grant update (is_read) on notifications to authenticated;  -- users can only mark read
grant select on businesses, queue_public to anon;              -- needed by the public queue display
grant execute on function is_admin(), can_manage(uuid, member_role[]) to anon, authenticated;

-- S7: only approved businesses expose services / queue numbers publicly
drop policy s_read on services;
create policy s_read on services for select using (can_manage(business_id) or
  (is_active and exists (select 1 from businesses b where b.id = business_id and b.status = 'approved')));
drop policy qp_read on queue_public;
create policy qp_read on queue_public for select using (can_manage(business_id) or
  exists (select 1 from businesses b where b.id = business_id and b.status = 'approved'));

-- L2: account deletion must not be blocked by history
alter table bookings drop constraint bookings_customer_id_fkey,
  add constraint bookings_customer_id_fkey foreign key (customer_id) references profiles(id) on delete cascade;
alter table counters drop constraint counters_staff_id_fkey,
  add constraint counters_staff_id_fkey foreign key (staff_id) references profiles(id) on delete set null;
create function delete_my_account() returns void language plpgsql security definer set search_path=public, auth as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if is_admin() then raise exception 'Admin accounts cannot be self-deleted'; end if;
  if exists (select 1 from businesses where owner_id = auth.uid()) then
    raise exception 'You own a business. Ask an admin to remove it first.'; end if;
  delete from auth.users where id = auth.uid();   -- cascades to profile, bookings, notifications
end $$;
revoke all on function delete_my_account from public; grant execute on function delete_my_account to authenticated;

-- S1: staff lookup only for approved businesses, one generic message (no email enumeration)
create or replace function add_staff_by_email(p_business uuid, p_email text, p_role member_role) returns void
language plpgsql security definer set search_path=public, auth as $$
declare v_uid uuid;
begin
  if not can_manage(p_business,'{owner}') then raise exception 'Only the owner can add staff'; end if;
  if not exists (select 1 from businesses where id = p_business and status = 'approved') then raise exception 'Business must be approved first'; end if;
  if p_role = 'owner' then raise exception 'Cannot add another owner'; end if;
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is not null then
    insert into business_members values (p_business, v_uid, p_role) on conflict (business_id,user_id) do update set role = excluded.role;
  end if;   -- same response whether or not the account exists
end $$;

-- S2 + S6: booking limits and validation
create or replace function create_booking(p_business uuid, p_service uuid, p_idem text, p_time time default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare v_token int; v_row bookings; v_uid uuid := auth.uid(); v_h jsonb; v_open time; v_close time;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id=v_uid and is_suspended) then raise exception 'Account suspended'; end if;
  if p_idem is null or length(p_idem) not between 8 and 100 then raise exception 'Invalid idempotency key'; end if;
  select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
  if found then return v_row; end if;

  select opening_hours into v_h from businesses where id=p_business and status='approved' and not queue_paused;
  if not found then raise exception 'Business is not accepting bookings'; end if;
  if not exists (select 1 from services where id=p_service and business_id=p_business and is_active) then raise exception 'Invalid service'; end if;
  if (select count(*) from bookings where customer_id=v_uid and business_id=p_business and service_date=current_date
        and status in ('waiting','called','serving')) >= 3 then raise exception 'You already have 3 active bookings here'; end if;
  if p_time is not null then
    if p_time <= localtime then raise exception 'Choose a future time'; end if;
    v_open := nullif(v_h->'daily'->>0,'')::time; v_close := nullif(v_h->'daily'->>1,'')::time;
    if v_open is not null and v_close is not null and (p_time < v_open or p_time > v_close) then raise exception 'Outside opening hours'; end if;
  end if;

  begin
    insert into queue_sequences(business_id, service_date, last_token) values (p_business, current_date, 1)
      on conflict (business_id, service_date) do update set last_token = queue_sequences.last_token + 1 returning last_token into v_token;
    insert into bookings(business_id, service_id, customer_id, token_number, appointment_time, idempotency_key)
      values (p_business, p_service, v_uid, v_token, p_time, p_idem) returning * into v_row;
  exception when unique_violation then
    select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
    if found then return v_row; end if;
    raise exception 'That appointment slot was just taken' using errcode='23505';
  end;
  insert into queue_events(booking_id,business_id,actor_id,to_status) values (v_row.id,p_business,v_uid,'waiting');
  insert into notifications(user_id,title,body) values (v_uid,'Booking confirmed','Your token is #'||v_token);
  return v_row;
end $$;

-- S5: counter only set by staff, and only a counter of the same business
create or replace function transition_booking(p_booking uuid, p_action text, p_counter uuid default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare b bookings; v_new booking_status; v_old booking_status; v_staff boolean; v_counter uuid;
begin
  select * into b from bookings where id=p_booking for update;
  if not found then raise exception 'Booking not found'; end if;
  v_staff := can_manage(b.business_id); v_old := b.status;
  v_new := case
    when p_action='call' and b.status='waiting' then 'called' when p_action='start' and b.status='called' then 'serving'
    when p_action='complete' and b.status='serving' then 'completed' when p_action='skip' and b.status in ('waiting','called') then 'skipped'
    when p_action='recall' and b.status='skipped' then 'waiting' when p_action='cancel' and b.status='waiting' then 'cancelled' else null end;
  if v_new is null then raise exception 'Invalid transition: % from %', p_action, b.status; end if;
  if p_action='cancel' then if not (v_staff or b.customer_id = auth.uid()) then raise exception 'Not allowed'; end if;
  elsif not v_staff then raise exception 'Not allowed'; end if;
  if p_counter is not null and v_staff then
    select id into v_counter from counters where id=p_counter and business_id=b.business_id and is_active;
    if v_counter is null then raise exception 'Invalid counter'; end if;
  end if;
  update bookings set status=v_new, counter_id = coalesce(v_counter, counter_id),
    called_at = case when v_new='called' then now() else called_at end,
    started_at = case when v_new='serving' then now() else started_at end,
    completed_at = case when v_new='completed' then now() else completed_at end
  where id=b.id returning * into b;
  insert into queue_events(booking_id,business_id,actor_id,from_status,to_status) values (b.id,b.business_id,auth.uid(),v_old,v_new);
  insert into notifications(user_id,title) values (b.customer_id,
    case v_new when 'called' then 'It''s your turn! Token #'||b.token_number when 'completed' then 'Service completed'
      when 'cancelled' then 'Booking cancelled' when 'skipped' then 'You were skipped' else 'Status: '||v_new end);
  return b;
end $$;
