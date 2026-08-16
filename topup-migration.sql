-- =========================================================
-- Automated wallet top-ups via Paystack
-- =========================================================

-- Prevent double-crediting if verify-topup is ever called twice for the
-- same Paystack reference (retry, duplicate webhook, etc).
alter table wallet_topups add column if not exists status text not null default 'approved';
create unique index if not exists wallet_topups_reference_unique
  on wallet_topups (reference)
  where reference is not null;

-- Atomically credit the partner's wallet balance and log the top-up.
-- Idempotent: if `reference` already exists, does nothing and reports
-- already_processed = true instead of crediting twice.
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
