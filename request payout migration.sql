-- Atomic payout request. Replaces the previous client-side flow of
-- "insert transactions row, then insert payout_requests row, delete
-- the transaction on failure" — that rollback silently failed because
-- regular users don't (and shouldn't) have DELETE on transactions,
-- leaving an orphaned payout that deducted balance with no
-- payout_requests row for admin to ever process.
--
-- Both inserts now happen in one function. If either fails, the whole
-- thing rolls back automatically — nothing is left half-done.
--
-- This also moves the balance calculation server-side, so a user can't
-- pass an arbitrary amount to the RPC call — the function always pays
-- out exactly the caller's true available balance.

create or replace function request_payout()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_available numeric;
  v_transaction_id uuid;
begin
  if not exists (select 1 from linked_accounts where user_id = auth.uid()) then
    raise exception 'No linked bank account on file';
  end if;

  select
    coalesce(sum(case when type = 'earning' and status = 'completed' then amount else 0 end), 0)
    - coalesce(sum(case when type = 'payout' then amount else 0 end), 0)
    + coalesce(sum(case when type = 'refund' and status = 'completed' then amount else 0 end), 0)
  into v_available
  from transactions
  where user_id = auth.uid();

  if v_available is null or v_available <= 0 then
    raise exception 'No available balance to withdraw';
  end if;

  insert into transactions (user_id, type, status, amount)
  values (auth.uid(), 'payout', 'pending', v_available)
  returning id into v_transaction_id;

  insert into payout_requests (user_id, transaction_id, amount, status)
  values (auth.uid(), v_transaction_id, v_available, 'pending');

  return v_transaction_id;
end;
$$;

grant execute on function request_payout() to authenticated;
