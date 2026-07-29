-- =========================================================================
-- SSM BITES — RPC FUNCTIONS
-- Run AFTER 01-04.
-- =========================================================================

-- ---------- place_order: atomic cart -> order transaction ----------
create or replace function place_order(p_student_id uuid, p_pay_method payment_method)
returns table(order_id uuid, token_number text, total_amount numeric)
language plpgsql
security definer
as $$
declare
  v_cart_id uuid;
  v_order_id uuid;
  v_subtotal numeric(10,2) := 0;
  v_token text;
  v_item record;
begin
  -- Ownership check: caller must be the student they claim to be
  if not exists (select 1 from students where id = p_student_id and auth_id = auth.uid()) then
    raise exception 'Not authorized to place this order';
  end if;

  select id into v_cart_id from cart where student_id = p_student_id;
  if v_cart_id is null then raise exception 'Cart is empty'; end if;

  -- Lock the cart items + their menu rows to prevent oversell under load
  for v_item in
    select ci.menu_item_id, ci.quantity, mi.price, mi.name, mi.qty_enabled
    from cart_items ci join menu_items mi on mi.id = ci.menu_item_id
    where ci.cart_id = v_cart_id
    for update of mi
  loop
    if v_item.qty_enabled then
      perform 1 from daily_stock
        where menu_item_id = v_item.menu_item_id and stock_date = current_date
          and remaining_qty >= v_item.quantity
        for update;
      if not found then
        raise exception 'Insufficient stock for %', v_item.name;
      end if;
    end if;
    v_subtotal := v_subtotal + (v_item.price * v_item.quantity);
  end loop;

  if v_subtotal = 0 then raise exception 'Cart is empty'; end if;

  insert into orders (student_id, subtotal, total_amount, pay_method)
  values (p_student_id, v_subtotal, v_subtotal, p_pay_method)  -- no platform fee, per product spec
  returning id, orders.token_number into v_order_id, v_token;

  insert into order_items (order_id, menu_item_id, item_name, unit_price, quantity)
  select v_order_id, ci.menu_item_id, mi.name, mi.price, ci.quantity
  from cart_items ci join menu_items mi on mi.id = ci.menu_item_id
  where ci.cart_id = v_cart_id;

  insert into payments (order_id, amount, method, status)
  values (v_order_id, v_subtotal, p_pay_method, 'initiated');

  delete from cart_items where cart_id = v_cart_id;

  return query select v_order_id, v_token, v_subtotal;
end;
$$;

-- ---------- top_selling_items: for admin dashboard "Sales by Item" ----------
create or replace function top_selling_items(p_limit int default 5)
returns table(menu_item_id uuid, name text, total_qty bigint)
language sql stable
as $$
  select mi.id, mi.name, sum(oi.quantity) as total_qty
  from order_items oi
  join menu_items mi on mi.id = oi.menu_item_id
  join orders o on o.id = oi.order_id
  where o.status <> 'cancelled'
  group by mi.id, mi.name
  order by total_qty desc
  limit p_limit;
$$;

-- ---------- mark_payment_success: called from the razorpay-verify Edge Function ----------
create or replace function mark_payment_success(p_order_id uuid, p_provider_order_id text,
                                                  p_provider_payment_id text, p_provider_signature text)
returns void
language plpgsql
security definer
as $$
begin
  update payments
    set status = 'success', provider_order_id = p_provider_order_id,
        provider_payment_id = p_provider_payment_id, provider_signature = p_provider_signature,
        updated_at = now()
    where order_id = p_order_id;

  insert into payment_history (payment_id, event_type, raw_payload)
  select id, 'success', jsonb_build_object('provider_payment_id', p_provider_payment_id)
  from payments where order_id = p_order_id;
end;
$$;
