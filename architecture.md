# Architecture
Browser (HTML/CSS/vanilla JS modules) -> Supabase (Auth, PostgreSQL with RLS, Realtime). There is no custom server: the database enforces the rules.

**Rule:** the browser only *asks*; PostgreSQL *decides*. All booking/queue writes go through functions (`create_booking`, `transition_booking`, `call_next`).

## Concurrency (A05)
- **Tokens:** `INSERT ... ON CONFLICT DO UPDATE` on `queue_sequences` locks one row per business/day, so simultaneous callers queue up and get 1, 2, 3... Backstop: `unique(business_id, service_date, token_number)`.
- **Idempotency:** `unique(customer_id, idempotency_key)`; the browser keeps one key per action, so retries return the original booking.
- **Slots:** a partial unique index allows one *active* booking per business/date/time.
- **State machine:** `transition_booking` does `SELECT ... FOR UPDATE` then checks the allowed transition. `call_next` uses `SKIP LOCKED` so two staff never call the same person.
- **Atomicity:** each function is one transaction; an error rolls back everything (including the token increment).

## Realtime (A01)
Clients subscribe with filters, then **re-read the database** on every event and after every (re)subscribe. RLS also filters realtime, so customers listen to `queue_public` (a safe summary kept by a trigger) instead of other people's bookings. Channels are removed when replaced or on page hide.

## Modules / pages
customer.html, business.html, admin.html, queue-display.html?b=<id>, plus login/register/index. Code is under `js/<module>/`.
