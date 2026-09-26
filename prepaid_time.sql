-- =====================================================================
-- QO'SHIMCHA: Pulga qarab vaqt hisoblash (prepaid session)
-- Bu skriptni schema_v2.sql'dan KEYIN, bir marta ishga tushiring.
-- =====================================================================

-- 1) Yangi ustunlar
alter table public.sessions
  add column if not exists prepaid_amount numeric(12,2),
  add column if not exists planned_minutes int,
  add column if not exists ends_at timestamptz;

-- 2) Eski gc_start_session'ni o'chiramiz (parametrlar soni o'zgargani uchun)
drop function if exists public.gc_start_session(uuid, uuid, numeric, text);

-- 3) Yangi gc_start_session: p_amount berilsa, vaqtni o'zi hisoblaydi
create or replace function public.gc_start_session(
  p_room_id uuid,
  p_customer_id uuid default null,
  p_tariff numeric default null,
  p_note text default '',
  p_amount numeric default null,
  p_method public.payment_method default 'cash'
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_room public.rooms%rowtype;
  v_session_id uuid;
  v_tariff numeric(10,2);
  v_planned_minutes int;
  v_ends_at timestamptz;
begin
  if not public.gc_has_role(array['admin','operator']::public.gc_role[]) then
    raise exception 'Faqat admin yoki operator seans ochishi mumkin';
  end if;

  select * into v_room from public.rooms
   where id = p_room_id for update;

  if not found then raise exception 'Xona topilmadi'; end if;
  if v_room.status = 'busy' then raise exception 'Xona band'; end if;

  v_tariff := coalesce(p_tariff, v_room.hourly_rate);
  if v_tariff <= 0 then raise exception 'Tarif noto''g''ri belgilangan'; end if;

  if p_amount is not null then
    if p_amount <= 0 then raise exception 'Summa 0 dan katta bo''lishi kerak'; end if;
    v_planned_minutes := greatest(1, round(p_amount / v_tariff * 60));
    v_ends_at := now() + (v_planned_minutes || ' minutes')::interval;
  end if;

  update public.rooms set status = 'busy' where id = p_room_id;

  insert into public.sessions
    (room_id, customer_id, tariff_per_hour, note, started_by, prepaid_amount, planned_minutes, ends_at)
  values
    (p_room_id, p_customer_id, v_tariff, p_note, auth.uid(), p_amount, v_planned_minutes, v_ends_at)
  returning id into v_session_id;

  if p_amount is not null then
    if p_method = 'balance' then
      if p_customer_id is null then raise exception 'Balans uchun mijoz tanlanmagan'; end if;
      update public.customers set balance = balance - p_amount
       where id = p_customer_id and balance >= p_amount;
      if not found then raise exception 'Mijoz balansida yetarli mablag'' yo''q'; end if;
    else
      insert into public.cash_transactions
        (txn_type, amount, direction, category, description, ref_id, method, created_by)
      values ('session_payment', p_amount, 'in', 'seans (oldindan)', v_room.name,
              v_session_id::text, p_method, auth.uid());
    end if;
  end if;

  return v_session_id;
end;
$$;

grant execute on function public.gc_start_session(uuid, uuid, numeric, text, numeric, public.payment_method) to authenticated;

-- 4) gc_end_session: oldindan to'langan summani hisobga oladi
-- (agar to'langan summa vaqt qiymatini qoplasa, qo'shimcha kassa yozuvi qo'shilmaydi;
--  agar mijoz belgilangan vaqtdan ko'p turib qolsa, faqat ORTIQCHA qismi to'lanadi)
create or replace function public.gc_end_session(p_session_id uuid, p_method public.payment_method default 'cash', p_cart jsonb default '[]'::jsonb)
returns numeric
language plpgsql security definer set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_product public.products%rowtype;
  v_item jsonb;
  v_minutes int;
  v_time_amount numeric(12,2);
  v_prepaid numeric(12,2);
  v_due_time numeric(12,2);
  v_cart_total numeric(12,2) := 0;
  v_total numeric(12,2);
  v_due_total numeric(12,2);
  v_sale_id uuid;
begin
  if not public.gc_has_role(array['admin','operator']::public.gc_role[]) then
    raise exception 'Faqat admin yoki operator seans yopishi mumkin';
  end if;

  select * into v_session from public.sessions
   where id = p_session_id and status = 'open' for update;

  if not found then raise exception 'Ochiq seans topilmadi'; end if;

  v_minutes := greatest(1, ceil(extract(epoch from (now() - v_session.started_at)) / 60));
  v_time_amount := round(v_session.tariff_per_hour * v_minutes / 60.0, 2);
  v_prepaid := coalesce(v_session.prepaid_amount, 0);
  v_due_time := greatest(0, v_time_amount - v_prepaid);

  if jsonb_typeof(p_cart) = 'array' and jsonb_array_length(p_cart) > 0 then
    for v_item in select * from jsonb_array_elements(p_cart) loop
      select * into v_product from public.products
       where id = (v_item->>'product_id')::uuid and active for update;
      if not found then raise exception 'Mahsulot topilmadi'; end if;
      if v_product.stock_qty < (v_item->>'qty')::numeric then
        raise exception '"%" dan yetarli qoldiq yo''q (qoldiq: %)', v_product.name, v_product.stock_qty;
      end if;

      update public.products set stock_qty = stock_qty - (v_item->>'qty')::numeric
       where id = v_product.id;
      insert into public.stock_movements (product_id, qty_change, reason, created_by)
      values (v_product.id, -(v_item->>'qty')::numeric, 'sale', auth.uid());

      v_cart_total := v_cart_total + v_product.price * (v_item->>'qty')::numeric;
    end loop;

    insert into public.sales (customer_id, payment_method, total_amount, created_by)
    values (v_session.customer_id, p_method, round(v_cart_total, 2), auth.uid())
    returning id into v_sale_id;

    for v_item in select * from jsonb_array_elements(p_cart) loop
      select * into v_product from public.products where id = (v_item->>'product_id')::uuid;
      insert into public.sale_items (sale_id, product_id, name, qty, unit_price)
      values (v_sale_id, v_product.id, v_product.name, (v_item->>'qty')::numeric, v_product.price);
    end loop;
  end if;

  v_total := round(v_time_amount + v_cart_total, 2);
  v_due_total := round(v_due_time + v_cart_total, 2);

  update public.sessions
     set status = 'closed', ended_at = now(), duration_min = v_minutes,
         amount = v_total, cart = coalesce(p_cart, '[]'::jsonb),
         paid = true, closed_by = auth.uid()
   where id = p_session_id;

  update public.rooms set status = 'free' where id = v_session.room_id;

  if p_method = 'balance' then
    if v_due_total > 0 then
      if v_session.customer_id is null then
        raise exception 'Balans uchun mijoz tanlanmagan';
      end if;
      update public.customers set balance = balance - v_due_total
       where id = v_session.customer_id and balance >= v_due_total;
      if not found then
        raise exception 'Mijoz balansida yetarli mablag'' yo''q (kerak: %)', v_due_total;
      end if;
    end if;
  else
    if v_due_time > 0 then
      insert into public.cash_transactions
        (txn_type, amount, direction, category, description, ref_id, method, created_by)
      values ('session_payment', v_due_time, 'in', 'seans',
              (select name from public.rooms where id = v_session.room_id),
              p_session_id::text, p_method, auth.uid());
    end if;
    if v_cart_total > 0 then
      insert into public.cash_transactions
        (txn_type, amount, direction, category, description, ref_id, method, created_by)
      values ('sale', round(v_cart_total, 2), 'in', 'seans savati', 'Seans ichidagi sotuv',
              v_sale_id::text, p_method, auth.uid());
    end if;
  end if;

  return v_due_total;
end;
$$;
