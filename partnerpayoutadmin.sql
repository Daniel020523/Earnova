-- ============================================================
-- partnerpayoutadmin.html — schema additions
-- Run this once in the Supabase SQL editor.
-- ============================================================

-- 1. Admin flag on profiles
alter table profiles
  add column if not exists is_admin boolean not null default false;

-- To make yourself an admin, run (replace with your user id/email):
-- update profiles set is_admin = true where id = 'YOUR-USER-UUID';

-- 2. Extra tracking columns on payout_requests
alter table payout_requests
  add column if not exists processed_at timestamptz,
  add column if not exists processed_by uuid references auth.users(id),
  add column if not exists rejection_reason text;

-- 3. Helpful indexes for the admin table/filters
create index if not exists payout_requests_status_idx on payout_requests(status);
create index if not exists payout_requests_partner_id_idx on payout_requests(partner_id);
create index if not exists payout_requests_created_at_idx on payout_requests(created_at desc);

-- ============================================================
-- 4. Admin-check helper function
--    SECURITY DEFINER so it can read profiles.is_admin without
--    triggering RLS recursion when used inside a profiles policy.
-- ============================================================
create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

-- ============================================================
-- 5. RLS policies
-- ============================================================
alter table profiles enable row level security;
alter table payout_requests enable row level security;

-- Admins can view every partner's profile (read-only — needed to
-- see who a payout request belongs to / their balance).
drop policy if exists "Admins can view all profiles" on profiles;
create policy "Admins can view all profiles"
  on profiles for select
  using (is_admin());

-- Admins can view every payout request (not just their own, unlike
-- the existing partner-facing policy).
drop policy if exists "Admins can view all payout requests" on payout_requests;
create policy "Admins can view all payout requests"
  on payout_requests for select
  using (is_admin());

-- Admins can move a request between pending / approved / rejected
-- directly. Note: 'paid' is deliberately excluded here — that
-- transition is only allowed through the admin_mark_payout_paid()
-- function below, so a balance deduction can never be skipped.
drop policy if exists "Admins can update payout request status" on payout_requests;
create policy "Admins can update payout request status"
  on payout_requests for update
  using (is_admin())
  with check (is_admin() and status in ('pending', 'approved', 'rejected'));

-- ============================================================
-- 6. Atomic "mark as paid" function
--    Verifies the caller is an admin, checks the request is
--    'approved', deducts the amount from the partner's balance,
--    and flips the request to 'paid' — all in one transaction.
-- ============================================================
create or replace function public.admin_mark_payout_paid(p_payout_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id uuid;
  v_amount numeric;
  v_status text;
  v_balance numeric;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  select partner_id, amount, status
    into v_partner_id, v_amount, v_status
  from payout_requests
  where id = p_payout_id
  for update;

  if v_status is null then
    raise exception 'Payout request not found';
  end if;

  if v_status <> 'approved' then
    raise exception 'Payout must be approved before it can be marked paid';
  end if;

  select balance into v_balance
  from profiles
  where id = v_partner_id
  for update;

  if v_balance is null or v_balance < v_amount then
    raise exception 'Partner balance is insufficient to cover this payout';
  end if;

  update profiles
  set balance = balance - v_amount
  where id = v_partner_id;

  update payout_requests
  set status = 'paid',
      processed_at = now(),
      processed_by = auth.uid()
  where id = p_payout_id;
end;
$$;

grant execute on function public.admin_mark_payout_paid(uuid) to authenticated;
grant execute on function public.is_admin() to authenticated;
