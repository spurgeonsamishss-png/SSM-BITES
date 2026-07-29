// SSM BITES — Edge Function: admin-reset-password
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData.user) return json({ ok: false, message: 'Unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: roleRow } = await admin
      .from('user_roles').select('role').eq('auth_id', userData.user.id).single();
    if (roleRow?.role !== 'super_admin') return json({ ok: false, message: 'Super Admin only' }, 403);

    const { adminAuthId, newPassword } = await req.json();
    if (!adminAuthId || !newPassword) return json({ ok: false, message: 'adminAuthId and newPassword required' }, 400);

    const { error } = await admin.auth.admin.updateUserById(adminAuthId, { password: newPassword });
    if (error) return json({ ok: false, message: error.message }, 400);

    await admin.from('activity_logs').insert({
      auth_id: userData.user.id, action: 'admin_password_reset', entity_type: 'admins', entity_id: adminAuthId,
    });

    return json({ ok: true });
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