-- =========================================================================
-- SSM BITES — PRODUCTION DATABASE SCHEMA
-- Target: Supabase (PostgreSQL 15+)
-- Run order: 01_schema.sql -> 02_rls_policies.sql -> 03_storage_buckets.sql
-- =========================================================================

create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- =========================================================================
-- SHARED HELPERS
-- =========================================================================

-- Generic updated_at trigger
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- Role enum used across auth-adjacent tables
create type app_role as enum ('student','admin','super_admin');
create type order_status as enum ('received','preparing','ready_for_pickup','collected','cancelled');
create type payment_status as enum ('initiated','success','failed','refunded');
create type payment_method as enum ('upi','google_pay','phonepe','paytm','debit_card','credit_card','cash','qr_code');
create type notification_channel as enum ('student','admin','super_admin');

-- =========================================================================
-- 1. IDENTITY / ROLE TABLES
-- Every human user has a row in auth.users (Supabase Auth). These tables
-- hold the role-specific profile and are linked 1:1 via auth_id.
-- =========================================================================

create table students (
  id              uuid primary key default uuid_generate_v4(),
  auth_id         uuid not null unique references auth.users(id) on delete cascade,
  roll_number     text not null unique,
  full_name       text,
  email           text unique,
  phone           text,
  profile_image_url text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_students_roll on students(roll_number);
create trigger trg_students_updated before update on students
  for each row execute function set_updated_at();

create table admins (
  id              uuid primary key default uuid_generate_v4(),
  auth_id         uuid not null unique references auth.users(id) on delete cascade,
  username        text not null unique,
  full_name       text,
  email           text unique,
  profile_image_url text,
  created_by      uuid references auth.users(id),  -- which super admin created this account
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_admins_username on admins(username);
create trigger trg_admins_updated before update on admins
  for each row execute function set_updated_at();

create table super_admins (
  id              uuid primary key default uuid_generate_v4(),
  auth_id         uuid not null unique references auth.users(id) on delete cascade,
  username        text not null unique,
  full_name       text,
  email           text unique,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create trigger trg_super_admins_updated before update on super_admins
  for each row execute function set_updated_at();

-- Fast role lookup used by RLS policies (avoids hitting 3 tables per check)
create table user_roles (
  auth_id  uuid primary key references auth.users(id) on delete cascade,
  role     app_role not null,
  ref_id   uuid not null   -- points at students.id / admins.id / super_admins.id
);
create index idx_user_roles_role on user_roles(role);

-- =========================================================================
-- 2. MENU DOMAIN
-- =========================================================================

create table food_categories (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null unique,      -- Veg / Non-Veg / Snacks / Beverages / Desserts
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

create table menu_items (
  id              uuid primary key default uuid_generate_v4(),
  category_id     uuid not null references food_categories(id) on delete restrict,
  name            text not null,
  description     text,
  price           numeric(10,2) not null check (price > 0),
  is_veg          boolean not null default true,
  emoji_icon      text default '🍽️',
  qty_enabled     boolean not null default false,
  status          text not null default 'active' check (status in ('active','inactive')),
  rating          numeric(2,1) not null default 0,
  rating_count    int not null default 0,
  created_by      uuid references admins(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_menu_items_category on menu_items(category_id);
create index idx_menu_items_status on menu_items(status);
create index idx_menu_items_name_trgm on menu_items using gin (name gin_trgm_ops);
create trigger trg_menu_items_updated before update on menu_items
  for each row execute function set_updated_at();

create table menu_images (
  id            uuid primary key default uuid_generate_v4(),
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  storage_path  text not null,           -- path inside Supabase Storage bucket
  is_primary    boolean not null default true,
  created_at    timestamptz not null default now()
);
create index idx_menu_images_item on menu_images(menu_item_id);

-- =========================================================================
-- 3. STOCK / DAILY INVENTORY
-- =========================================================================

create table daily_stock (
  id            uuid primary key default uuid_generate_v4(),
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  stock_date    date not null default current_date,
  opening_qty   int not null default 0,
  remaining_qty int not null default 0,
  updated_at    timestamptz not null default now(),
  unique(menu_item_id, stock_date)
);
create index idx_daily_stock_date on daily_stock(stock_date);

create table stock_history (
  id            uuid primary key default uuid_generate_v4(),
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  change_qty    int not null,             -- negative on sale, positive on restock
  reason        text not null,            -- 'order' | 'restock' | 'admin_adjustment'
  order_id      uuid,                     -- nullable FK set below after orders exists
  changed_by    uuid,                     -- admin auth_id, nullable for system/order events
  created_at    timestamptz not null default now()
);
create index idx_stock_history_item on stock_history(menu_item_id);

-- =========================================================================
-- 4. CART
-- =========================================================================

create table cart (
  id          uuid primary key default uuid_generate_v4(),
  student_id  uuid not null unique references students(id) on delete cascade,
  updated_at  timestamptz not null default now()
);

create table cart_items (
  id            uuid primary key default uuid_generate_v4(),
  cart_id       uuid not null references cart(id) on delete cascade,
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  quantity      int not null check (quantity > 0),
  created_at    timestamptz not null default now(),
  unique(cart_id, menu_item_id)
);
create index idx_cart_items_cart on cart_items(cart_id);

-- =========================================================================
-- 5. ORDERS / TOKENS / PAYMENTS
-- =========================================================================

create table order_window (
  id          uuid primary key default uuid_generate_v4(),
  label       text not null,             -- 'Morning Session', 'Lunch Session'
  start_time  time not null,
  end_time    time not null,
  is_active   boolean not null default true
);

create table canteen_settings (
  id                   int primary key default 1 check (id = 1), -- singleton row
  admin_window_override boolean not null default false,
  updated_at           timestamptz not null default now()
);
insert into canteen_settings (id) values (1) on conflict do nothing;

create sequence token_daily_seq;

create table orders (
  id              uuid primary key default uuid_generate_v4(),
  token_number    text not null,             -- e.g. A001, reset daily
  student_id      uuid not null references students(id) on delete restrict,
  status          order_status not null default 'received',
  subtotal        numeric(10,2) not null,
  total_amount    numeric(10,2) not null,
  pay_method      payment_method not null,
  order_date      date not null default current_date,
  placed_at       timestamptz not null default now(),
  ready_at        timestamptz,
  collected_at    timestamptz,
  cancelled_at    timestamptz,
  is_reviewed     boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique(token_number, order_date)
);
create index idx_orders_student on orders(student_id);
create index idx_orders_status on orders(status);
create index idx_orders_date on orders(order_date);
create trigger trg_orders_updated before update on orders
  for each row execute function set_updated_at();

create table order_items (
  id            uuid primary key default uuid_generate_v4(),
  order_id      uuid not null references orders(id) on delete cascade,
  menu_item_id  uuid not null references menu_items(id) on delete restrict,
  item_name     text not null,     -- denormalized snapshot at time of order
  unit_price    numeric(10,2) not null,
  quantity      int not null check (quantity > 0),
  line_total    numeric(10,2) generated always as (unit_price * quantity) stored
);
create index idx_order_items_order on order_items(order_id);

alter table stock_history
  add constraint fk_stock_history_order foreign key (order_id) references orders(id) on delete set null;

create table tokens (
  id            uuid primary key default uuid_generate_v4(),
  order_id      uuid not null unique references orders(id) on delete cascade,
  token_number  text not null,
  queue_position int,
  estimated_wait_minutes int,
  status        order_status not null default 'received',
  issued_at     timestamptz not null default now()
);

create table payments (
  id              uuid primary key default uuid_generate_v4(),
  order_id        uuid not null unique references orders(id) on delete cascade,
  amount          numeric(10,2) not null,
  method          payment_method not null,
  status          payment_status not null default 'initiated',
  provider        text default 'razorpay',
  provider_order_id text,
  provider_payment_id text,
  provider_signature text,
  qr_code_ref     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index idx_payments_order on payments(order_id);
create index idx_payments_status on payments(status);
create trigger trg_payments_updated before update on payments
  for each row execute function set_updated_at();

create table payment_history (
  id            uuid primary key default uuid_generate_v4(),
  payment_id    uuid not null references payments(id) on delete cascade,
  event_type    text not null,   -- 'created' | 'success' | 'failed' | 'refund_initiated' | 'refunded'
  raw_payload   jsonb,
  created_at    timestamptz not null default now()
);
create index idx_payment_history_payment on payment_history(payment_id);

-- =========================================================================
-- 6. REVIEWS / RATINGS / FEEDBACK
-- =========================================================================

create table reviews (
  id            uuid primary key default uuid_generate_v4(),
  order_id      uuid not null references orders(id) on delete cascade,
  student_id    uuid not null references students(id) on delete cascade,
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  rating        int not null check (rating between 1 and 5),
  review_text   text,
  image_url     text,
  created_at    timestamptz not null default now(),
  unique(order_id, menu_item_id)
);
create index idx_reviews_menu_item on reviews(menu_item_id);
create index idx_reviews_student on reviews(student_id);

create table ratings (
  id            uuid primary key default uuid_generate_v4(),
  menu_item_id  uuid not null unique references menu_items(id) on delete cascade,
  avg_rating    numeric(2,1) not null default 0,
  total_ratings int not null default 0,
  updated_at    timestamptz not null default now()
);

create table feedback (
  id          uuid primary key default uuid_generate_v4(),
  auth_id     uuid references auth.users(id) on delete set null,
  category    text not null default 'general',
  message     text not null,
  created_at  timestamptz not null default now()
);

-- =========================================================================
-- 7. NOTIFICATIONS
-- =========================================================================

create table notifications (
  id            uuid primary key default uuid_generate_v4(),
  channel       notification_channel not null,
  recipient_id  uuid,                 -- student_id / admin_id / super_admin_id, null = broadcast
  title         text not null,
  body          text not null,
  icon          text default '🔔',
  related_order_id uuid references orders(id) on delete set null,
  is_read       boolean not null default false,
  created_at    timestamptz not null default now()
);
create index idx_notifications_recipient on notifications(recipient_id, is_read);
create index idx_notifications_channel on notifications(channel);

create table devices (
  id            uuid primary key default uuid_generate_v4(),
  auth_id       uuid not null references auth.users(id) on delete cascade,
  push_token    text not null,
  platform      text not null check (platform in ('ios','android','web')),
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  unique(auth_id, push_token)
);

-- =========================================================================
-- 8. SETTINGS / PROFILE / SESSIONS
-- =========================================================================

create table theme_settings (
  auth_id     uuid primary key references auth.users(id) on delete cascade,
  theme       text not null default 'light' check (theme in ('light','dark')),
  updated_at  timestamptz not null default now()
);

create table profile_settings (
  auth_id           uuid primary key references auth.users(id) on delete cascade,
  notifications_on  boolean not null default true,
  language          text not null default 'en',
  updated_at        timestamptz not null default now()
);

create table sessions (
  id            uuid primary key default uuid_generate_v4(),
  auth_id       uuid not null references auth.users(id) on delete cascade,
  device_info   text,
  ip_address    inet,
  created_at    timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  revoked_at    timestamptz
);
create index idx_sessions_auth on sessions(auth_id);

-- =========================================================================
-- 9. OFFERS / BANNERS / FAVORITES
-- =========================================================================

create table offers (
  id            uuid primary key default uuid_generate_v4(),
  title         text not null,
  description   text,
  discount_pct  numeric(5,2),
  menu_item_id  uuid references menu_items(id) on delete cascade,
  valid_from    timestamptz not null default now(),
  valid_until   timestamptz,
  is_active     boolean not null default true,
  created_by    uuid references admins(id),
  created_at    timestamptz not null default now()
);

create table banners (
  id            uuid primary key default uuid_generate_v4(),
  title         text,
  storage_path  text not null,
  link_url      text,
  sort_order    int not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table favorites (
  student_id    uuid not null references students(id) on delete cascade,
  menu_item_id  uuid not null references menu_items(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (student_id, menu_item_id)
);

-- =========================================================================
-- 10. REPORTING / ANALYTICS / LOGS
-- =========================================================================

create table sales_reports (
  id              uuid primary key default uuid_generate_v4(),
  report_date     date not null unique,
  total_orders    int not null default 0,
  total_revenue   numeric(12,2) not null default 0,
  total_items_sold int not null default 0,
  avg_order_value numeric(10,2) not null default 0,
  generated_at    timestamptz not null default now()
);

create table analytics (
  id          uuid primary key default uuid_generate_v4(),
  auth_id     uuid references auth.users(id) on delete set null,
  event_name  text not null,        -- 'menu_view' | 'add_to_cart' | 'checkout_start' | ...
  metadata    jsonb,
  created_at  timestamptz not null default now()
);
create index idx_analytics_event on analytics(event_name);
create index idx_analytics_created on analytics(created_at);

create table activity_logs (
  id          uuid primary key default uuid_generate_v4(),
  auth_id     uuid references auth.users(id) on delete set null,
  action      text not null,        -- 'menu_item_created' | 'order_status_updated' | ...
  entity_type text,
  entity_id   uuid,
  details     jsonb,
  created_at  timestamptz not null default now()
);
create index idx_activity_logs_auth on activity_logs(auth_id);

create table system_logs (
  id          uuid primary key default uuid_generate_v4(),
  severity    text not null default 'info' check (severity in ('info','warning','error','critical')),
  source      text not null,        -- 'payment' | 'auth' | 'realtime' | 'edge_function' | ...
  message     text not null,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);
create index idx_system_logs_severity on system_logs(severity, created_at);

-- =========================================================================
-- SEED: default categories + default order windows (idempotent)
-- =========================================================================
insert into food_categories (name, sort_order) values
  ('Veg',1), ('Non-Veg',2), ('Snacks',3), ('Beverages',4), ('Desserts',5)
on conflict (name) do nothing;

insert into order_window (label, start_time, end_time) values
  ('Morning Session','08:30','09:00'),
  ('Lunch Session','11:30','11:50')
on conflict do nothing;
