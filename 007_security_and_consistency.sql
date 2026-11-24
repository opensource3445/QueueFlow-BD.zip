-- Run after 001-006. Final review fixes.

-- Pin search_path on the date helpers
create or replace function bd_today() returns date language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Dhaka')::date $$;
create or replace function bd_now_time() returns time language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Dhaka')::time $$;

-- Ban evasion: a suspended user cannot delete the account to dodge a suspension
create or replace function delete_my_account() returns void language plpgsql security definer set search_path=public, auth as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_suspended) then
    raise exception 'Suspended accounts cannot be self-deleted. Contact support.'; end if;
  if is_admin() then raise exception 'Admin accounts cannot be self-deleted'; end if;
  if exists (select 1 from businesses where owner_id = auth.uid()) then
    raise exception 'You own a business. Ask an admin to remove it first.'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- Opening hours: both times or neither, HH:MM, open before close
create or replace function guard_status() returns trigger language plpgsql set search_path = public as $$
declare v_a text; v_b text; v_re constant text := '^([01]\d|2[0-3]):[0-5]\d$';
begin
  if not is_admin() and (new.status is distinct from old.status or new.owner_id is distinct from old.owner_id) then
    raise exception 'Only admins can change a business status or owner'; end if;
  if new.opening_hours is distinct from old.opening_hours then
    v_a := nullif(new.opening_hours->'daily'->>0, ''); v_b := nullif(new.opening_hours->'daily'->>1, '');
    if (v_a is null) <> (v_b is null) then raise exception 'Set both opening and closing time, or neither'; end if;
    if v_a is not null then
      if v_a !~ v_re or v_b !~ v_re then raise exception 'Opening hours must be HH:MM'; end if;
      if v_a::time >= v_b::time then raise exception 'Opening time must be before closing time'; end if;
    end if;
  end if;
  return new;
end $$;

-- Removing a team member frees any counter assigned to them
create function clear_removed_staff_counters() returns trigger language plpgsql security definer set search_path = public as $$
begin update counters set staff_id = null where business_id = old.business_id and staff_id = old.user_id; return null; end $$;
create trigger trg_clear_staff_counters after delete on business_members for each row execute function clear_removed_staff_counters();

-- recall can collide with a slot that was re-booked while the booking was skipped
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
  begin
    update bookings set status=v_new, counter_id = coalesce(v_counter, counter_id),
      called_at = case when v_new='called' then now() else called_at end,
      started_at = case when v_new='serving' then now() else started_at end,
      completed_at = case when v_new='completed' then now() else completed_at end
    where id=b.id returning * into b;
  exception when unique_violation then
    raise exception 'Cannot recall: another active booking now holds this appointment slot' using errcode='23505';
  end;
  insert into queue_events(booking_id,business_id,actor_id,from_status,to_status) values (b.id,b.business_id,auth.uid(),v_old,v_new);
  insert into notifications(user_id,title) values (b.customer_id,
    case v_new when 'called' then 'It''s your turn! Token #'||b.token_number when 'completed' then 'Service completed'
      when 'cancelled' then 'Booking cancelled' when 'skipped' then 'You were skipped' else 'Status: '||v_new end);
  return b;
end $$;

-- Consent-based staff invitations: owners can no longer add arbitrary accounts (or learn which emails exist) directly
create table staff_invites (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  invitee_id uuid not null references profiles(id) on delete cascade,
  role member_role not null check (role in ('manager','staff')),
  invited_by uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (business_id, invitee_id));
alter table staff_invites enable row level security;
revoke all on staff_invites from anon, authenticated;
grant select, delete on staff_invites to authenticated;
create policy si_select on staff_invites for select using (invitee_id = auth.uid());   -- only the invited person; owners cannot list invites
create policy si_delete on staff_invites for delete using (invitee_id = auth.uid());   -- decline

create or replace function add_staff_by_email(p_business uuid, p_email text, p_role member_role) returns void
language plpgsql security definer set search_path=public, auth as $$
declare v_uid uuid; v_name text;
begin
  if not can_manage(p_business,'{owner}') then raise exception 'Only the owner can add staff'; end if;
  if not exists (select 1 from businesses where id = p_business and status = 'approved') then raise exception 'Business must be approved first'; end if;
  if p_role not in ('manager','staff') then raise exception 'Role must be manager or staff'; end if;
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  -- Identical, silent result for every case where no invite should exist (no enumeration)
  if v_uid is null or v_uid = auth.uid() then return; end if;
  if exists (select 1 from profiles where id = v_uid and (is_admin or is_suspended)) then return; end if;
  if exists (select 1 from business_members where business_id = p_business and user_id = v_uid and role = 'owner') then return; end if;
  insert into staff_invites(business_id, invitee_id, role, invited_by) values (p_business, v_uid, p_role, auth.uid())
    on conflict (business_id, invitee_id) do update set role = excluded.role, invited_by = excluded.invited_by, created_at = now();
  select name into v_name from businesses where id = p_business;
  insert into notifications(user_id, title, body) values (v_uid, 'Staff invitation', 'You were invited to join ' || v_name || '. Open your account page to accept or decline.');
end $$;

create function accept_staff_invite(p_invite uuid) returns void language plpgsql security definer set search_path = public as $$
declare i staff_invites;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_suspended) then raise exception 'Account suspended'; end if;
  delete from staff_invites where id = p_invite and invitee_id = auth.uid() returning * into i;
  if not found then raise exception 'Invitation not found'; end if;
  insert into business_members(business_id, user_id, role) values (i.business_id, i.invitee_id, i.role)
    on conflict (business_id, user_id) do update set role = excluded.role where business_members.role <> 'owner';   -- never downgrade an owner
end $$;
revoke all on function accept_staff_invite(uuid) from public;
grant execute on function accept_staff_invite(uuid) to authenticated;
