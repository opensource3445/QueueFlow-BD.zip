// State-machine test. Needs a STAFF login for the business plus a waiting booking id you own.
// Usage: SUPABASE_URL=.. SUPABASE_ANON_KEY=.. STAFF_EMAIL=.. STAFF_PASSWORD=.. BOOKING_ID=<waiting booking> node tests/queue-tests.js
import { createClient } from "@supabase/supabase-js";
const e = process.env, sb = createClient(e.SUPABASE_URL, e.SUPABASE_ANON_KEY);
await sb.auth.signInWithPassword({ email: e.STAFF_EMAIL, password: e.STAFF_PASSWORD });
const act = (a) => sb.rpc("transition_booking", { p_booking: e.BOOKING_ID, p_action: a });
let pass = true; const check = (n, ok) => { console.log(ok ? "PASS" : "FAIL", n); pass &&= ok; };
check("waiting -> complete is REJECTED", !!(await act("complete")).error);
check("waiting -> start is REJECTED", !!(await act("start")).error);
check("waiting -> call ok", !(await act("call")).error);
check("called -> call again REJECTED", !!(await act("call")).error);
check("called -> start ok", !(await act("start")).error);
check("serving -> cancel REJECTED", !!(await act("cancel")).error);
check("serving -> complete ok", !(await act("complete")).error);
check("completed -> anything REJECTED", !!(await act("recall")).error);


// Two staff clicking "Call next" at the same instant must call two DIFFERENT customers (FOR UPDATE SKIP LOCKED).
// Needs BUSINESS_ID and at least 2 bookings in 'waiting' status today.
if (e.BUSINESS_ID) {
  const [r1, r2] = await Promise.all([1, 2].map(() => sb.rpc("call_next", { p_business: e.BUSINESS_ID })));
  const ids = [r1, r2].map(r => r.data?.id).filter(Boolean);
  check("parallel call_next never calls the same booking twice", ids.length === new Set(ids).size);
  check("parallel call_next called two different customers", ids.length === 2);
  console.log(pass ? "ALL PASSED" : "SOME FAILED"); process.exit(pass ? 0 : 1);
} else console.log("SKIP parallel call_next test (set BUSINESS_ID, needs 2 waiting bookings)");
console.log(pass ? "ALL PASSED" : "SOME FAILED"); process.exit(pass ? 0 : 1);
