CREATE OR REPLACE FUNCTION public.request_payout()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    + coalesce(sum(case when type = 'referral' and status = 'completed' then amount else 0 end), 0)
  into v_available
  from transactions
  where user_id = auth.uid();

  if v_available is null or v_available <= 0 then
    raise exception 'No available balance to withdraw';
  end if;

  insert into transactions (user_id, type, status, amount)
  values (auth.uid(), 'payout', 'pending', v_available)
  returning id into v_transaction_id;

  -- payout_requests row is created by the on_payout_transaction_created
  -- trigger on the transactions insert above, which also pulls the correct
  -- bank details from linked_accounts. Do not insert it here too.

  return v_transaction_id;
end;
$function$
