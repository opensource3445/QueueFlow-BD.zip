# Database guide
Migrations in `supabase/migrations/`, run **in order** 001 -> 008.

| Table | Purpose |
|---|---|
| profiles | one row per user; `is_admin`/`is_suspended` not editable by clients |
| categories, businesses, business_members | catalog, approval status, roles (owner/manager/staff) |
| services, counters | what a business offers / its service points |
| bookings | token, date, optional appointment time, status, idempotency key |
| queue_sequences | per business per day token counter (no client access) |
| queue_public | public summary for realtime (serving/next/waiting) |
| queue_events, notifications | history and in-app messages |

## Key policies (RLS)
- `bk_read`: you see your own bookings, or bookings of a business you belong to. **No client insert/update policy on bookings**, so only the RPCs can change them.
- `b_read`: public sees approved businesses only; members see their own.
- `guard_status` trigger: only admins can change a business `status` (no self-approval).
- Profile column grants: users can update only `full_name` and `phone`.
- `queue_sequences`: RLS on, no policies = unreachable from the browser.
- `p_staff_read`: staff can read profiles of customers who booked with them.
