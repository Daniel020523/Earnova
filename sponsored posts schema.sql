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
  -- Campaign performance requirements, shown to users and used by admins
  -- when deciding whether a submission is ready to be marked complete.
  min_likes           integer,           -- e.g. 1000 = requires at least 1,000 likes
  review_hold_days    integer,           -- e.g. 3 or 4 = admin waits this many days before reviewing/crediting
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


-- ============================================================================
-- sponsored_post_participations
-- Tracks a user joining a campaign, posting their content, and submitting
-- the video for manual admin review. Reward is only credited once an admin
-- explicitly marks a submission "completed" — never automatically on submit.
--
-- Status lifecycle:
--   pending_submission -> user has joined, hasn't submitted a video yet
--   submitted           -> user submitted their video url, awaiting review
--   approved             -> admin reviewed and approved (content/engagement ok),
--                           but payout not yet released (e.g. still inside the
--                           campaign's review_hold_days / likes-threshold window)
--   rejected              -> admin rejected; admin_notes holds the reason;
--                           user may resubmit (app resets back to pending_submission)
--   completed             -> admin clicked "Complete" — payout has been credited
-- ============================================================================

create table public.sponsored_post_participations (
  id                  uuid primary key default gen_random_uuid(),
  post_id             uuid not null references public.sponsored_posts(id) on delete cascade,
  user_id             uuid not null references public.profiles(id) on delete cascade,
  social_handle_url   text,
  video_url           text,
  status              text not null default 'pending_submission'
                        check (status in ('pending_submission','submitted','approved','rejected','completed')),
  admin_notes         text,          -- e.g. rejection reason, or reviewer comments
  submitted_at        timestamptz,   -- when the user submitted their video url
  reviewed_at         timestamptz,   -- when an admin approved/rejected
  reviewed_by         uuid references public.profiles(id),
  completed_at        timestamptz,   -- when the admin marked it complete / credited
  credited            boolean not null default false,
  created_at          timestamptz not null default now(),
  unique (post_id, user_id)  -- one participation per user per campaign
);

alter table public.sponsored_post_participations enable row level security;

-- Users can see their own participations; admins can see everyone's.
create policy "Users can view own participations"
  on public.sponsored_post_participations for select
  using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true)
  );

-- Users can join a campaign (create their own participation row).
create policy "Users can create own participation"
  on public.sponsored_post_participations for insert
  with check (user_id = auth.uid());

-- Users can update their own row (e.g. add video_url); admins can update any
-- row (e.g. approve/reject/complete). Fine-grained field locking (so a user
-- can't set their own status to "approved"/"completed" or credit themselves)
-- is enforced below by the enforce_participation_update trigger, since
-- Postgres RLS alone can't restrict individual columns per-role here.
create policy "Users and admins can update participations"
  on public.sponsored_post_participations for update
  using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true)
  )
  with check (
    user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true)
  );

-- Only admins can delete participations.
create policy "Admins can delete participations"
  on public.sponsored_post_participations for delete
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));


-- ----------------------------------------------------------------------------
-- Trigger: enforce_participation_update
-- Locks down which fields a non-admin (the participant) is allowed to touch,
-- and which status transitions they're allowed to make on their own row.
-- Runs BEFORE the crediting trigger (name-ordered: 10_ before 20_).
-- ----------------------------------------------------------------------------
create or replace function public.enforce_participation_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  acting_is_admin boolean;
begin
  select exists (
    select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true
  ) into acting_is_admin;

  if not acting_is_admin then
    if old.user_id <> auth.uid() then
      raise exception 'Not allowed to modify this participation';
    end if;

    if old.status not in ('pending_submission','submitted') then
      raise exception 'This submission has already been reviewed and can no longer be edited';
    end if;

    if new.status not in ('pending_submission','submitted') then
      raise exception 'Not allowed to set that status';
    end if;

    -- lock every admin-only / system-only field to its previous value
    new.admin_notes  := old.admin_notes;
    new.reviewed_at  := old.reviewed_at;
    new.reviewed_by  := old.reviewed_by;
    new.completed_at := old.completed_at;
    new.credited     := old.credited;
    new.post_id      := old.post_id;
    new.user_id      := old.user_id;
  end if;

  return new;
end;
$$;

create trigger "10_enforce_participation_update"
  before update on public.sponsored_post_participations
  for each row execute function public.enforce_participation_update();


-- ----------------------------------------------------------------------------
-- Trigger: credit_sponsored_post_completion
-- Fires when a row's status is set to 'completed' for the first time.
-- Credits the user's balance and logs a transaction. SECURITY DEFINER so it
-- can write to profiles/transactions regardless of the caller's own RLS.
--
-- NOTE: this assumes public.profiles has a numeric "balance" column and
-- public.transactions has (user_id, type, amount, description) columns —
-- adjust the column names below to match your actual tables.
-- ----------------------------------------------------------------------------
create or replace function public.credit_sponsored_post_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  post_payout numeric(10,2);
  post_title  text;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' and new.credited = false then
    select payout, title into post_payout, post_title
    from public.sponsored_posts where id = new.post_id;

    update public.profiles
      set balance = coalesce(balance, 0) + coalesce(post_payout, 0)
      where id = new.user_id;

    insert into public.transactions (user_id, type, amount, description)
    values (
      new.user_id,
      'sponsored_post_payout',
      coalesce(post_payout, 0),
      'Sponsored post payout: ' || coalesce(post_title, 'Campaign')
    );

    new.credited     := true;
    new.completed_at := now();
    new.reviewed_by  := auth.uid();
  end if;

  return new;
end;
$$;

create trigger "20_credit_sponsored_post_completion"
  before update on public.sponsored_post_participations
  for each row execute function public.credit_sponsored_post_completion();
