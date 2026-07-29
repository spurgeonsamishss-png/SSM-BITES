// SSM BITES — Edge Function: admin-create
// Deploy: supabase functions deploy admin-create

import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  // Handle browser CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders,
    });
  }

  try {
    // Verify the caller using their JWT
    const authHeader = req.headers.get('Authorization') ?? '';

    const callerClient = createClient(
      SUPABASE_URL,
      SERVICE_ROLE_KEY,
      {
        global: {
          headers: {
            Authorization: authHeader,
          },
        },
      }
    );

    const { data: userData, error: userErr } =
      await callerClient.auth.getUser();

    if (userErr || !userData.user) {
      return json(
        {
          ok: false,
          message: 'Unauthorized',
        },
        401
      );
    }

    // Service role client
    const admin = createClient(
      SUPABASE_URL,
      SERVICE_ROLE_KEY
    );

    // Ensure caller is Super Admin
    const { data: roleRow, error: roleErr } = await admin
      .from('user_roles')
      .select('role')
      .eq('auth_id', userData.user.id)
      .single();

    if (roleErr) {
      return json(
        {
          ok: false,
          message: roleErr.message,
        },
        400
      );
    }

    if (roleRow?.role !== 'super_admin') {
      return json(
        {
          ok: false,
          message: 'Super Admin only',
        },
        403
      );
    }

    // Read request body
    const { username, password, fullName } = await req.json();

    if (!username || !password) {
      return json(
        {
          ok: false,
          message: 'Username and password are required.',
        },
        400
      );
    }

    const email =
      `${username.toLowerCase()}@staff.ssmbites.app`;

    // Create Auth user
    const { data: newUser, error: createErr } =
      await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

    if (createErr) {
      return json(
        {
          ok: false,
          message: createErr.message,
        },
        400
      );
    }

    // Insert admin profile
    const { data: adminRow, error: insertErr } =
      await admin
        .from('admins')
        .insert({
          auth_id: newUser.user.id,
          username: username.toLowerCase(),
          full_name: fullName ?? username,
          created_by: userData.user.id,
        })
        .select()
        .single();

    if (insertErr) {
      return json(
        {
          ok: false,
          message: insertErr.message,
        },
        400
      );
    }

    // Assign role
    const { error: roleInsertErr } = await admin
      .from('user_roles')
      .insert({
        auth_id: newUser.user.id,
        role: 'admin',
        ref_id: adminRow.id,
      });

    if (roleInsertErr) {
      return json(
        {
          ok: false,
          message: roleInsertErr.message,
        },
        400
      );
    }

    // Activity log
    await admin.from('activity_logs').insert({
      auth_id: userData.user.id,
      action: 'admin_account_created',
      entity_type: 'admins',
      entity_id: adminRow.id,
    });

    return json({
      ok: true,
      admin: adminRow,
    });

  } catch (err) {
    console.error(err);

    return json(
      {
        ok: false,
        message:
          err instanceof Error ? err.message : String(err),
      },
      500
    );
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders,
    },
  });
}