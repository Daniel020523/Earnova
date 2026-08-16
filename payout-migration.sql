-- =========================================================
-- Partner payout system: bank account storage + payout requests
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

-- Partners can see their own payout history — no direct write access.
-- All writes happen through the SECURITY DEFINER functions below, called
-- only from the request-payout Edge Function (matches the pattern used
-- for affiliate_sales / transactions elsewhere in this project).
drop policy if exists "Partners view own payouts" on partner_payouts;
create policy "Partners view own payouts"
on partner_payouts for select
using (partner_id = auth.uid());

-- 3. Storage: allow partners to delete their own product files
--    (needed for the "delete product also deletes its file" feature)
drop policy if exists "Partners delete own product files" on storage.objects;
create policy "Partners delete own product files"
on storage.objects for delete
using (
  bucket_id = 'product-files'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- 4. Reserve a payout amount against available balance, atomically.
--    Available balance = sum of partner_amount earned via affiliate_sales,
--    minus anything already pending or successfully paid out.
--    Uses an advisory lock keyed to the partner so two simultaneous
--    requests can't both succeed against the same balance.
create or replace function request_partner_payout(p_partner_id uuid, p_amount numeric)
returns partner_payouts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_earned numeric;
  v_reserved numeric;
  v_available numeric;
  v_payout partner_payouts;
begin
  if p_partner_id is null then
    raise exception 'Missing partner';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Invalid amount';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_partner_id::text));

  select coalesce(sum(partner_amount), 0) into v_earned
  from affiliate_sales
  where partner_id = p_partner_id;

  select coalesce(sum(amount), 0) into v_reserved
  from partner_payouts
  where partner_id = p_partner_id and status in ('pending', 'success');

  v_available := v_earned - v_reserved;

  if p_amount > v_available then
    raise exception 'Amount exceeds available balance';
  end if;

  insert into partner_payouts (partner_id, amount, status)
  values (p_partner_id, p_amount, 'pending')
  returning * into v_payout;

  return v_payout;
end;
$$;

revoke all on function request_partner_payout(uuid, numeric) from public;
grant execute on function request_partner_payout(uuid, numeric) to service_role;

-- 5. Update a payout row after the Paystack transfer call resolves.
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
begin
  update partner_payouts
  set status = p_status,
      paystack_transfer_code = coalesce(p_transfer_code, paystack_transfer_code),
      paystack_reference = coalesce(p_reference, paystack_reference),
      failure_reason = p_failure_reason
  where id = p_payout_id;
end;
$$;

revoke all on function finalize_partner_payout(uuid, text, text, text, text) from public;
grant execute on function finalize_partner_payout(uuid, text, text, text, text) to service_role;

-- 6. Read-only balance summary, safe for partners to call directly
--    (no state changes, scoped to their own auth.uid()).
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
    coalesce((select sum(partner_amount) from affiliate_sales where partner_id = v_partner), 0)
      - coalesce((select sum(amount) from partner_payouts where partner_id = v_partner and status in ('pending','success')), 0) as available,
    coalesce((select sum(amount) from partner_payouts where partner_id = v_partner and status = 'pending'), 0) as pending;
end;
$$;

grant execute on function get_partner_payout_summary() to authenticated;
