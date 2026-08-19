-- ---------------------------------------------------------------
-- Payout lifecycle + transaction history
-- Run this in the Supabase SQL editor (Project > SQL Editor).
--
-- This supersedes payout_server_checks.sql's balance trigger. If you
-- ran that script earlier, this migration drops and replaces it —
-- you don't need to run both, just run this one.
--
-- New behavior:
--   1. The moment a partner submits a payout request (and it passes
--      the ₦100 minimum + balance checks), the amount is deducted
--      from their wallet balance immediately — atomically, so two
--      simultaneous requests can never both succeed against the same
--      balance.
--   2. A debit transaction is logged to partner_wallet_transactions
--      with status 'pending'.
--   3. When admin approves/pays a request, the linked transaction row
--      is kept in sync automatically (status flips to 'paid', and the
--      description updates to "Payout paid") — so the partner's
--      transaction history always reflects the real status.
--   4. If admin rejects a request (pending or approved), the amount
--      is automatically refunded to the partner's balance, the
--      original debit row is flipped to 'rejected', and a separate
--      'refunded' credit transaction is logged.
-- ---------------------------------------------------------------

-- ============================================================
-- 1) Transaction ledger table
-- ============================================================
create table if not exists public.partner_wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references auth.users(id),
  payout_request_id uuid references public.partner_payout_requests(id),
  type text not null check (type in ('debit', 'credit')),
  amount numeric not null check (amount > 0),
  description text,
  -- Mirrors the linked payout request's status for debit rows, so the
  -- transaction history always reflects where the money actually stands
  -- (pending / approved / paid / rejected). Credit (refund) rows use
  -- 'refunded' since they represent a completed, one-time event.
  status text not null default 'pending',
  created_at timestamptz not null default now()
);

alter table public.partner_wallet_transactions
  add column if not exists status text not null default 'pending';

alter table public.partner_wallet_transactions enable row level security;

drop policy if exists "Partners can view own transactions" on public.partner_wallet_transactions;
create policy "Partners can view own transactions"
  on public.partner_wallet_transactions for select
  using (partner_id = auth.uid());

-- No insert/update/delete policies for partners or admins — rows are
-- only ever written by the SECURITY DEFINER trigger functions below.

-- ============================================================
-- 2) Minimum amount check (unchanged from payout_server_checks.sql,
--    safe to re-run)
-- ============================================================
alter table public.partner_payout_requests
  drop constraint if exists payout_min_amount;

alter table public.partner_payout_requests
  add constraint payout_min_amount check (amount >= 100);

-- ============================================================
-- 3) Replace the old balance-check-only trigger with one that
--    atomically checks AND deducts, avoiding a race between two
--    simultaneous payout requests.
-- ============================================================
drop trigger if exists trg_check_payout_balance on public.partner_payout_requests;
drop function if exists public.check_payout_balance();
drop trigger if exists trg_deduct_payout_balance on public.partner_payout_requests;

create or replace function public.deduct_payout_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_rows int;
begin
  -- Single atomic statement: only succeeds if the partner currently
  -- has enough balance. No separate "check, then deduct" steps, so
  -- there's no window for a race condition to double-spend a balance.
  update public.profiles
  set balance = balance - new.amount
  where id = new.partner_id
    and balance >= new.amount;

  get diagnostics updated_rows = row_count;

  if updated_rows = 0 then
    raise exception 'Payout amount exceeds available balance.' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger trg_deduct_payout_balance
  before insert on public.partner_payout_requests
  for each row
  execute function public.deduct_payout_balance();

revoke all on function public.deduct_payout_balance() from public, anon, authenticated;

-- ============================================================
-- 4) Log a debit transaction once the request (and its deduction)
--    has succeeded.
-- ============================================================
drop trigger if exists trg_log_payout_debit on public.partner_payout_requests;

create or replace function public.log_payout_debit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.partner_wallet_transactions (partner_id, payout_request_id, type, amount, description, status)
  values (new.partner_id, new.id, 'debit', new.amount, 'Payout requested', 'pending');
  return new;
end;
$$;

create trigger trg_log_payout_debit
  after insert on public.partner_payout_requests
  for each row
  execute function public.log_payout_debit();

revoke all on function public.log_payout_debit() from public, anon, authenticated;

-- ============================================================
-- 4b) Keep the transaction history's debit row in sync whenever the
--     payout request's status changes to 'approved' or 'paid', so
--     the partner sees "Paid" in their transaction history the
--     moment admin clicks Approve & pay — not stuck on "Payout
--     requested" forever.
-- ============================================================
drop trigger if exists trg_sync_payout_transaction_status on public.partner_payout_requests;

create or replace function public.sync_payout_transaction_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status and new.status in ('approved', 'paid') then
    update public.partner_wallet_transactions
    set status = new.status,
        description = case
          when new.status = 'paid' then 'Payout paid'
          else 'Payout approved'
        end
    where payout_request_id = new.id
      and type = 'debit';
  end if;
  return new;
end;
$$;

create trigger trg_sync_payout_transaction_status
  after update on public.partner_payout_requests
  for each row
  execute function public.sync_payout_transaction_status();

revoke all on function public.sync_payout_transaction_status() from public, anon, authenticated;

-- ============================================================
-- 5) Refund + log a credit transaction when a request transitions
--    to 'rejected' from any other status.
-- ============================================================
drop trigger if exists trg_refund_rejected_payout on public.partner_payout_requests;

create or replace function public.refund_rejected_payout()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'rejected' and old.status is distinct from 'rejected' then
    update public.profiles
    set balance = balance + old.amount
    where id = old.partner_id;

    -- Flip the original debit row to 'rejected' so it stops reading
    -- as an outstanding pending/paid payout in the history.
    update public.partner_wallet_transactions
    set status = 'rejected',
        description = 'Payout rejected'
    where payout_request_id = old.id
      and type = 'debit';

    insert into public.partner_wallet_transactions (partner_id, payout_request_id, type, amount, description, status)
    values (
      old.partner_id,
      old.id,
      'credit',
      old.amount,
      case
        when new.rejection_reason is not null and length(trim(new.rejection_reason)) > 0
          then 'Refund — payout rejected (' || new.rejection_reason || ')'
        else 'Refund — payout rejected'
      end,
      'refunded'
    );
  end if;
  return new;
end;
$$;

create trigger trg_refund_rejected_payout
  after update on public.partner_payout_requests
  for each row
  execute function public.refund_rejected_payout();

revoke all on function public.refund_rejected_payout() from public, anon, authenticated;

-- ============================================================
-- 5b) admin_reject_payout: a SECURITY DEFINER RPC for rejecting a
--     payout, mirroring admin_mark_payout_paid. This exists because a
--     plain client-side .update() to 'rejected' depends on an RLS
--     UPDATE policy existing for admins — if that policy is missing
--     or misconfigured, Supabase silently returns success with zero
--     rows changed (no error), which looks exactly like "the button
--     did nothing." Routing through this function sidesteps RLS
--     entirely, the same way admin_mark_payout_paid already does.
--     The existing trg_refund_rejected_payout trigger still fires
--     normally on the UPDATE this function performs, so the refund
--     and transaction-history sync keep working unchanged.
-- ============================================================
create or replace function public.admin_reject_payout(p_payout_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  is_caller_admin boolean;
  req record;
begin
  select is_admin into is_caller_admin from public.profiles where id = auth.uid();
  if not coalesce(is_caller_admin, false) then
    raise exception 'Not authorized.' using errcode = 'P0001';
  end if;

  select * into req from public.partner_payout_requests where id = p_payout_id for update;
  if req is null then
    raise exception 'Payout request not found.' using errcode = 'P0001';
  end if;
  if req.status not in ('pending', 'approved') then
    raise exception 'Only pending or approved payouts can be rejected.' using errcode = 'P0001';
  end if;

  update public.partner_payout_requests
  set status = 'rejected',
      rejection_reason = p_reason,
      processed_at = now(),
      processed_by = auth.uid()
  where id = p_payout_id;
end;
$$;

revoke all on function public.admin_reject_payout(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_reject_payout(uuid, text) to authenticated;
-- (same pattern as admin_mark_payout_paid: granting execute to all
-- authenticated users is safe because the is_admin check inside the
-- function is what actually gates who can successfully call it)

-- ============================================================
-- 6) Updated admin_mark_payout_paid: balance was already deducted
--    at request time, so this now only verifies admin + a valid
--    starting status ('pending' or 'approved', to also cover any
--    legacy rows already sitting in 'approved' from before this
--    change) and flips the request straight to 'paid'. No balance
--    change here.
-- ============================================================
create or replace function public.admin_mark_payout_paid(p_payout_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  is_caller_admin boolean;
  req record;
begin
  select is_admin into is_caller_admin from public.profiles where id = auth.uid();
  if not coalesce(is_caller_admin, false) then
    raise exception 'Not authorized.' using errcode = 'P0001';
  end if;

  select * into req from public.partner_payout_requests where id = p_payout_id for update;
  if req is null then
    raise exception 'Payout request not found.' using errcode = 'P0001';
  end if;
  if req.status not in ('pending', 'approved') then
    raise exception 'Only pending or approved payouts can be marked as paid.' using errcode = 'P0001';
  end if;

  update public.partner_payout_requests
  set status = 'paid', processed_at = now(), processed_by = auth.uid()
  where id = p_payout_id;
end;
$$;

revoke all on function public.admin_mark_payout_paid(uuid) from public, anon, authenticated;
grant execute on function public.admin_mark_payout_paid(uuid) to authenticated;
-- (the is_admin check inside the function is still what actually
-- gates who can successfully call this — granting execute to all
-- authenticated users is safe because non-admins will hit the
-- "Not authorized" exception)
