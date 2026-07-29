// SSM BITES — Edge Function: razorpay-create-order
// Secrets required (set via `supabase secrets set`):
//   RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RAZORPAY_KEY_ID = Deno.env.get('RAZORPAY_KEY_ID')!;
const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET')!;

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const caller = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: userData, error: userErr } = await caller.auth.getUser();
    if (userErr || !userData.user) return json({ ok: false, message: 'Unauthorized' }, 401);

    const { orderId, amount } = await req.json();
    if (!orderId || !amount) return json({ ok: false, message: 'orderId and amount required' }, 400);

    // Never trust a client-supplied amount blindly — re-verify against the DB.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: order, error: orderErr } = await admin
      .from('orders').select('total_amount, student_id, students!inner(auth_id)').eq('id', orderId).single();
    if (orderErr || !order) return json({ ok: false, message: 'Order not found' }, 404);
    if (order.students.auth_id !== userData.user.id) return json({ ok: false, message: 'Forbidden' }, 403);
    if (Number(order.total_amount) !== Number(amount)) return json({ ok: false, message: 'Amount mismatch' }, 400);

    const basicAuth = btoa(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`);
    const rpResp = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Basic ${basicAuth}` },
      body: JSON.stringify({
        amount: Math.round(amount * 100), // paise
        currency: 'INR',
        receipt: orderId,
        notes: { ssm_order_id: orderId },
      }),
    });
    const rpOrder = await rpResp.json();
    if (!rpResp.ok) return json({ ok: false, message: rpOrder.error?.description || 'Razorpay error' }, 400);

    await admin.from('payments').update({ provider_order_id: rpOrder.id }).eq('order_id', orderId);
    await admin.from('payment_history').insert({
      payment_id: (await admin.from('payments').select('id').eq('order_id', orderId).single()).data.id,
      event_type: 'created', raw_payload: rpOrder,
    });

    return json({ ok: true, razorpayOrderId: rpOrder.id, keyId: RAZORPAY_KEY_ID, amount: rpOrder.amount });
  } catch (e) {
    return json({ ok: false, message: String(e) }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}
