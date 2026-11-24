-- Realtime note: RLS also filters realtime events, so a customer would never see OTHER people's
-- booking changes. Solution: a small public summary table (no private data) kept in sync by a trigger.
create table queue_public (
  business_id uuid references businesses(id) on delete cascade,
  service_date date, serving int, next int, waiting int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (business_id, service_date));
alter table queue_public enable row level security;
create policy qp_read on queue_public for select using (true);

create function refresh_queue_public() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into queue_public(business_id, service_date, serving, next, waiting)
  select new.business_id, new.service_date,
    max(token_number) filter (where status in ('called','serving')),
    min(token_number) filter (where status='waiting'),
    count(*) filter (where status='waiting')
  from bookings where business_id=new.business_id and service_date=new.service_date
  on conflict (business_id, service_date) do update set serving=excluded.serving, next=excluded.next,
    waiting=excluded.waiting, updated_at=now();
  return null; end $$;
create trigger trg_qp after insert or update on bookings for each row execute function refresh_queue_public();
alter publication supabase_realtime add table queue_public;

-- People ahead + estimate (waiting tokens lower than mine x average service minutes). Estimate only.
create function get_my_position(p_booking uuid) returns json language plpgsql stable security definer set search_path=public as $$
declare b bookings; v_ahead int; v_avg numeric;
begin
  select * into b from bookings where id=p_booking and customer_id=auth.uid();
  if not found then raise exception 'Not found'; end if;
  select count(*) into v_ahead from bookings where business_id=b.business_id and service_date=b.service_date
    and status in ('waiting','called','serving') and token_number < b.token_number;
  select coalesce(avg(duration_min),10) into v_avg from services where business_id=b.business_id and is_active;
  return json_build_object('ahead',v_ahead,'est_minutes',round(v_ahead*v_avg),'status',b.status,'token',b.token_number);
end $$;
grant execute on function get_my_position to authenticated;
