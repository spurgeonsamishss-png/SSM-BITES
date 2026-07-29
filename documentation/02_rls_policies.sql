-- =========================================================================
-- SSM BITES — ROW LEVEL SECURITY POLICIES
-- Run AFTER 01_schema.sql
-- Model: every table has RLS enabled. Access is decided from user_roles,
-- resolved once per request via helper functions (STABLE + SECURITY DEFINER
-- so they can read user_roles even though RLS is on).
-- =========================================================================

-- ---------- Helper functions ----------
create or replace function current_role_name()
returns app_role
language sql stable security definer
as $$
  select role from user_roles where auth_id = auth.uid();
$$;

create or replace function current_student_id()
returns uuid
language sql stable security definer
as $$
  select id from students where auth_id = auth.uid();
$$;

create or replace function current_admin_id()
returns uuid
language sql stable security definer
as $$
  select id from admins where auth_id = auth.uid();
$$;

create or replace function is_super_admin()
returns boolean
language sql stable security definer
as $$
  select exists(select 1 from user_roles where auth_id = auth.uid() and role = 'super_admin');
$$;

create or replace function is_admin_or_super()
returns boolean
language sql stable security definer
as $$
  select exists(select 1 from user_roles where auth_id = auth.uid() and role in ('admin','super_admin'));
$$;

-- =========================================================================
-- IDENTITY TABLES
-- =========================================================================
alter table students enable row level security;
create policy "students_select_own" on students for select
  using (auth_id = auth.uid() or is_admin_or_super());
create policy "students_update_own" on students for update
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());
create policy "students_insert_self" on students for insert
  with check (auth_id = auth.uid());
create policy "super_admin_full_students" on students for all
  using (is_super_admin()) with check (is_super_admin());

alter table admins enable row level security;
create policy "admins_select_self_or_super" on admins for select
  using (auth_id = auth.uid() or is_super_admin());
create policy "admins_update_self" on admins for update
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());
-- Only Super Admin may create/delete Admin rows (enforced: no insert/delete
-- policy grants access to 'admin' role at all — only super_admin below).
create policy "super_admin_manage_admins" on admins for all
  using (is_super_admin()) with check (is_super_admin());

alter table super_admins enable row level security;
create policy "super_admin_self_only" on super_admins for all
  using (auth_id = auth.uid());

alter table user_roles enable row level security;
create policy "user_roles_select_self_or_super" on user_roles for select
  using (auth_id = auth.uid() or is_super_admin());
create policy "user_roles_super_admin_write" on user_roles for insert
  with check (is_super_admin());
create policy "user_roles_super_admin_update" on user_roles for update
  using (is_super_admin()) with check (is_super_admin());
create policy "user_roles_super_admin_delete" on user_roles for delete
  using (is_super_admin());

-- =========================================================================
-- MENU DOMAIN — everyone authenticated can read; only admin/super can write
-- =========================================================================
alter table food_categories enable row level security;
create policy "categories_read_all" on food_categories for select using (auth.uid() is not null);
create policy "categories_write_admin" on food_categories for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table menu_items enable row level security;
create policy "menu_items_read_all" on menu_items for select using (auth.uid() is not null);
create policy "menu_items_write_admin" on menu_items for insert with check (is_admin_or_super());
create policy "menu_items_update_admin" on menu_items for update
  using (is_admin_or_super()) with check (is_admin_or_super());
create policy "menu_items_delete_admin" on menu_items for delete using (is_admin_or_super());

alter table menu_images enable row level security;
create policy "menu_images_read_all" on menu_images for select using (auth.uid() is not null);
create policy "menu_images_write_admin" on menu_images for all
  using (is_admin_or_super()) with check (is_admin_or_super());

-- =========================================================================
-- STOCK
-- =========================================================================
alter table daily_stock enable row level security;
create policy "daily_stock_read_all" on daily_stock for select using (auth.uid() is not null);
create policy "daily_stock_write_admin" on daily_stock for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table stock_history enable row level security;
create policy "stock_history_read_admin" on stock_history for select using (is_admin_or_super());
create policy "stock_history_write_admin" on stock_history for insert with check (is_admin_or_super());

-- =========================================================================
-- CART — student owns their own cart only
-- =========================================================================
alter table cart enable row level security;
create policy "cart_owner_only" on cart for all
  using (student_id = current_student_id()) with check (student_id = current_student_id());

alter table cart_items enable row level security;
create policy "cart_items_owner_only" on cart_items for all
  using (cart_id in (select id from cart where student_id = current_student_id()))
  with check (cart_id in (select id from cart where student_id = current_student_id()));

-- =========================================================================
-- ORDERS / TOKENS / PAYMENTS
-- =========================================================================
alter table orders enable row level security;
create policy "orders_student_own" on orders for select
  using (student_id = current_student_id() or is_admin_or_super());
create policy "orders_student_insert" on orders for insert
  with check (student_id = current_student_id());
create policy "orders_admin_update_status" on orders for update
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table order_items enable row level security;
create policy "order_items_read" on order_items for select
  using (order_id in (select id from orders where student_id = current_student_id())
         or is_admin_or_super());
create policy "order_items_insert_owner" on order_items for insert
  with check (order_id in (select id from orders where student_id = current_student_id()));

alter table tokens enable row level security;
create policy "tokens_read" on tokens for select
  using (order_id in (select id from orders where student_id = current_student_id())
         or is_admin_or_super());
create policy "tokens_write_admin" on tokens for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table payments enable row level security;
create policy "payments_read_owner_or_admin" on payments for select
  using (order_id in (select id from orders where student_id = current_student_id())
         or is_admin_or_super());
create policy "payments_insert_owner" on payments for insert
  with check (order_id in (select id from orders where student_id = current_student_id()));
create policy "payments_update_admin_or_system" on payments for update
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table payment_history enable row level security;
create policy "payment_history_admin_only" on payment_history for select using (is_admin_or_super());

-- =========================================================================
-- REVIEWS / RATINGS / FEEDBACK
-- =========================================================================
alter table reviews enable row level security;
create policy "reviews_read_all" on reviews for select using (auth.uid() is not null);
create policy "reviews_insert_own_order" on reviews for insert
  with check (
    student_id = current_student_id()
    and order_id in (select id from orders where student_id = current_student_id() and status = 'collected')
  );
create policy "reviews_admin_read_all" on reviews for select using (is_admin_or_super());

alter table ratings enable row level security;
create policy "ratings_read_all" on ratings for select using (auth.uid() is not null);
create policy "ratings_system_write" on ratings for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table feedback enable row level security;
create policy "feedback_insert_self" on feedback for insert with check (auth_id = auth.uid());
create policy "feedback_read_admin" on feedback for select using (is_admin_or_super());

-- =========================================================================
-- NOTIFICATIONS
-- =========================================================================
alter table notifications enable row level security;
create policy "notifications_student_read" on notifications for select
  using (
    (channel = 'student' and recipient_id = current_student_id())
    or (channel = 'admin' and is_admin_or_super())
    or (channel = 'super_admin' and is_super_admin())
  );
create policy "notifications_student_mark_read" on notifications for update
  using (channel = 'student' and recipient_id = current_student_id())
  with check (channel = 'student' and recipient_id = current_student_id());
create policy "notifications_system_insert" on notifications for insert
  with check (is_admin_or_super() or auth.role() = 'service_role');

alter table devices enable row level security;
create policy "devices_owner_only" on devices for all
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());

-- =========================================================================
-- SETTINGS / SESSIONS
-- =========================================================================
alter table theme_settings enable row level security;
create policy "theme_settings_owner" on theme_settings for all
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());

alter table profile_settings enable row level security;
create policy "profile_settings_owner" on profile_settings for all
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());

alter table sessions enable row level security;
create policy "sessions_owner_read" on sessions for select using (auth_id = auth.uid() or is_super_admin());
create policy "sessions_owner_write" on sessions for insert with check (auth_id = auth.uid());
create policy "sessions_owner_revoke" on sessions for update
  using (auth_id = auth.uid()) with check (auth_id = auth.uid());

-- =========================================================================
-- OFFERS / BANNERS / FAVORITES
-- =========================================================================
alter table offers enable row level security;
create policy "offers_read_all" on offers for select using (auth.uid() is not null);
create policy "offers_write_admin" on offers for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table banners enable row level security;
create policy "banners_read_all" on banners for select using (auth.uid() is not null);
create policy "banners_write_admin" on banners for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table favorites enable row level security;
create policy "favorites_owner_only" on favorites for all
  using (student_id = current_student_id()) with check (student_id = current_student_id());

-- =========================================================================
-- REPORTING / ANALYTICS / LOGS — admin & super admin visibility only
-- =========================================================================
alter table sales_reports enable row level security;
create policy "sales_reports_admin_read" on sales_reports for select using (is_admin_or_super());
create policy "sales_reports_system_write" on sales_reports for all
  using (is_super_admin()) with check (is_super_admin());

alter table analytics enable row level security;
create policy "analytics_insert_self" on analytics for insert with check (auth.uid() is not null);
create policy "analytics_admin_read" on analytics for select using (is_admin_or_super());

alter table activity_logs enable row level security;
create policy "activity_logs_admin_read" on activity_logs for select using (is_admin_or_super());
create policy "activity_logs_insert_self" on activity_logs for insert with check (auth.uid() is not null);

alter table system_logs enable row level security;
create policy "system_logs_super_admin_only" on system_logs for select using (is_super_admin());

-- =========================================================================
-- ORDER WINDOW / CANTEEN SETTINGS — read for all authenticated, write admin
-- =========================================================================
alter table order_window enable row level security;
create policy "order_window_read_all" on order_window for select using (auth.uid() is not null);
create policy "order_window_write_admin" on order_window for all
  using (is_admin_or_super()) with check (is_admin_or_super());

alter table canteen_settings enable row level security;
create policy "canteen_settings_read_all" on canteen_settings for select using (auth.uid() is not null);
create policy "canteen_settings_write_admin" on canteen_settings for update
  using (is_admin_or_super()) with check (is_admin_or_super());
