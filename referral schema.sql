-- Records who referred whom. One row per referred user (a user can only
-- have been referred by one person, hence unique on referred_id).
create table public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles(id),
  referred_id uuid not null unique references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.referrals enable row level security;

create policy "Users can view referrals they made"
  on public.referrals for select
  using (auth.uid() = referrer_id);

-- Lets us later show "which friend earned you this" on referral.html,
-- without changing how existing transaction rows are read anywhere else.
alter table public.transactions
  add column if not exists source_user_id uuid references public.profiles(id);

-- Allow the new 'referral' transaction type alongside the existing ones.
alter table public.transactions
  drop constraint transactions_type_check;

alter table public.transactions
  add constraint transactions_type_check
  check (type = any (array['earning'::text, 'payout'::text, 'refund'::text, 'referral'::text]));

-- Fires every time a referred user's earning becomes 'completed' (whether
-- inserted that way directly, or approved later from 'pending' in
-- admin.html) and pays their referrer 5% as a 'referral' transaction.
create or replace function public.handle_referral_commission()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_referrer_id uuid;
  v_commission numeric;
begin
  if new.type = 'earning' and new.status = 'completed'
     and (TG_OP = 'INSERT' or old.status is distinct from 'completed') then

    select referrer_id into v_referrer_id
    from referrals
    where referred_id = new.user_id;

    if v_referrer_id is not null then
      v_commission := round(new.amount * 0.05, 2);

      insert into transactions (user_id, type, status, amount, source_user_id)
      values (v_referrer_id, 'referral', 'completed', v_commission, new.user_id);
    end if;
  end if;

  return new;
end;
$function$;

create trigger on_earning_completed_referral_commission
  after insert or update on public.transactions
  for each row
  execute function public.handle_referral_commission();
