-- Add payment tracking columns to challenge_submissions
alter table challenge_submissions
  add column payment_reference text,
  add column amount_paid numeric;

-- Prevent the same Paystack reference from being used on more than one row
create unique index if not exists challenge_submissions_payment_reference_key
  on challenge_submissions (payment_reference)
  where payment_reference is not null;

-- Client can no longer insert directly (payment must be verified by the
-- verify-join edge function using the service role) — drop any policy
-- that previously allowed authenticated users to INSERT here directly.
drop policy if exists "users can insert own submission" on challenge_submissions;
