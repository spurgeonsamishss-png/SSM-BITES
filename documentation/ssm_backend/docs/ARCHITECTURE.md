# SSM Bites — Backend Architecture & Deployment Guide

## 1. What's in this delivery vs. what needs a follow-up session

**Delivered here (complete, usable as-is):**
- Full normalized PostgreSQL schema — all 32 requested tables, PKs/FKs/indexes/constraints/defaults/triggers
- Production RLS policies enforcing the Student / Admin / Super Admin boundaries you specified
- Storage buckets + policies for all 6 image types
- Business-logic triggers: auto token generation with daily reset, atomic stock decrement, rating rollup, realtime notification fan-out, low-stock alerts, nightly sales rollup
- `place_order` RPC — the atomic, race-condition-safe checkout transaction
- Auth module (`auth.js`) — roll-number/username login mapped onto Supabase Auth (bcrypt hashing + JWT out of the box), persistent sessions, logout, forgot/reset password
- API layer (`api.js`) — one function per existing frontend need (menu, cart, checkout, orders, reviews, notifications, admin dashboard, super admin dashboard)
- 5 Edge Functions — admin creation/password reset (service-role only, never in the browser) and the full Razorpay create → verify → refund flow with signature verification

**Needs a dedicated follow-up (requires your actual credentials/environment, not something crystal ball guessing/scaffolding can responsibly finish):**
- Wiring every single line of the existing HTML's `<script>` to `api.js` (the pattern is identical for all ~40 functions — I'll do this with you screen-by-screen once your Supabase project exists, so we can test against real data instead of guessing)
- Your actual Razorpay test/live keys, webhook secret, and UPI/QR settlement account
- Native mobile build (APK/AAB/IPA) — this needs Xcode + an Apple Developer account (for IPA/TestFlight) and a configured Android signing keystore, neither of which exist in this chat's environment. I can generate the full React Native/Flutter source tree, but the actual binary build has to run on your machine or CI (see §6)
- Push notification certificates (FCM server key / APNs key)
- Load testing at 3000+ concurrent students (needs a real environment to run k6/Artillery against)

---

## 2. Recommended folder structure

```
ssm-bites/
├── frontend/
│   ├── index.html                # your existing UI, now importing backend/*.js
│   ├── backend/
│   │   ├── supabaseClient.js
│   │   ├── auth.js
│   │   └── api.js
│   └── assets/
├── database/
│   ├── 01_schema.sql
│   ├── 02_rls_policies.sql
│   ├── 03_storage_buckets.sql
│   ├── 04_functions_triggers.sql
│   └── 05_rpc_functions.sql
├── supabase/
│   ├── functions/
│   │   ├── admin-create/index.ts
│   │   ├── admin-reset-password/index.ts
│   │   ├── razorpay-create-order/index.ts
│   │   ├── razorpay-verify/index.ts
│   │   └── razorpay-refund/index.ts
│   └── config.toml
├── mobile/                       # React Native app (see §6)
│   ├── src/
│   ├── android/
│   └── ios/
└── .env.example
```

---

## 3. Supabase project setup (order matters)

```bash
# 1. Create the project at supabase.com, note the project ref + anon key
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF

# 2. Run the SQL in order
npx supabase db execute -f database/01_schema.sql
npx supabase db execute -f database/02_rls_policies.sql
npx supabase db execute -f database/03_storage_buckets.sql
npx supabase db execute -f database/04_functions_triggers.sql
npx supabase db execute -f database/05_rpc_functions.sql

# 3. Enable pg_cron (required for 04's scheduled jobs)
#    Dashboard → Database → Extensions → enable "pg_cron"

# 4. Deploy Edge Functions
npx supabase functions deploy admin-create
npx supabase functions deploy admin-reset-password
npx supabase functions deploy razorpay-create-order
npx supabase functions deploy razorpay-verify
npx supabase functions deploy razorpay-refund

# 5. Set Edge Function secrets
npx supabase secrets set RAZORPAY_KEY_ID=xxx RAZORPAY_KEY_SECRET=xxx
```

### Bootstrapping the first Super Admin
Since Super Admin creation can't happen through the app itself (nothing creates the *first* one), run this once manually after `01_schema.sql`:
```sql
-- After creating the auth user via Dashboard → Authentication → Add User
-- (email: superadmin@staff.ssmbites.app), then:
insert into super_admins (auth_id, username, full_name)
values ('<the-new-user-uuid>', 'superadmin', 'System Owner');

insert into user_roles (auth_id, role, ref_id)
values ('<the-new-user-uuid>', 'super_admin', (select id from super_admins where username='superadmin'));
```

---

## 4. Environment configuration

`.env.example`:
```
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_ANON_KEY=your-public-anon-key        # safe in browser
SUPABASE_SERVICE_ROLE_KEY=***NEVER IN BROWSER*** # Edge Functions only
RAZORPAY_KEY_ID=rzp_test_xxx
RAZORPAY_KEY_SECRET=***Edge Functions only***
```
`SUPABASE_SERVICE_ROLE_KEY` and `RAZORPAY_KEY_SECRET` must live only as Supabase Edge Function secrets (`supabase secrets set`) — never in any file shipped to `frontend/`.

---

## 5. Testing procedures

1. **RLS verification** — for each table, log in as each of the 3 roles via the Supabase SQL editor's "Run as user" or via `supabase.auth.signInWithPassword` in a test script, then attempt reads/writes that should be denied. Confirm every denial returns a Postgres RLS error, not just an empty result.
2. **Checkout race condition** — fire concurrent `place_order` RPC calls against a menu item with `remaining_qty = 1` from two different student sessions; exactly one should succeed.
3. **Token/day reset** — insert a test order with `order_date` forced to tomorrow; confirm `token_number` restarts at `A001`.
4. **Payment signature** — call `razorpay-verify` with a tampered `razorpay_signature`; confirm it's rejected and `payments.status` becomes `failed`.
5. **Realtime** — open two browser tabs as the same student; confirm an admin status update in one triggers a UI update in the other within ~1s via `subscribeToOrderUpdates`.
6. **Load test** (once staging exists): `k6 run --vus 3000 --duration 5m load-test.js` against the menu-fetch and checkout endpoints; watch Supabase's connection pooler (use Supavisor/PgBouncer transaction mode) and add read replicas if p95 latency degrades.

---

## 6. Mobile app conversion — React Native vs Flutter

**Recommendation: React Native.**

| Factor | React Native | Flutter |
|---|---|---|
| Code reuse from existing app | High — your HTML/CSS/JS is already component-shaped (screens, sheets, state); React Native's component model maps almost 1:1 | Low — full rewrite in Dart, no code reuse |
| Supabase SDK support | Official, first-class (`@supabase/supabase-js` works directly; realtime, auth, storage all supported) | Official Dart SDK exists but is less mature/less community-tested |
| Team ramp-up | If your team knows JS (they clearly do, given the existing app), this is a much shorter path | Requires learning Dart + Flutter widget system from scratch |
| Razorpay SDK | Mature `react-native-razorpay` package | Official `razorpay_flutter` package exists, less community support |
| Performance for this app's complexity | More than sufficient — SSM Bites is CRUD + realtime, not a graphics-heavy app where Flutter's rendering engine would matter | Would be equally sufficient, but the advantage doesn't apply here |

**Verdict:** Flutter's main edge (custom rendering for pixel-perfect, animation-heavy UIs) isn't relevant here — your existing CSS design language is straightforward to reproduce with React Native + `styled-components` or NativeWind (Tailwind for RN), and you get to reuse your JS logic and Supabase integration almost verbatim.

### Conversion approach
1. Scaffold with `npx react-native init SSMBitesApp` (or Expo for faster iteration — recommended given no native modules beyond camera/QR/biometrics/push, all of which Expo supports).
2. Map each `.screen` `<section>` → one React Native screen component under `mobile/src/screens/` (`HomeScreen.tsx`, `OrdersScreen.tsx`, `AdminDashboardScreen.tsx`, `SuperAdminDashboardScreen.tsx`, etc.) — same names, same responsibilities.
3. Map each `.sheet-backdrop` modal → a `react-native-modal` bottom sheet component.
4. Reuse `backend/api.js` and `backend/auth.js` nearly unchanged (Supabase JS SDK works identically in React Native).
5. Reuse your CSS custom-property color tokens (`--accent`, `--bg`, etc.) as a shared `theme.ts` JS object consumed by NativeWind/styled-components.
6. Add native capabilities via Expo modules:
   - Push notifications → `expo-notifications` (+ FCM/APNs config)
   - QR Scanner (for token pickup verification) → `expo-camera` + `expo-barcode-scanner`
   - Biometric login → `expo-local-authentication`
   - Deep linking → `expo-linking` (e.g. `ssmbites://order/<token>`)
   - Offline cache → `@tanstack/react-query` with `persistQueryClient` against AsyncStorage
7. App icons/splash → `expo-splash-screen` + asset generation via `npx expo-asset-generate`.
8. Build:
   ```bash
   eas build --platform android --profile production   # → AAB for Play Store
   eas build --platform ios --profile production        # → IPA for App Store (needs Apple Developer account)
   ```
   This step must run with your Apple/Google developer credentials — I can generate every source file up to this point, but the signed binary has to be produced under your account.

---

## 7. Security checklist

- [x] Password hashing — delegated to Supabase Auth (bcrypt), not hand-rolled
- [x] JWT sessions with auto-refresh (`persistSession`, `autoRefreshToken`)
- [x] RLS on every table, default-deny (no `using (true)` writes anywhere)
- [x] Service-role key confined to Edge Functions only
- [x] Razorpay signature verified server-side, amount re-checked against DB before order creation (prevents client-side amount tampering)
- [x] SQL injection — not applicable, all queries go through the parameterized Supabase client / RPC, no string-concatenated SQL
- [ ] Rate limiting — add at the edge: Supabase's built-in Auth rate limits cover login; wrap checkout/review endpoints with `upstash/ratelimit` in the Edge Functions if abuse is observed
- [ ] CSRF — not applicable to a token-based (JWT in header) API, but confirm your production frontend is served over HTTPS only
- [ ] XSS — the existing frontend uses template-literal `innerHTML` in several render functions (e.g. `foodCardHTML`); when wiring real user-supplied text (food names, review text) escape it before interpolation, or switch those spots to `textContent`
- [ ] Audit logs — `activity_logs` / `system_logs` tables are in place; wire admin-mutating actions (menu edit, order status change, admin creation) to insert into them

---

## 8. Performance notes for 3000+ concurrent students

- Use Supabase's connection pooler (Supavisor, transaction mode) — already default on hosted Supabase
- All hot-path queries (`menu_items`, `orders` by student/date, `notifications` by recipient) have indexes in `01_schema.sql`
- Pagination: `fetchAdminOrders`/`fetchStudentOrders` should add `.range(offset, offset+49)` once order volume grows — noted as a follow-up wiring step
- Realtime channels are scoped per-student/per-admin (not one global firehose) to keep payload volume low
- Cache `fetchMenu()` client-side for ~30s (menu doesn't change every second) to cut redundant reads during a lunch-rush spike

---

## 9. Final deployment checklist

- [ ] Run all 5 SQL files against production Supabase project
- [ ] Enable pg_cron, confirm the two scheduled jobs appear in `cron.job`
- [ ] Bootstrap the first Super Admin account (§3)
- [ ] Set all Edge Function secrets, deploy all 5 functions
- [ ] Point `supabaseClient.js` at production URL/anon key via build-time env injection
- [ ] Switch Razorpay from test keys to live keys, re-test the full checkout → verify → refund loop
- [ ] Confirm RLS denies unauthorized access for all 3 roles (§5.1)
- [ ] Load test at target concurrency, watch Supabase dashboard's DB/Realtime metrics
- [ ] Set up daily Supabase automated backups (Dashboard → Database → Backups)
- [ ] Configure custom domain + HTTPS for the web frontend
- [ ] Submit mobile builds to Play Store / App Store review
