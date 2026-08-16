-- =========================================================
-- Switch payout balance check from "earned via affiliate_sales"
-- to the partner's wallet balance (profiles.balance) — the same
-- number shown on the "Wallet balance" card.
--
-- Run this AFTER payout-migration.sql. It replaces two functions
-- in place; no table changes needed.
-- =========================================================

-- Reserve the payout amount by deducting it from wallet balance up front,
-- locked so two simultaneous requests can't both succeed against the
-- same balance. If the Paystack transfer later fails, the amount is
-- refunded back to the balance by finalize_partner_payout below.
create or replace function request_partner_payout(p_partner_id uuid, p_amount numeric)
returns partner_payouts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric;
  v_payout partner_payouts;
begin
  if p_partner_id is null then
    raise exception 'Missing partner';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Invalid amount';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_partner_id::text));

  select balance into v_balance
  from profiles
  where id = p_partner_id
  for update;

  if v_balance is null then
    raise exception 'Profile not found';
  end if;

  if p_amount > v_balance then
    raise exception 'Amount exceeds available balance';
  end if;

  update profiles
  set balance = balance - p_amount
  where id = p_partner_id;

  insert into partner_payouts (partner_id, amount, status)
  values (p_partner_id, p_amount, 'pending')
  returning * into v_payout;

  return v_payout;
end;
$$;

-- On failure, refund the reserved amount back to wallet balance.
-- On success/pending (awaiting Paystack OTP), the deduction stays.
create or replace function finalize_partner_payout(
  p_payout_id uuid,
  p_status text,
  p_transfer_code text,
  p_reference text,
  p_failure_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner uuid;
  v_amount numeric;
begin
  select partner_id, amount into v_partner, v_amount
  from partner_payouts
  where id = p_payout_id;

  update partner_payouts
  set status = p_status,
      paystack_transfer_code = coalesce(p_transfer_code, paystack_transfer_code),
      paystack_reference = coalesce(p_reference, paystack_reference),
      failure_reason = p_failure_reason
  where id = p_payout_id;

  if p_status = 'failed' and v_partner is not null then
    update profiles
    set balance = balance + v_amount
    where id = v_partner;
  end if;
end;
$$;

-- Available balance is now just the wallet balance (already net of any
-- reserved/pending payouts, since request_partner_payout deducts up front).
create or replace function get_partner_payout_summary()
returns table(available numeric, pending numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner uuid := auth.uid();
begin
  return query
  select
    coalesce((select balance from profiles where id = v_partner), 0) as available,
    coalesce((select sum(amount) from partner_payouts where partner_id = v_partner and status = 'pending'), 0) as pending;
end;
$$;
