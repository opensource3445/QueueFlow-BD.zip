# Setup guide
1. Create a free project at supabase.com. Copy **Project URL** and the **anon/publishable** key (Settings -> API). Never use or share the service_role key.
2. In the SQL editor run `001` to `008` in order (005 = audit fixes and grants, 006 = review fixes, 007 = invitations, 008 = final hardening).
3. Make yourself admin (SQL editor): `update profiles set is_admin = true where id = (select id from auth.users where email='you@example.com');`
4. Local: copy `.env.example` values into your shell, run `npm install`, then `SUPABASE_URL=... SUPABASE_ANON_KEY=... npm run build && npm start`.
   (Or edit `public/config.js` by hand locally; don't commit real values.)
5. Authentication -> URL configuration: add `/reset-password.html` on your local and Vercel URLs as redirect URLs. Also enable CAPTCHA under Attack Protection (needs a Cloudflare Turnstile key).
6. Deploy: push to GitHub, import in Vercel, add env vars `SUPABASE_URL` and `SUPABASE_ANON_KEY`. `vercel.json` runs the config build.
7. Try it: register a business user -> submit business -> approve as admin -> add a service -> book as a customer.

## Bot protection (optional but recommended)
1. Cloudflare Turnstile -> add a widget for your domain; copy the **site key** and **secret key**.
2. Supabase -> Authentication -> Attack Protection -> enable CAPTCHA (Turnstile) and paste the **secret** key there.
3. Vercel env var `TURNSTILE_SITE_KEY` = site key, then redeploy. Do both steps 2 and 3, or signups will fail.

## Config file
`public/config.js` is git-ignored. Vercel generates it from env vars at build time. Locally: copy `public/config.example.js` to `public/config.js`, or run `npm run build` / `npm run demo`.
