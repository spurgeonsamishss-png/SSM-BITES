// SSM BITES — Edge Function: razorpay-refund
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RAZORPAY_KEY_ID = Deno.env.get('RAZORPAY_KEY_ID')!;
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

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: roleRow } = await admin.from('user_roles').select('role').eq('auth_id', userData.user.id).single();
    if (!['admin', 'super_admin'].includes(roleRow?.role)) return json({ ok: false, message: 'Admin only' }, 403);

    const { paymentId, reason } = await req.json();
    const { data: payment, error: payErr } = await admin.from('payments').select('*').eq('id', paymentId).single();
    if (payErr || !payment?.provider_payment_id) return json({ ok: false, message: 'Payment not found or not captured' }, 404);

    const basicAuth = btoa(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`);
    const rpResp = await fetch(`https://api.razorpay.com/v1/payments/${payment.provider_payment_id}/refund`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Basic ${basicAuth}` },
      body: JSON.stringify({ notes: { reason } }),
    });
    const refund = await rpResp.json();
    if (!rpResp.ok) return json({ ok: false, message: refund.error?.description || 'Refund failed' }, 400);

    await admin.from('payments').update({ status: 'refunded' }).eq('id', paymentId);
    await admin.from('payment_history').insert({ payment_id: paymentId, event_type: 'refunded', raw_payload: refund });

    return json({ ok: true, refund });
  } catch (e) {
    return json({ ok: false, message: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}
