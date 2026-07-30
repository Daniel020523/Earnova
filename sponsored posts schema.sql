-- ============================================================================
-- EarnOva — sponsored_posts table
-- Matches sponsoredpost.html and sponsoredpostadmin.html exactly.
-- Uses uuid ids like your existing jobs/profiles/transactions tables.
-- ============================================================================

create extension if not exists "pgcrypto";

create table public.sponsored_posts (
  id                  uuid primary key default gen_random_uuid(),
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
  posted_by           uuid references public.profiles(id),
  is_active           boolean not null default true,
  created_at          timestamptz not null default now()
);

alter table public.sponsored_posts enable row level security;

-- Anyone can read active campaigns (used by sponsoredpost.html)
create policy "Public can read active sponsored posts"
  on public.sponsored_posts for select
  using (is_active = true);

-- Admins can do everything, including see inactive campaigns
-- (used by sponsoredpostadmin.html)
create policy "Admins can manage sponsored posts"
  on public.sponsored_posts for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));
