-- ============================================================================
-- EarnOva — Supabase schema
-- Covers: jobs.html, sponsoredpost.html / sponsoredpostadmin.html,
--         affiliate.html / affiliateadmin.html
--
-- Run this in the Supabase SQL editor. Adjust types/defaults to taste.
-- Column names here match exactly what the front-end JS in each page
-- selects/inserts/updates — rename in both places together if you change them.
-- ============================================================================

-- Needed for gen_random_uuid()
create extension if not exists "pgcrypto";


-- ============================================================================
-- 1. JOBS  (jobs.html)
-- ============================================================================
create table if not exists public.jobs (
  id                integer generated always as identity primary key,
  title             text not null,
  company           text not null,
  location          text not null,
  job_type          text not null check (job_type in ('Full-time','Part-time','Contract','Internship')),
  salary_range      text,
  summary           text,
  requirements      text,
  responsibilities  text,
  work_schedule     text,
  rules             text,
  apply_link        text,
  apply_email       text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);

alter table public.jobs enable row level security;

-- Anyone can read active job listings.
create policy "Public can read active jobs"
  on public.jobs for select
  using (is_active = true);


-- ============================================================================
-- 2. SPONSORED POSTS  (sponsoredpost.html / sponsoredpostadmin.html)
-- ============================================================================
create table if not exists public.sponsored_posts (
  id                  integer generated always as identity primary key,
  title               text not null,
  brand               text not null,
  platform            text not null check (platform in ('Instagram','TikTok','YouTube','X','Blog')),
  payout              numeric(10,2) not null default 0,
  summary             text,
  requirements        text,
  content_guidelines  text,
  deadline            date,
  apply_link          text,
  apply_email         text,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);

alter table public.sponsored_posts enable row level security;

create policy "Public can read active sponsored posts"
  on public.sponsored_posts for select
  using (is_active = true);


-- ============================================================================
-- 3. AFFILIATE PROGRAM  (affiliate.html / affiliateadmin.html)
-- ============================================================================

-- Commission tiers, e.g. Starter / Silver / Gold based on referral count.
create table if not exists public.commission_tiers (
  id             integer generated always as identity primary key,
  name           text not null,
  min_referrals  integer not null default 0,
  max_referrals  integer,               -- null = no upper bound
  rate           numeric(5,2) not null default 0,   -- percent, e.g. 12.5
  sort_order     integer not null default 0
);

alter table public.commission_tiers enable row level security;

create policy "Public can read commission tiers"
  on public.commission_tiers for select
  using (true);

-- Seed a default set of tiers.
insert into public.commission_tiers (name, min_referrals, max_referrals, rate, sort_order)
values
  ('Starter', 0, 5, 10, 0),
  ('Silver',  6, 15, 15, 1),
  ('Gold',    16, null, 20, 2)
on conflict do nothing;


-- One row per affiliate/user.
create table if not exists public.affiliates (
  id               integer generated always as identity primary key,
  user_id          uuid not null references auth.users(id) on delete cascade,
  name             text,
  email            text,
  referral_code    text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  total_earnings   numeric(10,2) not null default 0,
  pending_earnings numeric(10,2) not null default 0,
  referral_count   integer not null default 0,
  tier_id          integer references public.commission_tiers(id),
  created_at       timestamptz not null default now(),

  unique (user_id)
);

alter table public.affiliates enable row level security;

-- Affiliates can read only their own row.
create policy "Affiliates can read their own record"
  on public.affiliates for select
  using (auth.uid() = user_id);

-- An affiliate row is created automatically the first time a user
-- needs one — allow a user to insert only their own row.
create policy "Users can create their own affiliate record"
  on public.affiliates for insert
  with check (auth.uid() = user_id);


-- People referred by an affiliate.
create table if not exists public.referrals (
  id                 integer generated always as identity primary key,
  affiliate_id       integer not null references public.affiliates(id) on delete cascade,
  referred_name      text,
  referred_email     text,
  status             text not null default 'pending' check (status in ('pending','confirmed')),
  commission_earned  numeric(10,2) not null default 0,
  created_at         timestamptz not null default now()
);

alter table public.referrals enable row level security;

-- Affiliates can see only the referrals that belong to them.
create policy "Affiliates can read their own referrals"
  on public.referrals for select
  using (
    exists (
      select 1 from public.affiliates a
      where a.id = referrals.affiliate_id
        and a.user_id = auth.uid()
    )
  );


-- Products affiliates can promote (added via affiliateadmin.html).
create table if not exists public.products (
  id                integer generated always as identity primary key,
  name              text not null,
  price             numeric(10,2) not null default 0,
  commission_rate   numeric(5,2) not null default 0,   -- percent
  category          text,
  image_url         text,
  description       text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);

alter table public.products enable row level security;

create policy "Public can read active products"
  on public.products for select
  using (is_active = true);


-- ============================================================================
-- 4. ADMIN ACCESS
-- ============================================================================
-- None of the tables above grant public/anon INSERT, UPDATE, or DELETE —
-- the admin pages (affiliateadmin.html, sponsoredpostadmin.html) call
-- .insert() / .update() / .delete() using the anon key, which will be
-- rejected until you add write policies.
--
-- Do NOT simply open these tables up to any authenticated user — that
-- would let any signed-in user edit tiers, products, or campaigns.
-- Instead, gate writes behind an admin flag. One common pattern:
--
-- create table if not exists public.admin_users (
--   user_id uuid primary key references auth.users(id) on delete cascade
-- );
--
-- create policy "Admins can manage jobs"
--   on public.jobs for all
--   using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
--   with check (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));
--
-- Repeat similarly for sponsored_posts, commission_tiers, and products.
-- Add the current admin's uuid to admin_users to grant access:
--   insert into public.admin_users (user_id) values ('<uuid-here>');
--
-- Alternatively, keep the admin pages behind a server-side route that
-- uses the Supabase service_role key (never expose that key in the browser).
