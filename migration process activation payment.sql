-- Migration: atomic activation-payment processing
--
-- Run this in the Supabase SQL editor (or via `supabase db push` if you
-- keep migrations in your repo).
--
-- Why: paystack-verify (client-triggered) and paystack-webhook
-- (server-triggered) can both fire for the same payment. Previously each
-- function did "insert into activation_payments" then "update profiles"
-- as two separate steps — if the insert succeeded but the update failed
-- (network blip, etc.), a retry would see the payment as already recorded
-- and skip re-processing, silently leaving paid_until un-extended.
--
-- This function makes both steps one atomic transaction, and handles the
-- verify/webhook race safely: whichever call arrives first extends
-- paid_until; the other is a no-op that just returns the current value.

-- 1. Reference must be unique — this is what lets us detect "already
--    processed" and is what the function's race-handling relies on.
--    Safe to run even if the constraint already exists.
create unique index if not exists activation_payments_reference_key
  on public.activation_payments (reference);

-- 2. The atomic function itself.
create or replace function public.process_activation_payment(
  p_user_id uuid,
  p_reference text,
  p_amount integer,
  p_access_period_days integer
) returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_paid_until timestamptz;
  v_extend_from timestamptz;
  v_new_paid_until timestamptz;
begin
  -- Try to record the payment. If `reference` was already inserted by the
  -- other path (verify vs webhook racing each other), this raises
  -- unique_violation — caught below — and we do NOT extend paid_until
  -- again for the same payment.
  begin
    insert into activation_payments (user_id, reference, amount, status)
    values (p_user_id, p_reference, p_amount, 'success');
  exception when unique_violation then
    select paid_until into v_current_paid_until
    from profiles
    where id = p_user_id;

    return v_current_paid_until;
  end;

  -- Lock this user's profile row for the rest of the transaction. This
  -- serializes concurrent calls for the SAME user with DIFFERENT
  -- references (e.g. two separate renewal payments happening close
  -- together) so neither reads a stale paid_until.
  select paid_until into v_current_paid_until
  from profiles
  where id = p_user_id
  for update;

  -- Extend from the later of "now" or the current paid_until, so paying
  -- a few days early adds to remaining time instead of resetting it.
  v_extend_from := greatest(coalesce(v_current_paid_until, now()), now());
  v_new_paid_until := v_extend_from + (p_access_period_days || ' days')::interval;

  update profiles
  set paid_until = v_new_paid_until
  where id = p_user_id;

  return v_new_paid_until;
end;
$$;

-- 3. Only the service role (used by both edge functions via
--    SUPABASE_SERVICE_ROLE_KEY) should be able to call this — it bypasses
--    RLS by design (security definer), so it must not be reachable by
--    ordinary user sessions.
revoke all on function public.process_activation_payment(uuid, text, integer, integer) from public;
grant execute on function public.process_activation_payment(uuid, text, integer, integer) to service_role;
