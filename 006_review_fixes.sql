-- Review fixes. Run after 001-005. All rules are enforced in the database first.

-- 1. Explicit Bangladesh date/time (the DB session timezone is no longer relied on)
create function bd_today() returns date language sql stable as $$ select (now() at time zone 'Asia/Dhaka')::date $$;
create function bd_now_time() returns time language sql stable as $$ select (now() at time zone 'Asia/Dhaka')::time $$;
grant execute on function bd_today(), bd_now_time() to anon, authenticated;
alter table bookings alter column service_date set default bd_today();

-- 3. A suspended account loses all business-member powers (admins are checked via is_admin(), which already requires not suspended)
create or replace function can_manage(b uuid, roles member_role[] default '{owner,manager,staff}') returns boolean
language sql stable security definer set search_path=public as $$
  select is_admin() or exists (select 1 from business_members m join profiles p on p.id = m.user_id
    where m.business_id = b and m.user_id = auth.uid() and m.role = any(roles) and not p.is_suspended) $$;

drop policy b_insert on businesses;
create policy b_insert on businesses for insert with check (owner_id = auth.uid() and status = 'pending'
  and exists (select 1 from profiles where id = auth.uid() and not is_suspended));

-- 4. Non-admins can change neither status nor owner_id; owners cannot edit membership directly
create or replace function guard_status() returns trigger language plpgsql set search_path = public as $$
begin
  if not is_admin() and (new.status is distinct from old.status or new.owner_id is distinct from old.owner_id) then
    raise exception 'Only admins can change a business status or owner'; end if;
  return new; end $$;
drop policy m_owner on business_members;
create policy m_owner_delete on business_members for delete using (can_manage(business_id, '{owner}') and role <> 'owner');
create policy m_admin_all on business_members for all using (is_admin()) with check (is_admin());
-- (adding staff stays possible only through add_staff_by_email)

-- 2. create_booking: per-customer advisory lock (closes the 3-booking race), safe opening-hours parsing, BD dates
create or replace function create_booking(p_business uuid, p_service uuid, p_idem text, p_time time default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare v_token int; v_row bookings; v_uid uuid := auth.uid(); v_today date := bd_today();
        v_h jsonb; v_a text; v_b text; v_open time; v_close time;
        v_re constant text := '^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$';
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id=v_uid and is_suspended) then raise exception 'Account suspended'; end if;
  if p_idem is null or length(p_idem) not between 8 and 100 then raise exception 'Invalid idempotency key'; end if;

  -- Serialize this customer's bookings at this business, THEN re-check idempotency under the lock.
  perform pg_advisory_xact_lock(hashtext('cust:' || v_uid::text || ':' || p_business::text));
  select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
  if found then return v_row; end if;

  select opening_hours into v_h from businesses where id=p_business and status='approved' and not queue_paused;
  if not found then raise exception 'Business is not accepting bookings'; end if;
  if not exists (select 1 from services where id=p_service and business_id=p_business and is_active) then raise exception 'Invalid service'; end if;
  if (select count(*) from bookings where customer_id=v_uid and business_id=p_business and service_date=v_today
        and status in ('waiting','called','serving')) >= 3 then raise exception 'You already have 3 active bookings here'; end if;

  if p_time is not null then
    if p_time <= bd_now_time() then raise exception 'Choose a future time'; end if;
    v_a := v_h->'daily'->>0; v_b := v_h->'daily'->>1;
    if v_a ~ v_re and v_b ~ v_re then
      v_open := v_a::time; v_close := v_b::time;
      if v_open <= v_close and (p_time < v_open or p_time > v_close) then raise exception 'Outside opening hours'; end if;
    end if;
  end if;

  begin
    insert into queue_sequences(business_id, service_date, last_token) values (p_business, v_today, 1)
      on conflict (business_id, service_date) do update set last_token = queue_sequences.last_token + 1 returning last_token into v_token;
    insert into bookings(business_id, service_id, customer_id, token_number, service_date, appointment_time, idempotency_key)
      values (p_business, p_service, v_uid, v_token, v_today, p_time, p_idem) returning * into v_row;
  exception when unique_violation then
    select * into v_row from bookings where customer_id=v_uid and idempotency_key=p_idem;
    if found then return v_row; end if;
    raise exception 'That appointment slot was just taken' using errcode='23505';
  end;
  insert into queue_events(booking_id,business_id,actor_id,to_status) values (v_row.id,p_business,v_uid,'waiting');
  insert into notifications(user_id,title,body) values (v_uid,'Booking confirmed','Your token is #'||v_token);
  return v_row;
end $$;

-- 3. transition_booking: reject anonymous and suspended callers
create or replace function transition_booking(p_booking uuid, p_action text, p_counter uuid default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare b bookings; v_new booking_status; v_old booking_status; v_staff boolean; v_counter uuid;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id=auth.uid() and is_suspended) then raise exception 'Account suspended'; end if;
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

-- 1. BD dates in the remaining functions
create or replace function call_next(p_business uuid, p_counter uuid default null)
returns bookings language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not can_manage(p_business) then raise exception 'Not allowed'; end if;
  select id into v_id from bookings where business_id=p_business and service_date=bd_today() and status='waiting'
    order by token_number limit 1 for update skip locked;
  if v_id is null then raise exception 'No customers waiting'; end if;
  return transition_booking(v_id,'call',p_counter);
end $$;

create or replace function get_public_queue(p_business uuid) returns json language plpgsql stable security definer set search_path=public as $$
declare v_name text; v_paused boolean;
begin
  -- Unapproved/suspended/unknown business: reveal nothing (this function is callable by anon)
  select name, queue_paused into v_name, v_paused from businesses where id = p_business and status = 'approved';
  if not found then return json_build_object('business', null, 'paused', null, 'serving', null, 'next', null, 'waiting', 0); end if;
  return json_build_object('business', v_name, 'paused', v_paused,
    'serving', (select max(token_number) from bookings where business_id=p_business and service_date=bd_today() and status in ('called','serving')),
    'next',    (select min(token_number) from bookings where business_id=p_business and service_date=bd_today() and status='waiting'),
    'waiting', (select count(*) from bookings where business_id=p_business and service_date=bd_today() and status='waiting'));
end $$;

create or replace function admin_stats() returns json language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return json_build_object(
    'customers', (select count(*) from profiles where not is_admin), 'businesses', (select count(*) from businesses),
    'active', (select count(*) from businesses where status='approved'), 'pending', (select count(*) from businesses where status='pending'),
    'bookings', (select count(*) from bookings),
    'active_queues', (select count(distinct business_id) from bookings where service_date=bd_today() and status in ('waiting','called','serving')));
end $$;

-- 5. queue_public: lock per business+day so concurrent transactions cannot publish stale counts; also react to DELETE
create or replace function refresh_queue_public() returns trigger language plpgsql security definer set search_path=public as $$
declare v_biz uuid := coalesce(new.business_id, old.business_id); v_date date := coalesce(new.service_date, old.service_date);
begin
  perform pg_advisory_xact_lock(hashtext('qp:' || v_biz::text || ':' || v_date::text));
  if not exists (select 1 from businesses where id = v_biz) then return null; end if;   -- business itself being deleted
  insert into queue_public(business_id, service_date, serving, next, waiting)
  select v_biz, v_date,
    max(token_number) filter (where status in ('called','serving')),
    min(token_number) filter (where status='waiting'),
    count(*) filter (where status='waiting')
  from bookings where business_id = v_biz and service_date = v_date
  on conflict (business_id, service_date) do update set serving=excluded.serving, next=excluded.next, waiting=excluded.waiting, updated_at=now();
  return null;
end $$;
drop trigger trg_qp on bookings;
create trigger trg_qp after insert or update or delete on bookings for each row execute function refresh_queue_public();

-- 7. get_my_position: authenticated only; no queue math once the booking is no longer waiting/called
create or replace function get_my_position(p_booking uuid) returns json language plpgsql stable security definer set search_path=public as $$
declare b bookings; v_ahead int; v_avg numeric;
begin
  select * into b from bookings where id = p_booking and customer_id = auth.uid();
  if not found then raise exception 'Not found'; end if;
  if b.status not in ('waiting','called') then
    return json_build_object('ahead', 0, 'est_minutes', 0, 'status', b.status, 'token', b.token_number); end if;
  select count(*) into v_ahead from bookings where business_id=b.business_id and service_date=b.service_date
    and status in ('waiting','called','serving') and token_number < b.token_number;
  select coalesce(avg(duration_min),10) into v_avg from services where business_id=b.business_id and is_active;
  return json_build_object('ahead', v_ahead, 'est_minutes', round(v_ahead*v_avg), 'status', b.status, 'token', b.token_number);
end $$;
revoke all on function get_my_position(uuid) from public;
grant execute on function get_my_position(uuid) to authenticated;

-- 8. Staff/managers can see the names of their own team (Counters & Staff tab)
create policy p_team_read on profiles for select using (
  exists (select 1 from business_members bm where bm.user_id = profiles.id and can_manage(bm.business_id)));

-- 9. Deleting a category must not be blocked by businesses using it
alter table businesses drop constraint businesses_category_id_fkey,
  add constraint businesses_category_id_fkey foreign key (category_id) references categories(id) on delete set null;
