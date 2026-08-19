-- ============================================================
-- Server-side gating for the review/claim flow:
--   1. A verification code + server timestamp, issued when the
--      user starts the review, that must be presented at claim time.
--   2. A minimum elapsed-time requirement between start and claim.
-- Adjust MIN_SECONDS below to change the minimum dwell time.
-- ============================================================

create table if not exists review_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  target_url text not null,
  verification_code text not null,
  started_at timestamptz not null default now(),
  used boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists review_attempts_user_target_idx
  on review_attempts (user_id, target_url, used);

alter table review_attempts enable row level security;

-- Users can only see their own attempts (not strictly required since
-- everything goes through SECURITY DEFINER functions, but keeps the
-- table safe if it's ever queried directly from the client).
create policy "own review attempts" on review_attempts
  for select using (auth.uid() = user_id);


-- ------------------------------------------------------------
-- start_review_task: called when the user clicks "Start review".
-- Issues a short verification code and stamps the server-side
-- start time. Enforces the same daily limit used elsewhere so a
-- user can't rack up unused attempts once they're already capped.
-- ------------------------------------------------------------
create or replace function start_review_task(p_target_url text)
returns table (verification_code text, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_daily_limit int := 5;   -- keep in sync with DAILY_LIMIT_DISPLAY in the front end
  v_used_today int;
  v_code text;
begin
  select count(*) into v_used_today
  from transactions
  where user_id = auth.uid()
    and type = 'review'
    and created_at >= date_trunc('day', now());

  if v_used_today >= v_daily_limit then
    return query select null::text, 'daily_limit_reached';
    return;
  end if;

  v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

  insert into review_attempts (user_id, target_url, verification_code)
  values (auth.uid(), p_target_url, v_code);

  return query select v_code, null::text;
end;
$$;


-- ------------------------------------------------------------
-- submit_review_and_claim: now requires the verification code
-- issued by start_review_task, and enforces a minimum elapsed
-- time since that code was issued, in addition to whatever
-- checks already existed (daily limit, reward amount, etc).
-- Adjust MIN_SECONDS to change the minimum dwell time.
-- ------------------------------------------------------------
create or replace function submit_review_and_claim(
  p_target_url text,
  p_answer_activity text,
  p_answer_about text,
  p_verification_code text
)
returns table (claimed boolean, amount numeric, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reward numeric := 50;      -- keep in sync with REWARD_DISPLAY in the front end
  v_daily_limit int := 5;      -- keep in sync with DAILY_LIMIT_DISPLAY in the front end
  v_min_seconds int := 20;     -- <-- minimum time between start and claim
  v_used_today int;
  v_attempt review_attempts%rowtype;
  v_txn_id uuid;
begin
  select count(*) into v_used_today
  from transactions
  where user_id = auth.uid()
    and type = 'review'
    and created_at >= date_trunc('day', now());

  if v_used_today >= v_daily_limit then
    return query select false, null::numeric, 'daily_limit_reached';
    return;
  end if;

  select * into v_attempt
  from review_attempts
  where user_id = auth.uid()
    and target_url = p_target_url
    and verification_code = upper(p_verification_code)
    and used = false
  order by started_at desc
  limit 1;

  if v_attempt.id is null then
    return query select false, null::numeric, 'invalid_or_used_code';
    return;
  end if;

  if now() - v_attempt.started_at < make_interval(secs => v_min_seconds) then
    return query select false, null::numeric, 'too_fast';
    return;
  end if;

  update review_attempts set used = true where id = v_attempt.id;

  insert into transactions (user_id, type, amount, status)
  values (auth.uid(), 'review', v_reward, 'completed')
  returning id into v_txn_id;

  insert into review_submissions (user_id, transaction_id, target_url, answer_activity, answer_about)
  values (auth.uid(), v_txn_id, p_target_url, p_answer_activity, p_answer_about);

  return query select true, v_reward, null::text;
end;
$$;

-- NOTE: this assumes a review_submissions table already exists per the
-- comment in the original claim.html (user_id, transaction_id, target_url,
-- answer_activity, answer_about, ...). Adjust the insert above to match
-- your actual schema/column names if it differs.
