# QueueFlow BD
Smart queue and appointment management for small businesses (Hack the Vibe 2026 / CSE project).
Customers book, get a digital token and track their position live; businesses run the queue from a dashboard; admins approve businesses; a public screen shows the current token.

## Stack
HTML, CSS, vanilla JS (ES modules) · Supabase (PostgreSQL, Auth, Realtime) · GitHub · Vercel.

## Features
Customer portal (search, booking, tokens, live tracking, notifications) · Business dashboard (queue controls, services, counters, staff, profile, reports) · Admin dashboard · Public queue display · Atomic tokens, idempotent bookings, slot protection, state machine · Realtime sync with reconnect re-sync.

## Folder structure
`public/` (the only folder deployed: pages, `css/`, `js/<module>/`) · `supabase/migrations/` · `tests/` · `docs/` · `scripts/build-config.js`

## Demo mode (no Supabase needed)
`npm install` then `npm run demo` opens the app with sample data. Logins (password `demo1234`): `customer@demo.test`, `owner@demo.test`, `admin@demo.test`.
Open the customer page and the business queue page in **two browser tabs**: bookings and queue actions appear live in the other tab.
A brown banner marks demo mode. Data lives only in that browser's localStorage, is **not** Supabase, and is **not secure**. Demo mode turns on only when `config.js` says `demo: true` (the `npm run demo` script does this); a failed real login never falls back to it. Switch back with `npm run build` (real keys). Demo-mode rules mirror the SQL functions but are a simulation: the real concurrency, RLS and realtime are only proven against Supabase.

## Run it
See **docs/setup-guide.md** (Supabase, migrations, env vars, local run, Vercel).
Architecture and concurrency: **docs/architecture.md**. Tables and policies: **docs/database.md**. Tests: **tests/concurrency-tests.md**.

## Security notes
Only the public anon key is in the frontend. RLS is on every table; roles live in the database; clients cannot write bookings directly; business status and admin flags are protected by triggers/grants. Never commit `.env` or a service_role key.

## Known limitations (honest list)
- **Nothing has been run against a live Supabase project yet**; tests are written but unexecuted.
- Opening hours are enforced for appointments; slot length vs service duration is still not checked.
- Registration CAPTCHA must be enabled in the Supabase dashboard (not coded). Privacy/Terms pages are templates.
- No charts, logo upload, audit log or email notifications; edit dialogs use `prompt()`.
- Responsive layout and accessibility were written carefully but not audited in browsers.
