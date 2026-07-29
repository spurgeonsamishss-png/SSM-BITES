// =========================================================================
// SSM BITES — Supabase client bootstrap
// Load via <script type="module" src="/backend/supabaseClient.js"></script>
// or import { supabase } from './supabaseClient.js' in a bundler setup.
// =========================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Never hardcode the anon key in a committed file in real production —
// inject these via your build tool (Vite: import.meta.env.VITE_SUPABASE_URL)
// or a small server-rendered <script> tag that reads process.env at deploy time.
const SUPABASE_URL = window.__ENV__?.SUPABASE_URL || 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = window.__ENV__?.SUPABASE_ANON_KEY || 'YOUR_PUBLIC_ANON_KEY';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,       // keeps the student/admin logged in across refreshes
    autoRefreshToken: true,     // silently refreshes the JWT before it expires
    detectSessionInUrl: true,
  },
  realtime: {
    params: { eventsPerSecond: 10 },
  },
});

// Service-role client — NEVER ship this to the browser. It belongs only in
// Edge Functions / a trusted backend (e.g. for admin-account creation,
// Razorpay webhook verification, sending push notifications).
// export const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
