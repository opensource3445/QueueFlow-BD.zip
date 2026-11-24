-- Business operations. (Bangladesh dates come from bd_today() in 006, not from a database setting.)

create function set_queue_paused(p_business uuid, p_paused boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not can_manage(p_business) then raise exception 'Not allowed'; end if;
  update businesses set queue_paused = p_paused where id = p_business;
end $$;

-- Owner adds an existing user (by email) as manager/staff. Server-side lookup; email list is never exposed.
create function add_staff_by_email(p_business uuid, p_email text, p_role member_role) returns void
language plpgsql security definer set search_path=public, auth as $$
declare v_uid uuid;
begin
  if not can_manage(p_business,'{owner}') then raise exception 'Only the owner can add staff'; end if;
  if p_role = 'owner' then raise exception 'Cannot add another owner'; end if;
  select id into v_uid from auth.users where lower(email)=lower(p_email);
  if v_uid is null then raise exception 'No account with that email'; end if;
  insert into business_members values (p_business, v_uid, p_role) on conflict (business_id,user_id) do update set role=excluded.role;
end $$;

create function business_stats(p_business uuid, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path=public as $$
begin
  if not can_manage(p_business) then raise exception 'Not allowed'; end if;
  return (select json_build_object(
    'total', count(*), 'waiting', count(*) filter (where status='waiting'),
    'serving', count(*) filter (where status in ('called','serving')),
    'completed', count(*) filter (where status='completed'),
    'cancelled', count(*) filter (where status='cancelled'),
    'avg_service_min', round(avg(extract(epoch from completed_at-started_at)/60) filter (where status='completed')::numeric,1),
    'avg_wait_min', round(avg(extract(epoch from started_at-created_at)/60) filter (where started_at is not null)::numeric,1))
  from bookings where business_id=p_business and service_date between p_from and p_to);
end $$;

-- Staff may read the profile (name/phone) of customers who booked with their business.
create policy p_staff_read on profiles for select using (
  exists (select 1 from bookings b where b.customer_id = profiles.id and can_manage(b.business_id)));

revoke all on function set_queue_paused, add_staff_by_email, business_stats from public;
grant execute on function set_queue_paused, add_staff_by_email, business_stats to authenticated;
