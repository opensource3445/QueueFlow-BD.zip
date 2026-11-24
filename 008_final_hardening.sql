-- Run after 001-007. Round-3 hardening.

-- add_staff_by_email: reject NULL role, normalise the email, and send at most one invitation notification per hour
create or replace function add_staff_by_email(p_business uuid, p_email text, p_role member_role) returns void
language plpgsql security definer set search_path=public, auth as $$
declare v_uid uuid; v_name text; v_email text := lower(trim(coalesce(p_email, ''))); v_prev timestamptz;
begin
  if not can_manage(p_business,'{owner}') then raise exception 'Only the owner can add staff'; end if;
  if not exists (select 1 from businesses where id = p_business and status = 'approved') then raise exception 'Business must be approved first'; end if;
  if p_role is null or p_role not in ('manager','staff') then raise exception 'Role must be manager or staff'; end if;
  if v_email = '' then return; end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null or v_uid = auth.uid() then return; end if;
  if exists (select 1 from profiles where id = v_uid and (is_admin or is_suspended)) then return; end if;
  if exists (select 1 from business_members where business_id = p_business and user_id = v_uid and role = 'owner') then return; end if;
  select created_at into v_prev from staff_invites where business_id = p_business and invitee_id = v_uid;
  insert into staff_invites(business_id, invitee_id, role, invited_by) values (p_business, v_uid, p_role, auth.uid())
    on conflict (business_id, invitee_id) do update set role = excluded.role, invited_by = excluded.invited_by, created_at = now();
  if v_prev is null or v_prev < now() - interval '1 hour' then     -- no notification spam on repeated invites
    select name into v_name from businesses where id = p_business;
    insert into notifications(user_id, title, body) values (v_uid, 'Staff invitation', 'You were invited to join ' || v_name || '. Open your account page to accept or decline.');
  end if;
end $$;

-- Invites expire after 7 days and only work for approved businesses
drop policy si_select on staff_invites;
create policy si_select on staff_invites for select using (invitee_id = auth.uid() and created_at > now() - interval '7 days'
  and exists (select 1 from businesses b where b.id = business_id and b.status = 'approved'));

create or replace function accept_staff_invite(p_invite uuid) returns void language plpgsql security definer set search_path = public as $$
declare i staff_invites;
begin
  if auth.uid() is null then raise exception 'Not authenticated' using errcode='28000'; end if;
  if exists (select 1 from profiles where id = auth.uid() and is_suspended) then raise exception 'Account suspended'; end if;
  delete from staff_invites where id = p_invite and invitee_id = auth.uid() and created_at > now() - interval '7 days' returning * into i;
  if not found then raise exception 'Invitation not found or expired'; end if;
  if not exists (select 1 from businesses where id = i.business_id and status = 'approved') then
    raise exception 'This business is no longer active'; end if;          -- the raise also rolls the delete back
  insert into business_members(business_id, user_id, role) values (i.business_id, i.invitee_id, i.role)
    on conflict (business_id, user_id) do update set role = excluded.role where business_members.role <> 'owner';
end $$;

-- guard_status: status/owner rules only on UPDATE; opening_hours validated on INSERT and on change
create or replace function guard_status() returns trigger language plpgsql set search_path = public as $$
declare v_a text; v_b text; v_check boolean; v_re constant text := '^([01]\d|2[0-3]):[0-5]\d$';
begin
  if tg_op = 'UPDATE' then
    if not is_admin() and (new.status is distinct from old.status or new.owner_id is distinct from old.owner_id) then
      raise exception 'Only admins can change a business status or owner'; end if;
    v_check := new.opening_hours is distinct from old.opening_hours;
  else v_check := true; end if;
  if v_check then
    v_a := nullif(new.opening_hours->'daily'->>0, ''); v_b := nullif(new.opening_hours->'daily'->>1, '');
    if (v_a is null) <> (v_b is null) then raise exception 'Set both opening and closing time, or neither'; end if;
    if v_a is not null then
      if v_a !~ v_re or v_b !~ v_re then raise exception 'Opening hours must be HH:MM'; end if;
      if v_a::time >= v_b::time then raise exception 'Opening time must be before closing time'; end if;
    end if;
  end if;
  return new;
end $$;
drop trigger trg_guard_status on businesses;
create trigger trg_guard_status before insert or update on businesses for each row execute function guard_status();

-- No anonymous execution of authenticated-only functions
revoke all on function create_booking(uuid, uuid, text, time), transition_booking(uuid, text, uuid), call_next(uuid, uuid), get_my_position(uuid),
  set_queue_paused(uuid, boolean), add_staff_by_email(uuid, text, member_role), accept_staff_invite(uuid), business_stats(uuid, date, date),
  admin_set_suspended(uuid, boolean), admin_stats(), delete_my_account() from public, anon;
grant execute on function create_booking(uuid, uuid, text, time), transition_booking(uuid, text, uuid), call_next(uuid, uuid), get_my_position(uuid),
  set_queue_paused(uuid, boolean), add_staff_by_email(uuid, text, member_role), accept_staff_invite(uuid), business_stats(uuid, date, date),
  admin_set_suspended(uuid, boolean), admin_stats(), delete_my_account() to authenticated;
