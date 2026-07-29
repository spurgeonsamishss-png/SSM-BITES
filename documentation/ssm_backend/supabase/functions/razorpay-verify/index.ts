// SSM BITES — Edge Function: razorpay-verify
// Verifies the HMAC-SHA256 signature Razorpay returns to Checkout.js on the
// client, per Razorpay's documented verification scheme:
//   expected = HMAC_SHA256(razorpay_order_id + "|" + razorpay_payment_id, KEY_SECRET)
// Only marks the order paid if expected === razorpay_signature.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { crypto } from 'https://deno.land/std@0.224.0/crypto/mod.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET')!;

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const caller = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData.user) return json({ ok: false, message: 'Unauthorized' }, 401);

    const { orderId, razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();

    const expected = await hmacSha256Hex(RAZORPAY_KEY_SECRET, `${razorpay_order_id}|${razorpay_payment_id}`);
    if (expected !== razorpay_signature) {
      const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
      await admin.from('payments').update({ status: 'failed' }).eq('order_id', orderId);
      await admin.from('system_logs').insert({ severity: 'warning', source: 'payment', message: 'Signature mismatch', metadata: { orderId } });
      return json({ ok: false, message: 'Signature verification failed' }, 400);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    await admin.rpc('mark_payment_success', {
      p_order_id: orderId,
      p_provider_order_id: razorpay_order_id,
      p_provider_payment_id: razorpay_payment_id,
      p_provider_signature: razorpay_signature,
    });

    return json({ ok: true, status: 'success' });
  } catch (e) {
    return json({ ok: false, message: String(e) }, 500);
  }
});

async function hmacSha256Hex(secret: string, message: string) {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}
