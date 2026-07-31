-- ============================================================================
-- EarnOva — sponsored posts: participation & manual-review migration
-- Safe to run even though public.sponsored_posts already exists.
-- Only adds new columns / a new table / new triggers — does not touch
-- or recreate anything that already exists.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. New columns on the existing sponsored_posts table
-- ----------------------------------------------------------------------------
alter table public.sponsored_posts
  add column if not exists min_likes integer,
  add column if not exists review_hold_days integer;


-- ----------------------------------------------------------------------------
-- 2. sponsored_post_participations
-- ----------------------------------------------------------------------------
create table if not exists public.sponsored_post_participations (
  id                  uuid primary key default gen_random_uuid(),
  post_id             uuid not null references public.sponsored_posts(id) on delete cascade,
  user_id             uuid not null references public.profiles(id) on delete cascade,
  social_handle_url   text,
  video_url           text,
  status              text not null default 'pending_submission'
                        check (status in ('pending_submission','submitted','approved','rejected','completed')),
  admin_notes         text,
  submitted_at        timestamptz,
  reviewed_at         timestamptz,
  reviewed_by         uuid references public.profiles(id),
  completed_at        timestamptz,
  credited            boolean not null default false,
  created_at          timestamptz not null default now(),
  unique (post_id, user_id)
);

alter table public.sponsored_post_participations enable row level security;

drop policy if exists "Users can view own participations" on public.sponsored_post_participations;
create policy "Users can view own participations"
  on public.sponsored_post_participations for select
  using (
    user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true)
  );

drop policy if exists "Users can create own participation" on public.sponsored_post_participations;
create policy "Users can create own participation"
  on public.sponsored_post_participations for insert
  with check (user_id = auth.uid());

drop policy if exists "Users and admins can update participations" on public.sponsored_post_participations;
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

drop policy if exists "Admins can delete participations" on public.sponsored_post_participations;
create policy "Admins can delete participations"
  on public.sponsored_post_participations for delete
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));


-- ----------------------------------------------------------------------------
-- 3. Trigger: lock down which fields/status a non-admin can change
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

drop trigger if exists "10_enforce_participation_update" on public.sponsored_post_participations;
create trigger "10_enforce_participation_update"
  before update on public.sponsored_post_participations
  for each row execute function public.enforce_participation_update();


-- ----------------------------------------------------------------------------
-- 4. Trigger: credit the user when an admin marks a submission "completed"
--    NOTE: assumes public.profiles has a numeric "balance" column and
--    public.transactions has (user_id, type, amount, description) columns —
--    adjust the column names below if your actual tables differ.
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

drop trigger if exists "20_credit_sponsored_post_completion" on public.sponsored_post_participations;
create trigger "20_credit_sponsored_post_completion"
  before update on public.sponsored_post_participations
  for each row execute function public.credit_sponsored_post_completion();


-- ============================================================================
-- 5. NEW: "disqualified" status
--
-- Lets an admin disqualify a participant at any point after they've joined —
-- including after their submission was approved or even completed — for
-- reasons discovered later (e.g. abusive use of chat/support, fraud found on
-- re-check, TOS violation). This is a manual admin-only action; non-admins
-- can never set this status (enforce_participation_update above already
-- blocks non-admins from setting any status outside
-- pending_submission/submitted).
--
-- IMPORTANT: disqualifying a participation does NOT automatically claw back
-- a payout that was already credited (credited = true / status was
-- 'completed'). That balance adjustment, if desired, is a separate manual
-- step for the admin/finance team — this migration intentionally does not
-- touch public.profiles.balance here to avoid silently modifying user
-- balances from a status change.
-- ============================================================================

alter table public.sponsored_post_participations
  drop constraint if exists sponsored_post_participations_status_check;

alter table public.sponsored_post_participations
  add constraint sponsored_post_participations_status_check
  check (status in ('pending_submission','submitted','approved','rejected','completed','disqualified'));


-- ============================================================================
-- 6. "Review hold period (days)" replaced by a concrete "campaign ends" date,
--    and the standalone "Deadline" field is retired
--
-- Admins now set the date the campaign itself ends, and submissions are
-- reviewed after that date — instead of a relative number of hold days from
-- when the user submitted, or a separate submission deadline. The old
-- min_likes structured field is also retired: admins now write minimum
-- engagement requirements (likes, views, etc.) directly into the free-text
-- `requirements` field instead.
--
-- Non-destructive: this only adds the new column. The old deadline,
-- min_likes, and review_hold_days columns are left in place (simply no
-- longer read/written by the app) so no historical data is lost; drop them
-- later once you've confirmed nothing else depends on them.
-- ============================================================================

alter table public.sponsored_posts
  add column if not exists campaign_ends_at date;

