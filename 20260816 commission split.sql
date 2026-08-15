-- ============================================================================
-- Commission split for EarnOva product sales
--
-- Rule:
--   Website always keeps a fixed 10% of the sale price.
--   The remaining 90% ("payable pool") is split:
--     - Referral sale  -> referrer gets product.commission_rate% of the PRICE
--                         (capped so it never exceeds the 90% pool),
--                         partner gets what's left of the pool.
--     - No referral    -> partner gets the full 90% pool.
--
-- All of this happens inside record_sale(), a single SECURITY DEFINER
-- function that runs as one transaction, so a sale is never half-credited.
-- It is only ever called from the verify-paystack Edge Function using the
-- service role key, AFTER Paystack has confirmed the payment server-side.
-- ============================================================================

-- 1. Make affiliate_sales able to represent both referral AND direct sales.
alter table affiliate_sales
  alter column affiliate_link_id drop not null;

alter table affiliate_sales
  add column if not exists product_id uuid references products(id),
  add column if not exists partner_id uuid references profiles(id),
  add column if not exists partner_amount numeric not null default 0,
  add column if not exists site_amount numeric not null default 0,
  add column if not exists paystack_reference text;

-- Backfill product_id / partner_id for any sales that already exist
-- (every existing row is a referral sale, so it has an affiliate_link_id
-- to derive the product — and the product tells us the partner).
update affiliate_sales s
set product_id = al.product_id
from affiliate_links al
where s.affiliate_link_id = al.id
  and s.product_id is null;

update affiliate_sales s
set partner_id = p.created_by
from products p
where s.product_id = p.id
  and s.partner_id is null;

-- If any rows still couldn't be backfilled (e.g. an affiliate_link whose
-- product was later deleted, or a row that already had a NULL
-- affiliate_link_id before this migration), stop here with a clear message
-- instead of a confusing generic NOT NULL error.
do $$
declare
  v_missing_count int;
begin
  select count(*) into v_missing_count
  from affiliate_sales
  where product_id is null;

  if v_missing_count > 0 then
    raise exception
      '% affiliate_sales row(s) could not be backfilled with a product_id. Run: select id, affiliate_link_id, buyer_email, sale_amount, created_at from affiliate_sales where product_id is null;  then either fix/delete those rows or tell me their affiliate_link_id / buyer_email so I can adjust the migration.',
      v_missing_count;
  end if;
end $$;

do $$
declare
  v_missing_count int;
begin
  select count(*) into v_missing_count
  from affiliate_sales
  where partner_id is null;

  if v_missing_count > 0 then
    raise exception
      '% affiliate_sales row(s) could not be backfilled with a partner_id. Run: select s.id, s.product_id, p.created_by from affiliate_sales s left join products p on p.id = s.product_id where s.partner_id is null;  then either fix/delete those rows or tell me the details so I can adjust the migration.',
      v_missing_count;
  end if;
end $$;

alter table affiliate_sales
  alter column product_id set not null,
  alter column partner_id set not null;

-- Idempotency guard: a given Paystack reference can only ever produce one
-- affiliate_sales row, even if verify-paystack is called twice for it
-- (e.g. the browser retries after a dropped connection).
create unique index if not exists affiliate_sales_paystack_reference_key
  on affiliate_sales (paystack_reference);

-- 2. Balance ledger helper. Kept separate + simple so it can also be reused
--    elsewhere (e.g. wallet top-up approval) without duplicating logic.
create or replace function increment_balance(p_user_id uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update profiles
  set balance = coalesce(balance, 0) + p_amount
  where id = p_user_id;
end;
$$;

-- Lock this down: only the service role (used by Edge Functions) may call
-- it directly. Regular users must never be able to credit their own balance.
revoke execute on function increment_balance(uuid, numeric) from public, anon, authenticated;

-- 3. The core function: verify inputs against the DB, split the money,
--    write the ledger + sale row, atomically.
create or replace function record_sale(
  p_paystack_reference text,
  p_product_id uuid,
  p_ref_code text,
  p_buyer_name text,
  p_buyer_email text,
  p_paid_kobo bigint          -- amount Paystack actually confirmed, in kobo
)
returns table (
  sale_id uuid,
  already_processed boolean,
  commission_amount numeric,
  partner_amount numeric,
  site_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product products%rowtype;
  v_link affiliate_links%rowtype;
  v_existing affiliate_sales%rowtype;
  v_price numeric;
  v_site_amount numeric;
  v_pool numeric;
  v_commission numeric := 0;
  v_partner_amount numeric;
  v_sale_id uuid;
  v_has_referral boolean := false;
begin
  -- Idempotency: if we've already recorded this exact payment, hand back
  -- the same result instead of crediting anyone twice.
  select * into v_existing
  from affiliate_sales
  where paystack_reference = p_paystack_reference;

  if found then
    return query select
      v_existing.id, true, v_existing.commission_amount,
      v_existing.partner_amount, v_existing.site_amount;
    return;
  end if;

  select * into v_product from products where id = p_product_id and is_active = true;
  if not found then
    raise exception 'Product % not found or inactive', p_product_id;
  end if;

  v_price := v_product.price;

  -- Defense in depth: the amount Paystack actually confirmed must match
  -- the product's current price. Prevents a tampered client-side amount
  -- from ever reaching this far (verify-paystack should already catch
  -- this, but we never trust the caller with money math).
  if p_paid_kobo is distinct from round(v_price * 100) then
    raise exception 'Paid amount does not match product price';
  end if;

  -- Resolve referral, if any. A ref_code that doesn't exist, or points at
  -- a different product, is silently ignored -> treated as a direct sale.
  if p_ref_code is not null then
    select * into v_link
    from affiliate_links
    where code = p_ref_code and product_id = p_product_id;
    v_has_referral := found;
  end if;

  v_site_amount := round(v_price * 0.10, 2);
  v_pool := v_price - v_site_amount;               -- 90% pool

  if v_has_referral then
    -- Referral sale: referrer earns commission_rate% of the price, capped
    -- to the pool so a misconfigured >90% commission_rate can never eat
    -- into the site's cut.
    v_commission := least(round(v_price * (v_product.commission_rate / 100.0), 2), v_pool);
    v_partner_amount := v_pool - v_commission;
  else
    -- Direct sale, no referral: partner gets the whole pool.
    v_commission := 0;
    v_partner_amount := v_pool;
  end if;

  insert into affiliate_sales (
    affiliate_link_id, product_id, partner_id, paystack_reference,
    buyer_name, buyer_email, sale_amount,
    commission_amount, partner_amount, site_amount, status
  ) values (
    case when v_has_referral then v_link.id else null end,
    p_product_id, v_product.created_by, p_paystack_reference,
    p_buyer_name, p_buyer_email, v_price,
    v_commission, v_partner_amount, v_site_amount, 'completed'
  )
  returning id into v_sale_id;

  -- Credit balances. Partner always gets paid; referrer only on a
  -- referral sale.
  perform increment_balance(v_product.created_by, v_partner_amount);

  if v_has_referral then
    perform increment_balance(v_link.user_id, v_commission);
  end if;

  return query select v_sale_id, false, v_commission, v_partner_amount, v_site_amount;
end;
$$;

-- Only the service role (Edge Functions) may call this — it moves real money.
revoke execute on function record_sale(text, uuid, text, text, text, bigint) from public, anon, authenticated;

-- 4. Let a partner see the sales rows for products they created, so the
--    partner dashboard can show a "Your product sales" breakdown. This is
--    read-only and additive — it does not change who can see affiliate
--    (referral-owner) rows, which is presumably already covered by an
--    existing affiliate_sales policy on affiliate_link_id ownership.
alter table affiliate_sales enable row level security;

create policy "Partners can view sales of their own products"
  on affiliate_sales
  for select
  to authenticated
  using (partner_id = auth.uid());
