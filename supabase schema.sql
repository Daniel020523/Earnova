-- =========================================================
-- EarnOva signup schema
-- Run this in Supabase SQL Editor (Project > SQL Editor > New query)
-- =========================================================

-- 1. Profiles table (extra info not stored in auth.users)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  phone text not null unique,
  referral_code text,
  is_partner boolean not null default false,
  business_name text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Users can only read their own profile
drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
  on public.profiles for select
  using (auth.uid() = id);

-- Users can only update their own profile
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
  on public.profiles for update
  using (auth.uid() = id);

-- No public insert policy: rows are created only by the trigger below (security definer),
-- so the anon key can never write directly into profiles.

-- =========================================================
-- 2. Trigger: auto-create a profile row whenever a new auth user signs up.
--    Expects full_name, phone, referral_code, is_partner to be passed in
--    via supabase.auth.signUp({ options: { data: {...} } })
-- =========================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, phone, referral_code, is_partner, business_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', ''),
    nullif(new.raw_user_meta_data->>'referral_code', ''),
    coalesce((new.raw_user_meta_data->>'is_partner')::boolean, false),
    nullif(new.raw_user_meta_data->>'business_name', '')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- 3. RPC: check if email or phone is already taken, BEFORE calling auth.signUp.
--    security definer lets anon users call this without any select access
--    to the profiles table itself, so no data is exposed.
-- =========================================================
create or replace function public.check_existing_user(p_email text, p_phone text)
returns table(email_exists boolean, phone_exists boolean)
language sql
security definer
set search_path = public
as $$
  select
    exists(select 1 from public.profiles where email = p_email) as email_exists,
    exists(select 1 from public.profiles where phone = p_phone) as phone_exists;
$$;

grant execute on function public.check_existing_user(text, text) to anon, authenticated;
