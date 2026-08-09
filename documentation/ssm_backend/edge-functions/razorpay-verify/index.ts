// SSM BITES — Edge Function: razorpay-verify (updated for Snacks/Lunch split)
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { crypto } from 'https://deno.land/std@0.224.0/crypto/mod.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const caller = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData.user) return json({ ok: false, message: 'Unauthorized' }, 401);

    const { orderId, razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();

    const expected = await hmacSha256Hex(RAZORPAY_KEY_SECRET, `${razorpay_order_id}|${razorpay_payment_id}`);
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    if (expected !== razorpay_signature) {
      // Signature failed — payment is not trustworthy. Mark it failed AND
      // cancel the pending order immediately rather than leaving it to expire.
      await admin.from('payments').update({ status: 'failed' }).eq('order_id', orderId);
      await admin.from('orders').update({ status: 'cancelled', cancelled_at: new Date().toISOString() })
        .eq('id', orderId).eq('status', 'pending_payment');
      await admin.from('system_logs').insert({ severity: 'warning', source: 'payment', message: 'Signature mismatch', metadata: { orderId } });
      return json({ ok: false, message: 'Signature verification failed' }, 400);
    }

    const { data: confirmResult, error: confirmErr } = await admin.rpc('confirm_order_payment', {
      p_order_id: orderId,
      p_provider_order_id: razorpay_order_id,
      p_provider_payment_id: razorpay_payment_id,
      p_provider_signature: razorpay_signature,
    });
    if (confirmErr) return json({ ok: false, message: confirmErr.message }, 500);

    const row = confirmResult?.[0];
    return json({ ok: true, status: 'success', tokenNumber: row?.token_number, orderCategory: row?.order_category });
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
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}
