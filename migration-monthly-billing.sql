-- ============================================================================
-- Migration: switch account access from a one-time is_activated flag to a
-- manually-renewed monthly paid_until expiry.
-- ============================================================================

-- 1. Add the new expiry column. Null = never paid.
alter table public.profiles
  add column if not exists paid_until timestamptz;

-- 2. Backfill: give already-activated accounts one paid month from today,
--    so nobody currently active gets locked out the moment this ships.
--    Run this once, right after deploying the new activate.html /
--    dashboard.html / paystack-verify code.
update public.profiles
set paid_until = now() + interval '30 days'
where is_activated = true
  and paid_until is null;

-- 3. Drop the old one-time flag once you've confirmed paid_until is working
--    everywhere (activate.html, dashboard.html, and any other gated page).
--    Leave this commented out until you're ready — nothing above depends on
--    is_activated existing, but nothing will break if you leave it for now.
-- alter table public.profiles drop column is_activated;

-- 4. Make sure a payment reference can only ever be recorded once, as a
--    database-level backstop to the idempotency check already done in the
--    paystack-verify edge function.
alter table public.activation_payments
  add constraint activation_payments_reference_key unique (reference);

-- 5. Helpful index for looking up a user's payment history (e.g. a future
--    "billing history" section), and for the edge function's reference
--    lookup.
create index if not exists activation_payments_user_id_idx
  on public.activation_payments (user_id);

-- 6. RLS: users should be able to see their own payment history, but never
--    insert/update rows directly — only the edge function (service role)
--    should write here.
alter table public.activation_payments enable row level security;

drop policy if exists "Users can view own payments" on public.activation_payments;
create policy "Users can view own payments"
  on public.activation_payments
  for select
  using (auth.uid() = user_id);

-- No insert/update/delete policies are created for regular users, which
-- means those operations are denied by default under RLS and only the
-- service-role key (used by the edge function) can write to this table.
