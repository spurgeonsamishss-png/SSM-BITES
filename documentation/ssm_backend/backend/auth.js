// =========================================================================
// SSM BITES — AUTH MODULE
// Replaces STUDENT_ACCOUNTS / ADMIN_ACCOUNTS / SUPER_ADMIN_ACCOUNT arrays.
//
// Design: Supabase Auth owns the credential (email + hashed password + JWT).
// A student's "roll number" is mapped to a synthetic internal email
// (e.g. 922125149043@students.ssmbites.app) so the existing "log in with
// roll number" UX is fully preserved while still using Supabase Auth's
// battle-tested password hashing (bcrypt) and JWT session issuance.
// =========================================================================
import { supabase } from './supabaseClient.js';

function rollToEmail(roll) {
  return `${roll.toLowerCase()}@students.ssmbites.app`;
}
function usernameToEmail(username) {
  return `${username.toLowerCase()}@staff.ssmbites.app`;
}

/**
 * Unified login — mirrors the original attemptLogin() UX (single roll/
 * username + password field), but now resolves against Supabase Auth
 * and the user_roles table instead of hardcoded arrays.
 */
export async function login(identifier, password) {
  const lower = identifier.trim().toLowerCase();
  const email = /^\d+$/.test(lower) ? rollToEmail(lower) : usernameToEmail(lower);

  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    return { ok: false, message: humanizeAuthError(error) };
  }

  const { data: roleRow, error: roleErr } = await supabase
    .from('user_roles')
    .select('role, ref_id')
    .eq('auth_id', data.user.id)
    .single();

  if (roleErr || !roleRow) {
    await supabase.auth.signOut();
    return { ok: false, message: 'Account has no assigned role. Contact Super Admin.' };
  }

  return { ok: true, role: roleRow.role, refId: roleRow.ref_id, session: data.session, user: data.user };
}

export async function logout() {
  await supabase.auth.signOut();
}

/** Persistent-login check on app boot — call before showing splash->login. */
export async function getActiveSession() {
  const { data } = await supabase.auth.getSession();
  if (!data.session) return null;

  const { data: roleRow } = await supabase
    .from('user_roles')
    .select('role, ref_id')
    .eq('auth_id', data.session.user.id)
    .single();

  return roleRow ? { session: data.session, role: roleRow.role, refId: roleRow.ref_id } : null;
}

/** Student self-registration (if you want open signup by roll number). */
export async function registerStudent(roll, password, fullName) {
  const email = rollToEmail(roll);
  const { data, error } = await supabase.auth.signUp({ email, password });
  if (error) return { ok: false, message: humanizeAuthError(error) };

  const { data: student, error: insErr } = await supabase
    .from('students')
    .insert({ auth_id: data.user.id, roll_number: roll, full_name: fullName })
    .select()
    .single();
  if (insErr) return { ok: false, message: insErr.message };

  await supabase.from('user_roles').insert({ auth_id: data.user.id, role: 'student', ref_id: student.id });
  return { ok: true, student };
}

/**
 * Admin account creation — MUST be called from an authenticated Super
 * Admin session. The actual auth.users row + password should be created
 * server-side (Edge Function using the service-role key) because the
 * anon/public client cannot set another user's password directly.
 * This function calls that Edge Function.
 */
export async function createAdminAccount(username, password, fullName) {
  const { data: sessionData } = await supabase.auth.getSession();
  const resp = await fetch(`${supabase.supabaseUrl}/functions/v1/admin-create`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${sessionData.session.access_token}`,
    },
    body: JSON.stringify({ username, password, fullName }),
  });
  return resp.json(); // { ok, admin } or { ok:false, message }
}

/** Super Admin resets an admin's password — also an Edge Function call. */
export async function resetAdminPassword(adminAuthId, newPassword) {
  const { data: sessionData } = await supabase.auth.getSession();
  const resp = await fetch(`${supabase.supabaseUrl}/functions/v1/admin-reset-password`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${sessionData.session.access_token}`,
    },
    body: JSON.stringify({ adminAuthId, newPassword }),
  });
  return resp.json();
}

export async function forgotPassword(identifier) {
  const lower = identifier.trim().toLowerCase();
  const email = /^\d+$/.test(lower) ? rollToEmail(lower) : usernameToEmail(lower);
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${window.location.origin}/reset-password.html`,
  });
  return error ? { ok: false, message: error.message } : { ok: true };
}

export async function updatePassword(newPassword) {
  const { error } = await supabase.auth.updateUser({ password: newPassword });
  return error ? { ok: false, message: error.message } : { ok: true };
}

function humanizeAuthError(error) {
  if (error.message.includes('Invalid login credentials')) return 'Invalid roll number/username or password';
  return error.message;
}

// Keep Supabase Auth session in sync with any other open tab/device.
supabase.auth.onAuthStateChange((_event, _session) => {
  // Hook this up to your app's state re-sync / logout-elsewhere logic.
});
