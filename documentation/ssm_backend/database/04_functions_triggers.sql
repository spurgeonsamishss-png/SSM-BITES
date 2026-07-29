-- =========================================================================
-- SSM BITES — BUSINESS LOGIC: TOKENS, STOCK, RATINGS, NOTIFICATIONS
-- Run AFTER 01-03. Requires pg_cron extension enabled in Supabase dashboard
-- (Database > Extensions > pg_cron) for the daily reset job at the bottom.
-- =========================================================================

-- ---------- 1. Token generation (auto, daily reset, queue position) ----------
create or replace function assign_token_and_queue()
returns trigger as $$
declare
  v_seq int;
  v_token text;
  v_queue_pos int;
begin
  -- Count today's orders so far -> sequential token number, resets naturally
  -- because we filter by order_date = current_date.
  select count(*) + 1 into v_seq
  from orders
  where order_date = new.order_date;

  v_token := 'A' || lpad(v_seq::text, 3, '0');
  new.token_number := v_token;

  select count(*) + 1 into v_queue_pos
  from orders
  where order_date = new.order_date
    and status in ('received','preparing');

  insert into tokens (order_id, token_number, queue_position, estimated_wait_minutes, status)
  values (new.id, v_token, v_queue_pos, v_queue_pos * 4, 'received');

  return new;
end;
$$ language plpgsql;

create trigger trg_orders_assign_token
  before insert on orders
  for each row execute function assign_token_and_queue();

-- ---------- 2. Stock decrement on order placement ----------
create or replace function decrement_stock_on_order_item()
returns trigger as $$
declare
  v_qty_enabled boolean;
begin
  select qty_enabled into v_qty_enabled from menu_items where id = new.menu_item_id;
  if v_qty_enabled then
    update daily_stock
      set remaining_qty = greatest(0, remaining_qty - new.quantity),
          updated_at = now()
      where menu_item_id = new.menu_item_id and stock_date = current_date;

    insert into stock_history (menu_item_id, change_qty, reason, order_id)
    values (new.menu_item_id, -new.quantity, 'order', new.order_id);
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_order_items_decrement_stock
  after insert on order_items
  for each row execute function decrement_stock_on_order_item();

-- ---------- 3. Ratings rollup when a review is submitted ----------
create or replace function refresh_menu_item_rating()
returns trigger as $$
declare
  v_avg numeric(2,1);
  v_count int;
begin
  select round(avg(rating)::numeric,1), count(*) into v_avg, v_count
  from reviews where menu_item_id = new.menu_item_id;

  update menu_items set rating = coalesce(v_avg,0), rating_count = v_count
  where id = new.menu_item_id;

  insert into ratings (menu_item_id, avg_rating, total_ratings)
  values (new.menu_item_id, coalesce(v_avg,0), v_count)
  on conflict (menu_item_id) do update
    set avg_rating = excluded.avg_rating,
        total_ratings = excluded.total_ratings,
        updated_at = now();

  update orders set is_reviewed = true where id = new.order_id;

  return new;
end;
$$ language plpgsql;

create trigger trg_reviews_refresh_rating
  after insert on reviews
  for each row execute function refresh_menu_item_rating();

-- ---------- 4. Realtime notifications on order status change ----------
create or replace function notify_on_order_status_change()
returns trigger as $$
declare
  v_icon text;
  v_title text;
begin
  if new.status is distinct from old.status then
    v_icon := case new.status
      when 'received' then '✅'
      when 'preparing' then '👨‍🍳'
      when 'ready_for_pickup' then '🔔'
      when 'collected' then '🎉'
      when 'cancelled' then '❌'
      else '🔔' end;
    v_title := case new.status
      when 'preparing' then 'Order is Being Prepared'
      when 'ready_for_pickup' then 'Ready for Pickup!'
      when 'cancelled' then 'Order Cancelled'
      else initcap(new.status::text) end;

    insert into notifications (channel, recipient_id, title, body, icon, related_order_id)
    values ('student', new.student_id, v_title,
            'Token ' || new.token_number || ' · status updated to ' || new.status, v_icon, new.id);

    update tokens set status = new.status,
      issued_at = case when new.status = 'ready_for_pickup' then now() else issued_at end
      where order_id = new.id;

    if new.status = 'ready_for_pickup' then
      update orders set ready_at = now() where id = new.id;
    elsif new.status = 'collected' then
      update orders set collected_at = now() where id = new.id;
    elsif new.status = 'cancelled' then
      update orders set cancelled_at = now() where id = new.id;
    end if;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_orders_notify_status
  after update on orders
  for each row execute function notify_on_order_status_change();

-- ---------- 5. New-order notification to admins ----------
create or replace function notify_admins_new_order()
returns trigger as $$
begin
  insert into notifications (channel, recipient_id, title, body, icon, related_order_id)
  values ('admin', null, 'New Order', 'Token ' || new.token_number || ' placed', '🧾', new.id);
  return new;
end;
$$ language plpgsql;

create trigger trg_orders_notify_admin_new
  after insert on orders
  for each row execute function notify_admins_new_order();

-- ---------- 6. Low stock -> admin notification ----------
create or replace function notify_low_stock()
returns trigger as $$
begin
  if new.remaining_qty <= 5 and (old.remaining_qty is null or old.remaining_qty > 5) then
    insert into notifications (channel, recipient_id, title, body, icon)
    select 'admin', null, 'Low Stock Alert', mi.name || ' has ' || new.remaining_qty || ' left', '⚠️'
    from menu_items mi where mi.id = new.menu_item_id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger trg_daily_stock_low_alert
  after update on daily_stock
  for each row execute function notify_low_stock();

-- ---------- 7. Daily sales report rollup (called by pg_cron nightly) ----------
create or replace function generate_daily_sales_report(p_date date default current_date - 1)
returns void as $$
declare
  v_orders int;
  v_revenue numeric(12,2);
  v_items int;
begin
  select count(*), coalesce(sum(total_amount),0) into v_orders, v_revenue
  from orders where order_date = p_date and status <> 'cancelled';

  select coalesce(sum(oi.quantity),0) into v_items
  from order_items oi join orders o on o.id = oi.order_id
  where o.order_date = p_date and o.status <> 'cancelled';

  insert into sales_reports (report_date, total_orders, total_revenue, total_items_sold, avg_order_value)
  values (p_date, v_orders, v_revenue, v_items,
          case when v_orders > 0 then round(v_revenue / v_orders, 2) else 0 end)
  on conflict (report_date) do update
    set total_orders = excluded.total_orders,
        total_revenue = excluded.total_revenue,
        total_items_sold = excluded.total_items_sold,
        avg_order_value = excluded.avg_order_value,
        generated_at = now();
end;
$$ language plpgsql;

-- ---------- 8. Scheduled jobs (requires pg_cron enabled in Supabase) ----------
-- Nightly rollup of yesterday's report at 00:05
select cron.schedule(
  'ssm_bites_daily_sales_report',
  '5 0 * * *',
  $$select generate_daily_sales_report(current_date - 1);$$
);

-- Seed today's daily_stock rows from each qty-enabled menu item's last known
-- opening quantity at 06:00 every day (admin can still edit before opening).
create or replace function seed_daily_stock()
returns void as $$
begin
  insert into daily_stock (menu_item_id, stock_date, opening_qty, remaining_qty)
  select id, current_date, 0, 0 from menu_items
  where qty_enabled = true
  on conflict (menu_item_id, stock_date) do nothing;
end;
$$ language plpgsql;

select cron.schedule(
  'ssm_bites_seed_daily_stock',
  '0 6 * * *',
  $$select seed_daily_stock();$$
);
