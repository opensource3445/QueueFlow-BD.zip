// Concurrency test against YOUR Supabase project (anon key + normal logins, so RLS applies).
// Usage: SUPABASE_URL=.. SUPABASE_ANON_KEY=.. TEST_EMAIL=.. TEST_PASSWORD=.. BUSINESS_ID=.. SERVICE_ID=.. node tests/booking-tests.js
// Optional second customer for a cross-user test: TEST_EMAIL_2, TEST_PASSWORD_2.
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
const e = process.env;
async function login(email, password) { const c = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY); const { error } = await c.auth.signInWithPassword({ email, password }); if (error) throw error; return c; }
const u1 = await login(e.TEST_EMAIL, e.TEST_PASSWORD), u2 = e.TEST_EMAIL_2 ? await login(e.TEST_EMAIL_2, e.TEST_PASSWORD_2) : null;
const call = (c, key, time = null) => c.rpc("create_booking", { p_business: e.BUSINESS_ID, p_service: e.SERVICE_ID, p_idem: key, p_time: time });
let pass = true; const created = []; const check = (name, ok) => { console.log(ok ? "PASS" : "FAIL", name); pass &&= ok; };
const keep = (r) => { if (r.data?.id) created.push({ id: r.data.id, c: r.c }); return r; };
const cancelAll = async () => { for (const b of created.splice(0)) await b.c.rpc("transition_booking", { p_booking: b.id, p_action: "cancel" }); };

// 1. One customer may hold 3 active bookings: 3 parallel get 3 DIFFERENT tokens, a 4th is refused
const a = await Promise.all([1, 2, 3].map(() => call(u1, randomUUID()).then(r => keep({ ...r, c: u1 }))));
const t1 = a.map(r => r.data?.token_number).filter(Boolean);
check("3 parallel bookings -> 3 unique tokens", t1.length === 3 && new Set(t1).size === 3);
check("4th active booking refused (cap = 3)", !!(await call(u1, randomUUID())).error);
await cancelAll();

// 1b. Two different customers booking at the same time must never share a token
if (u2) { const m = await Promise.all([call(u1, randomUUID()), call(u2, randomUUID()), call(u1, randomUUID()), call(u2, randomUUID())].map((p, i) => p.then(r => keep({ ...r, c: i % 2 ? u2 : u1 }))));
  const t = m.map(r => r.data?.token_number).filter(Boolean); check("4 parallel bookings from 2 customers -> 4 unique tokens", t.length === 4 && new Set(t).size === 4); await cancelAll(); }
else console.log("SKIP cross-customer test (set TEST_EMAIL_2 / TEST_PASSWORD_2)");

// 2. Same idempotency key sent 10x at once -> exactly ONE booking
const key = randomUUID(), dup = await Promise.all(Array.from({ length: 10 }, () => call(u1, key).then(r => keep({ ...r, c: u1 }))));
check("10 identical requests -> 1 booking id", new Set(dup.map(r => r.data?.id)).size === 1);
await cancelAll();                                           // free the cap before the slot test

// 3. Same appointment slot, two requests at once -> exactly one wins. Slot = 20 min from now (Bangladesh time), inside opening hours.
const { data: biz } = await u1.from("businesses").select("opening_hours").eq("id", e.BUSINESS_ID).single();
const bd = new Date(Date.now() + 20 * 60000).toLocaleTimeString("en-GB", { timeZone: "Asia/Dhaka", hour12: false }).slice(0, 5), [open, close] = biz?.opening_hours?.daily || [];
if ((open && bd < open) || (close && bd > close) || bd < "00:20") console.log("SKIP slot test: 20 minutes from now is outside opening hours (" + bd + ")");
else { const race = await Promise.all([call(u1, randomUUID(), bd).then(r => keep({ ...r, c: u1 })), call(u1, randomUUID(), bd).then(r => keep({ ...r, c: u1 }))]);
  check("same-slot race -> exactly 1 success", race.filter(r => r.data).length === 1); await cancelAll(); }
console.log(pass ? "ALL PASSED" : "SOME FAILED"); process.exit(pass ? 0 : 1);
