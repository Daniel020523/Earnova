-- =========================================================
-- Referral / "share your link" reward system
-- Run this in the Supabase SQL editor.
-- =========================================================

-- 1. One unique short code per user
create table if not exists referral_codes (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  code       text unique not null default substr(md5(gen_random_uuid()::text), 1, 8),
  created_at timestamptz not null default now()
);

alter table referral_codes enable row level security;

drop policy if exists "select own ref code" on referral_codes;
create policy "select own ref code" on referral_codes
  for select using (auth.uid() = user_id);

drop policy if exists "insert own ref code" on referral_codes;
create policy "insert own ref code" on referral_codes
  for insert with check (auth.uid() = user_id);

-- 2. Every rewarded click, one row per (link, device) — permanent lock, not daily.
--    If you already ran an earlier version of this file, run this first:
--    alter table referral_clicks drop constraint if exists referral_clicks_ref_code_device_id_click_date_key;
create table if not exists referral_clicks (
  id         uuid primary key default gen_random_uuid(),
  ref_code   text not null references referral_codes(code) on delete cascade,
  device_id  uuid not null,
  click_date date not null default current_date,
  created_at timestamptz not null default now(),
  unique (ref_code, device_id)
);

alter table referral_clicks enable row level security;

-- Owners can see click counts for their own link (via their own code)
drop policy if exists "select own referral clicks" on referral_clicks;
create policy "select own referral clicks" on referral_clicks
  for select using (
    ref_code in (select code from referral_codes where user_id = auth.uid())
  );
-- No client-side insert policy — inserts only happen inside the function below.

-- 3. Atomic "record click + pay reward" function.
--    Runs as the table owner, so it bypasses RLS and the reward amount
--    can't be tampered with from the browser.
create or replace function claim_referral_click(p_ref_code text, p_device_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
  v_visitor_id uuid := auth.uid(); -- null if visitor isn't logged in
  v_reward numeric := 1;
begin
  select user_id into v_owner_id from referral_codes where code = p_ref_code;

  if v_owner_id is null then
    return json_build_object('ok', false, 'reason', 'invalid_code');
  end if;

  if v_visitor_id is not null and v_visitor_id = v_owner_id then
    return json_build_object('ok', false, 'reason', 'self_click');
  end if;

  begin
    insert into referral_clicks (ref_code, device_id) values (p_ref_code, p_device_id);
  exception when unique_violation then
    return json_build_object('ok', false, 'reason', 'already_claimed_today');
  end;

  insert into transactions (user_id, type, status, amount, verification_status)
  values (v_owner_id, 'referral_click', 'completed', v_reward, 'auto');

  return json_build_object('ok', true, 'reward', v_reward);
end;
$$;

grant execute on function claim_referral_click(text, uuid) to anon, authenticated;

-- 4. Helper the logged-in user calls to fetch (or lazily create) their own code.
create or replace function get_or_create_ref_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  select code into v_code from referral_codes where user_id = auth.uid();
  if v_code is null then
    insert into referral_codes (user_id) values (auth.uid())
    returning code into v_code;
  end if;
  return v_code;
end;
$$;

grant execute on function get_or_create_ref_code() to authenticated;

-- =========================================================
-- DIAGNOSTIC: run this manually in the SQL editor to check setup.
-- Replace 'YOURCODE' with a real code from `select * from referral_codes;`
-- =========================================================
-- select claim_referral_click('YOURCODE', gen_random_uuid());
--
-- Expected: {"ok": true, "reward": 1}
-- If you get a permission/role error instead, the grants above didn't apply —
-- re-run just the "grant execute" lines.
-- If it returns {"ok": false, "reason": "invalid_code"}, that ref code
-- doesn't exist in referral_codes — the user hasn't loaded share-earn.html
-- yet (which is what creates it), or you copied the wrong code.
