// =========================================================================
// SSM BITES — API LAYER
// One function per existing frontend need. Import what you need into the
// HTML's <script> and swap the in-memory `state.foods/orders/reviews/...`
// reads/writes for calls into this file. Function names below intentionally
// mirror the concepts already used in the app (renderMenu, addToCart,
// confirmOrder, renderAdminOrders, renderSuperDashboard, etc).
// =========================================================================
import { supabase } from './supabaseClient.js';

/* ---------------------------------------------------------------------- */
/* MENU                                                                    */
/* ---------------------------------------------------------------------- */

export async function fetchMenu() {
  const { data, error } = await supabase
    .from('menu_items')
    .select(`
      id, name, description, price, is_veg, emoji_icon, qty_enabled,
      status, rating, rating_count,
      category:food_categories(name),
      images:menu_images(storage_path, is_primary),
      daily_stock!left(remaining_qty, stock_date)
    `)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

export async function fetchCategories() {
  const { data, error } = await supabase.from('food_categories').select('*').order('sort_order');
  if (error) throw error;
  return data;
}

export async function createMenuItem(payload) {
  // payload: { name, description, price, category_id, is_veg, emoji_icon, qty_enabled }
  const { data: user } = await supabase.auth.getUser();
  const { data: admin } = await supabase.from('admins').select('id').eq('auth_id', user.user.id).single();
  const { data, error } = await supabase
    .from('menu_items')
    .insert({ ...payload, created_by: admin.id })
    .select()
    .single();
  if (error) throw error;

  if (payload.qty_enabled) {
    await supabase.from('daily_stock').insert({
      menu_item_id: data.id, stock_date: new Date().toISOString().slice(0, 10),
      opening_qty: payload.qty, remaining_qty: payload.qty,
    });
  }
  return data;
}

export async function updateMenuItem(id, payload) {
  const { data, error } = await supabase.from('menu_items').update(payload).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

export async function deleteMenuItem(id) {
  const { error } = await supabase.from('menu_items').delete().eq('id', id);
  if (error) throw error;
}

export async function uploadFoodImage(menuItemId, file) {
  const path = `${menuItemId}/${Date.now()}_${file.name}`;
  const { error: upErr } = await supabase.storage.from('food-images').upload(path, file);
  if (upErr) throw upErr;
  const { data: pub } = supabase.storage.from('food-images').getPublicUrl(path);
  await supabase.from('menu_images').insert({ menu_item_id: menuItemId, storage_path: path, is_primary: true });
  return pub.publicUrl;
}

/* ---------------------------------------------------------------------- */
/* ORDER WINDOW / CANTEEN SETTINGS                                         */
/* ---------------------------------------------------------------------- */

export async function fetchOrderingWindow() {
  const { data: settings } = await supabase.from('canteen_settings').select('*').single();
  if (settings.admin_window_override) return { open: true, label: 'Admin Override', closesAt: '—' };

  const { data: windows } = await supabase.from('order_window').select('*').eq('is_active', true);
  const now = new Date();
  const mins = now.getHours() * 60 + now.getMinutes();
  for (const w of windows) {
    const [sh, sm] = w.start_time.split(':').map(Number);
    const [eh, em] = w.end_time.split(':').map(Number);
    const start = sh * 60 + sm, end = eh * 60 + em;
    if (mins >= start && mins <= end) return { open: true, label: w.label, closesAt: w.end_time };
  }
  const next = windows.find(w => {
    const [sh, sm] = w.start_time.split(':').map(Number);
    return mins < sh * 60 + sm;
  }) || windows[0];
  return { open: false, label: next.label, opensAt: next.start_time };
}

export async function toggleAdminWindowOverride() {
  const { data: settings } = await supabase.from('canteen_settings').select('*').single();
  const { error } = await supabase
    .from('canteen_settings')
    .update({ admin_window_override: !settings.admin_window_override })
    .eq('id', 1);
  if (error) throw error;
  return !settings.admin_window_override;
}

/* ---------------------------------------------------------------------- */
/* CART                                                                     */
/* ---------------------------------------------------------------------- */

export async function getOrCreateCart(studentId) {
  let { data: cart } = await supabase.from('cart').select('*').eq('student_id', studentId).maybeSingle();
  if (!cart) {
    const { data, error } = await supabase.from('cart').insert({ student_id: studentId }).select().single();
    if (error) throw error;
    cart = data;
  }
  return cart;
}

export async function addToCart(studentId, menuItemId, qty = 1) {
  const cart = await getOrCreateCart(studentId);
  const { data: existing } = await supabase
    .from('cart_items').select('*').eq('cart_id', cart.id).eq('menu_item_id', menuItemId).maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('cart_items').update({ quantity: existing.quantity + qty }).eq('id', existing.id);
    if (error) throw error;
  } else {
    const { error } = await supabase
      .from('cart_items').insert({ cart_id: cart.id, menu_item_id: menuItemId, quantity: qty });
    if (error) throw error;
  }
}

export async function decCartItem(studentId, menuItemId) {
  const cart = await getOrCreateCart(studentId);
  const { data: existing } = await supabase
    .from('cart_items').select('*').eq('cart_id', cart.id).eq('menu_item_id', menuItemId).maybeSingle();
  if (!existing) return;
  if (existing.quantity <= 1) {
    await supabase.from('cart_items').delete().eq('id', existing.id);
  } else {
    await supabase.from('cart_items').update({ quantity: existing.quantity - 1 }).eq('id', existing.id);
  }
}

export async function fetchCart(studentId) {
  const cart = await getOrCreateCart(studentId);
  const { data, error } = await supabase
    .from('cart_items')
    .select('quantity, menu_item:menu_items(id, name, price, emoji_icon)')
    .eq('cart_id', cart.id);
  if (error) throw error;
  return data;
}

export async function clearCart(studentId) {
  const cart = await getOrCreateCart(studentId);
  await supabase.from('cart_items').delete().eq('cart_id', cart.id);
}

/* ---------------------------------------------------------------------- */
/* CHECKOUT / ORDERS / TOKENS                                              */
/* ---------------------------------------------------------------------- */

/**
 * Places the order via a single Postgres RPC (atomic — avoids partial
 * writes if stock runs out mid-checkout). See functions_triggers.sql /
 * the `place_order` function referenced in ARCHITECTURE.md for the
 * transactional version; this client call wraps it.
 */
export async function checkout(studentId, payMethod) {
  const { data, error } = await supabase.rpc('place_order', {
    p_student_id: studentId,
    p_pay_method: payMethod,
  });
  if (error) throw error;
  return data; // { order_id, token_number, total_amount }
}

export async function fetchStudentOrders(studentId, tab = 'active') {
  const activeStatuses = ['received', 'preparing', 'ready_for_pickup'];
  let query = supabase
    .from('orders')
    .select('*, order_items(item_name, quantity, unit_price)')
    .eq('student_id', studentId)
    .order('placed_at', { ascending: false });

  query = tab === 'active' ? query.in('status', activeStatuses) : query.in('status', ['collected', 'cancelled']);
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

export async function fetchAdminOrders(statusFilter = 'all') {
  let query = supabase
    .from('orders')
    .select('*, order_items(item_name, quantity, unit_price), student:students(roll_number)')
    .order('placed_at', { ascending: false });
  if (statusFilter !== 'all') query = query.eq('status', statusFilter);
  const { data, error } = await query;
  if (error) throw error;
  return data;
}

export async function updateOrderStatus(orderId, status) {
  const { error } = await supabase.from('orders').update({ status }).eq('id', orderId);
  if (error) throw error;
}

/* ---------------------------------------------------------------------- */
/* PAYMENTS (Razorpay)                                                     */
/* ---------------------------------------------------------------------- */

/** Step 1 — ask the Edge Function to create a Razorpay order (server-side,
 *  keeps your Razorpay key secret off the client). */
export async function createRazorpayOrder(orderId, amount) {
  const { data: sessionData } = await supabase.auth.getSession();
  const resp = await fetch(`${supabase.supabaseUrl}/functions/v1/razorpay-create-order`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${sessionData.session.access_token}` },
    body: JSON.stringify({ orderId, amount }),
  });
  return resp.json(); // { razorpayOrderId, keyId }
}

/** Step 2 — after Razorpay Checkout.js succeeds client-side, verify the
 *  signature server-side (never trust the client-reported "success"). */
export async function verifyRazorpayPayment(payload) {
  const { data: sessionData } = await supabase.auth.getSession();
  const resp = await fetch(`${supabase.supabaseUrl}/functions/v1/razorpay-verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${sessionData.session.access_token}` },
    body: JSON.stringify(payload),
  });
  return resp.json(); // { ok, status }
}

export async function requestRefund(paymentId, reason) {
  const { data: sessionData } = await supabase.auth.getSession();
  const resp = await fetch(`${supabase.supabaseUrl}/functions/v1/razorpay-refund`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${sessionData.session.access_token}` },
    body: JSON.stringify({ paymentId, reason }),
  });
  return resp.json();
}

/* ---------------------------------------------------------------------- */
/* REVIEWS                                                                  */
/* ---------------------------------------------------------------------- */

export async function submitReview(orderId, studentId, menuItemId, rating, text) {
  const { error } = await supabase
    .from('reviews')
    .insert({ order_id: orderId, student_id: studentId, menu_item_id: menuItemId, rating, review_text: text });
  if (error) throw error;
}

export async function fetchStudentReviews(studentId) {
  const { data, error } = await supabase
    .from('reviews')
    .select('*, menu_item:menu_items(name)')
    .eq('student_id', studentId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

export async function fetchMenuItemReviews(menuItemId, limit = 2) {
  const { data, error } = await supabase
    .from('reviews')
    .select('*, student:students(roll_number)')
    .eq('menu_item_id', menuItemId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}

/* ---------------------------------------------------------------------- */
/* NOTIFICATIONS (realtime)                                                */
/* ---------------------------------------------------------------------- */

export async function fetchNotifications(channel, recipientId) {
  const { data, error } = await supabase
    .from('notifications')
    .select('*')
    .eq('channel', channel)
    .or(recipientId ? `recipient_id.eq.${recipientId},recipient_id.is.null` : 'recipient_id.is.null')
    .order('created_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  return data;
}

export async function markNotificationsRead(ids) {
  const { error } = await supabase.from('notifications').update({ is_read: true }).in('id', ids);
  if (error) throw error;
}

/** Call once after login; invoke `onNotification(payload)` for toasts/badges. */
export function subscribeToNotifications(channel, recipientId, onNotification) {
  return supabase
    .channel(`notifications-${channel}-${recipientId || 'broadcast'}`)
    .on('postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'notifications', filter: `channel=eq.${channel}` },
      (payload) => {
        const n = payload.new;
        if (!n.recipient_id || n.recipient_id === recipientId) onNotification(n);
      })
    .subscribe();
}

/** Realtime order-status updates for the student's "My Orders" screen. */
export function subscribeToOrderUpdates(studentId, onUpdate) {
  return supabase
    .channel(`orders-${studentId}`)
    .on('postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'orders', filter: `student_id=eq.${studentId}` },
      (payload) => onUpdate(payload.new))
    .subscribe();
}

/** Realtime new-order feed for the admin "Live Orders" screen. */
export function subscribeToNewOrders(onNewOrder) {
  return supabase
    .channel('admin-new-orders')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'orders' }, (payload) => onNewOrder(payload.new))
    .subscribe();
}

/* ---------------------------------------------------------------------- */
/* ADMIN DASHBOARD                                                          */
/* ---------------------------------------------------------------------- */

export async function fetchAdminDashboardStats() {
  const today = new Date().toISOString().slice(0, 10);
  const { data: orders } = await supabase.from('orders').select('status, total_amount').eq('order_date', today);
  const revenue = orders.filter(o => o.status !== 'cancelled').reduce((s, o) => s + Number(o.total_amount), 0);
  return {
    revenue,
    totalOrders: orders.length,
    preparing: orders.filter(o => o.status === 'preparing').length,
    ready: orders.filter(o => o.status === 'ready_for_pickup').length,
  };
}

export async function fetchLowStock() {
  const today = new Date().toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from('daily_stock')
    .select('remaining_qty, menu_item:menu_items(id, name, emoji_icon)')
    .eq('stock_date', today)
    .gt('remaining_qty', 0)
    .lte('remaining_qty', 5);
  if (error) throw error;
  return data;
}

export async function fetchTopSelling(limit = 5) {
  const { data, error } = await supabase.rpc('top_selling_items', { p_limit: limit });
  if (error) throw error;
  return data;
}

/* ---------------------------------------------------------------------- */
/* SUPER ADMIN                                                              */
/* ---------------------------------------------------------------------- */

export async function fetchSuperAdminStats() {
  const { data: orders } = await supabase.from('orders').select('status, total_amount, order_items(quantity)');
  const valid = orders.filter(o => o.status !== 'cancelled');
  return {
    totalSales: valid.length,
    totalOrders: orders.length,
    totalRevenue: valid.reduce((s, o) => s + Number(o.total_amount), 0),
    totalItemsSold: valid.reduce((s, o) => s + o.order_items.reduce((si, i) => si + i.quantity, 0), 0),
  };
}

export async function fetchRevenueByPeriod(period) {
  // period: 'daily' | 'weekly' | 'monthly' — backed by the sales_reports rollup table
  const days = period === 'daily' ? 1 : period === 'weekly' ? 7 : 30;
  const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
  const { data, error } = await supabase.from('sales_reports').select('*').gte('report_date', since);
  if (error) throw error;
  return data.reduce((s, r) => s + Number(r.total_revenue), 0);
}

export async function fetchAdminAccounts() {
  const { data, error } = await supabase.from('admins').select('id, auth_id, username, is_active, created_at');
  if (error) throw error;
  return data;
}

export async function deleteAdminAccount(adminId) {
  const { error } = await supabase.from('admins').delete().eq('id', adminId);
  if (error) throw error; // cascades to user_roles via auth_id FK on the auth.users row cleanup (Edge Function)
}

/* ---------------------------------------------------------------------- */
/* PROFILE / SETTINGS                                                       */
/* ---------------------------------------------------------------------- */

export async function fetchTheme(authId) {
  const { data } = await supabase.from('theme_settings').select('theme').eq('auth_id', authId).maybeSingle();
  return data?.theme || 'light';
}

export async function setTheme(authId, theme) {
  const { error } = await supabase.from('theme_settings').upsert({ auth_id: authId, theme, updated_at: new Date() });
  if (error) throw error;
}

export async function updateStudentProfile(studentId, payload) {
  const { error } = await supabase.from('students').update(payload).eq('id', studentId);
  if (error) throw error;
}
