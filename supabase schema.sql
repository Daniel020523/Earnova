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

-- =========================================================
-- 4. Job board: jobs table + admin flag
--    Set a user's profiles.is_admin = true manually in the
--    Table Editor to give them access to jobadmin.html.
-- =========================================================
alter table public.profiles add column if not exists is_admin boolean not null default false;

create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  company text not null,
  location text not null default 'Remote',
  job_type text not null default 'Full-time',
  salary_range text,
  description text not null,
  apply_link text,
  apply_email text,
  posted_by uuid references auth.users(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.jobs enable row level security;

-- Anyone (including logged-out visitors) can see active job posts
drop policy if exists "Anyone can view active jobs" on public.jobs;
create policy "Anyone can view active jobs"
  on public.jobs for select
  using (is_active = true);

-- Admins can see every job post, active or hidden
drop policy if exists "Admins can view all jobs" on public.jobs;
create policy "Admins can view all jobs"
  on public.jobs for select
  using (exists(select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- Only admins can create job posts
drop policy if exists "Admins can insert jobs" on public.jobs;
create policy "Admins can insert jobs"
  on public.jobs for insert
  with check (exists(select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- Only admins can edit job posts (e.g. hide/unhide)
drop policy if exists "Admins can update jobs" on public.jobs;
create policy "Admins can update jobs"
  on public.jobs for update
  using (exists(select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- Only admins can delete job posts
drop policy if exists "Admins can delete jobs" on public.jobs;
create policy "Admins can delete jobs"
  on public.jobs for delete
  using (exists(select 1 from public.profiles where id = auth.uid() and is_admin = true));
