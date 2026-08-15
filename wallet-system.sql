-- Run this in Supabase: Project > SQL Editor > New query
-- Adds a wallet balance system: partners top up, and completing a
-- sponsored post submission atomically moves money from the
-- partner's balance to the user's balance.

-- ============================================================
-- 1. Balance column on profiles (used for both partner spending
--    power and user earnings — same column, different direction)
-- ============================================================
alter table public.profiles add column if not exists balance numeric not null default 0;


-- ============================================================
-- 2. wallet_topups — partner-submitted top-up requests, admin-approved
--    (mirrors the existing payout_requests approval pattern)
-- ============================================================
create table if not exists public.wallet_topups (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references auth.users(id),
  amount numeric not null check (amount > 0),
  reference text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_notes text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

alter table public.wallet_topups enable row level security;

drop policy if exists "Partners can view their own topups" on public.wallet_topups;
create policy "Partners can view their own topups"
  on public.wallet_topups for select
  using (auth.uid() = partner_id);

drop policy if exists "Partners can insert their own topups" on public.wallet_topups;
create policy "Partners can insert their own topups"
  on public.wallet_topups for insert
  with check (auth.uid() = partner_id);

drop policy if exists "Admins can view all topups" on public.wallet_topups;
create policy "Admins can view all topups"
  on public.wallet_topups for select
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "Admins can update topups" on public.wallet_topups;
create policy "Admins can update topups"
  on public.wallet_topups for update
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true))
  with check (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));


-- ============================================================
-- 3. approve_topup / reject_topup — admin-only, atomic balance credit
-- ============================================================
create or replace function public.approve_topup(p_topup_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_partner uuid;
  v_amount numeric;
  v_status text;
begin
  select is_admin into v_is_admin from public.profiles where id = auth.uid();
  if not coalesce(v_is_admin, false) then
    raise exception 'Not authorized';
  end if;

  select partner_id, amount, status into v_partner, v_amount, v_status
  from public.wallet_topups where id = p_topup_id
  for update;

  if v_status is null then
    raise exception 'Top-up not found';
  end if;
  if v_status <> 'pending' then
    raise exception 'This top-up has already been processed';
  end if;

  update public.wallet_topups
    set status = 'approved', reviewed_at = now()
    where id = p_topup_id;

  update public.profiles
    set balance = balance + v_amount
    where id = v_partner;
end;
$$;

create or replace function public.reject_topup(p_topup_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_status text;
begin
  select is_admin into v_is_admin from public.profiles where id = auth.uid();
  if not coalesce(v_is_admin, false) then
    raise exception 'Not authorized';
  end if;

  select status into v_status from public.wallet_topups where id = p_topup_id for update;

  if v_status is null then
    raise exception 'Top-up not found';
  end if;
  if v_status <> 'pending' then
    raise exception 'This top-up has already been processed';
  end if;

  update public.wallet_topups
    set status = 'rejected', admin_notes = p_reason, reviewed_at = now()
    where id = p_topup_id;
end;
$$;


-- ============================================================
-- 4. complete_sponsored_submission — admin-only, atomic payout:
--    debits the partner, credits the user, marks the submission
--    completed. If the partner can't afford it, the campaign is
--    hidden (is_active = false) and the call fails loudly instead
--    of silently completing a payout nobody can cover.
-- ============================================================
create or replace function public.complete_sponsored_submission(p_submission_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin boolean;
  v_status text;
  v_user_id uuid;
  v_post_id uuid;
  v_payout numeric;
  v_partner_id uuid;
  v_partner_balance numeric;
begin
  select is_admin into v_is_admin from public.profiles where id = auth.uid();
  if not coalesce(v_is_admin, false) then
    raise exception 'Not authorized';
  end if;

  select status, user_id, post_id
    into v_status, v_user_id, v_post_id
  from public.sponsored_post_participations
  where id = p_submission_id
  for update;

  if v_status is null then
    raise exception 'Submission not found';
  end if;
  if v_status <> 'approved' then
    raise exception 'Submission must be approved before it can be completed';
  end if;

  select payout, created_by into v_payout, v_partner_id
  from public.sponsored_posts
  where id = v_post_id
  for update;

  if v_partner_id is null then
    raise exception 'This campaign has no owning partner account on file — cannot charge for payout';
  end if;

  select balance into v_partner_balance
  from public.profiles
  where id = v_partner_id
  for update;

  if v_partner_balance < v_payout then
    update public.sponsored_posts set is_active = false where id = v_post_id;
    raise exception 'Partner balance is too low to cover this payout — campaign has been hidden';
  end if;

  update public.profiles set balance = balance - v_payout where id = v_partner_id;
  update public.profiles set balance = balance + v_payout where id = v_user_id;

  update public.sponsored_post_participations
    set status = 'completed', reviewed_at = now()
    where id = p_submission_id;
end;
$$;


-- ============================================================
-- 5. Safety net trigger — whenever a partner's balance drops,
--    automatically hide any of their active sponsored_posts they
--    can no longer afford (covers cases outside the RPC above too,
--    e.g. manual balance adjustments).
-- ============================================================
create or replace function public.hide_underfunded_sponsored_posts()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.balance < OLD.balance then
    update public.sponsored_posts
      set is_active = false
      where created_by = NEW.id
        and is_active = true
        and payout > NEW.balance;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_hide_underfunded_posts on public.profiles;
create trigger trg_hide_underfunded_posts
after update of balance on public.profiles
for each row
execute function public.hide_underfunded_sponsored_posts();
