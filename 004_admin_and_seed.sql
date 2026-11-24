insert into categories(name) values ('Salon & Barbershop'),('Mobile & Computer Repair'),('Local Service Center'),('Other')
  on conflict (name) do nothing;

-- Column grants stop clients editing is_suspended, so admins use this checked function.
create function admin_set_suspended(p_user uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot suspend yourself'; end if;
  update profiles set is_suspended = p_suspended where id = p_user and not is_admin;
end $$;

create function admin_stats() returns json language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  return json_build_object(
    'customers', (select count(*) from profiles where not is_admin),
    'businesses', (select count(*) from businesses),
    'active', (select count(*) from businesses where status='approved'),
    'pending', (select count(*) from businesses where status='pending'),
    'bookings', (select count(*) from bookings),
    'active_queues', (select count(distinct business_id) from bookings where service_date=current_date and status in ('waiting','called','serving')));
end $$;
revoke all on function admin_set_suspended, admin_stats from public;
grant execute on function admin_set_suspended, admin_stats to authenticated;
-- To make yourself the first admin (run once in SQL editor, never from the app):
-- update profiles set is_admin = true where id = (select id from auth.users where email = 'you@example.com');
