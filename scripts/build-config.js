// Writes config.js from environment variables (run by Vercel at build time, or locally: npm run build).
import { writeFileSync } from "node:fs";
const { SUPABASE_URL, SUPABASE_ANON_KEY, TURNSTILE_SITE_KEY = "" } = process.env;   // site key is public; optional
if (process.argv.includes("--demo")) { writeFileSync("public/config.js", 'window.__QF_CONFIG__ = {"demo":true};\n'); console.log("config.js written in DEMO mode"); process.exit(0); }
if (!SUPABASE_URL || !SUPABASE_ANON_KEY) { console.error("Set SUPABASE_URL and SUPABASE_ANON_KEY (anon key only!)."); process.exit(1); }
writeFileSync("public/config.js", `window.__QF_CONFIG__ = ${JSON.stringify({ url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY, demo: false, turnstileSiteKey: TURNSTILE_SITE_KEY })};\n`);
console.log("config.js written");
