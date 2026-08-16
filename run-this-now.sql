-- =========================================================
-- Run this ENTIRE script once in the Supabase SQL editor.
-- Safe to run even if parts were already applied — every
-- statement is idempotent (IF NOT EXISTS / CREATE OR REPLACE).
-- =========================================================

-- 1. Payout account fields on the partner's profile row
alter table profiles add column if not exists payout_bank_code text;
alter table profiles add column if not exists payout_bank_name text;
alter table profiles add column if not exists payout_account_number text;
alter table profiles add column if not exists payout_account_name text;
alter table profiles add column if not exists paystack_recipient_code text;

-- 2. Payout history / ledger
create table if not exists partner_payouts (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references auth.users(id),
  amount numeric not null,
  status text not null default 'pending', -- pending | success | failed
  paystack_transfer_code text,
  paystack_reference text,
  failure_reason text,
  created_at timestamptz not null default now()
);

alter table partner_payouts enable row level security;

drop policy if exists "Partners view own payouts" on partner_payouts;
create policy "Partners view own payouts"
on partner_payouts for select
using (partner_id = auth.uid());

-- 3. Storage: allow partners to delete their own product files
drop policy if exists "Partners delete own product files" on storage.objects;
create policy "Partners delete own product files"
on storage.objects for delete
using (
  bucket_id = 'product-files'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- 4. Reserve a withdrawal amount against WALLET BALANCE, atomically.
--    Deducts up front (locked per-partner) so two simultaneous requests
--    can't both succeed against the same balance. finalize_partner_payout
--    (below) refunds this if the Paystack transfer fails.
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

revoke all on function request_partner_payout(uuid, numeric) from public;
grant execute on function request_partner_payout(uuid, numeric) to service_role;

-- 5. Update a payout row after the Paystack transfer call resolves.
--    Refunds wallet balance if the transfer failed.
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

revoke all on function finalize_partner_payout(uuid, text, text, text, text) from public;
grant execute on function finalize_partner_payout(uuid, text, text, text, text) to service_role;

-- 6. Read-only balance summary for the frontend — wallet balance +
--    anything currently pending.
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

grant execute on function get_partner_payout_summary() to authenticated;

-- 7. Idempotent wallet top-ups (prevents double-crediting on retry)
alter table wallet_topups add column if not exists status text not null default 'approved';
create unique index if not exists wallet_topups_reference_unique
  on wallet_topups (reference)
  where reference is not null;

create or replace function credit_wallet_topup(
  p_partner_id uuid,
  p_amount numeric,
  p_reference text
)
returns table(already_processed boolean)
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from wallet_topups where reference = p_reference) then
    return query select true;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_partner_id::text));

  insert into wallet_topups (partner_id, amount, reference, status)
  values (p_partner_id, p_amount, p_reference, 'approved');

  update profiles
  set balance = coalesce(balance, 0) + p_amount
  where id = p_partner_id;

  return query select false;
end;
$$;

revoke all on function credit_wallet_topup(uuid, numeric, text) from public;
grant execute on function credit_wallet_topup(uuid, numeric, text) to service_role;

-- =========================================================
-- Done. To verify it actually applied, run:
--   select proname from pg_proc where proname = 'request_partner_payout';
-- and check the function body references `profiles.balance`, not
-- `affiliate_sales`.
-- =========================================================
