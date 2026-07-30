-- ============================================================================
-- EarnOva — Affiliate program (product-based)
-- Separate from the existing "referrals" (invite-a-friend) system.
-- Matches existing conventions: uuid ids, profiles.id as user ref,
-- transactions ledger for balances, status = 'completed' (not 'confirmed').
-- ============================================================================

create extension if not exists "pgcrypto";


-- 1. Products available to promote
create table public.products (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  price             numeric(10,2) not null default 0,
  commission_rate   numeric(5,2) not null default 0,   -- base % commission
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


-- 2. Each user's personal link for a product they've chosen to promote
create table public.affiliate_links (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete cascade,
  code         text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
  clicks       integer not null default 0,
  created_at   timestamptz not null default now(),

  unique (user_id, product_id)
);

alter table public.affiliate_links enable row level security;

create policy "Users can read their own affiliate links"
  on public.affiliate_links for select
  using (auth.uid() = user_id);

create policy "Users can create their own affiliate links"
  on public.affiliate_links for insert
  with check (auth.uid() = user_id);


-- 3. Sales recorded when someone buys through a link
create table public.affiliate_sales (
  id                  uuid primary key default gen_random_uuid(),
  affiliate_link_id   uuid not null references public.affiliate_links(id) on delete cascade,
  buyer_name          text,
  buyer_email         text,
  sale_amount         numeric(10,2) not null default 0,
  commission_amount   numeric(10,2) not null default 0,
  status              text not null default 'pending' check (status in ('pending','completed')),
  created_at          timestamptz not null default now()
);

alter table public.affiliate_sales enable row level security;

create policy "Users can read sales on their own links"
  on public.affiliate_sales for select
  using (
    exists (
      select 1 from public.affiliate_links al
      where al.id = affiliate_sales.affiliate_link_id
        and al.user_id = auth.uid()
    )
  );


-- 4. Commission tiers — bonus % on top of a product's base commission_rate,
--    based on a user's total completed sales count.
create table public.commission_tiers (
  id           integer generated always as identity primary key,
  name         text not null,
  min_sales    integer not null default 0,
  max_sales    integer,               -- null = no upper bound
  bonus_rate   numeric(5,2) not null default 0,   -- extra %, e.g. 5 = +5%
  sort_order   integer not null default 0
);

alter table public.commission_tiers enable row level security;

create policy "Public can read commission tiers"
  on public.commission_tiers for select
  using (true);

insert into public.commission_tiers (name, min_sales, max_sales, bonus_rate, sort_order)
values
  ('Starter', 0, 9, 0, 0),
  ('Silver',  10, 49, 5, 1),
  ('Gold',    50, null, 10, 2);


-- ============================================================================
-- 5. Auto-post to the transactions ledger when a sale is marked completed
-- ============================================================================
-- Mirrors how "referral" commissions already land in transactions
-- (type = 'referral', status = 'completed'). This does the same for
-- affiliate sales so balances / payout_requests work the same way.

create or replace function public.post_affiliate_commission()
returns trigger
language plpgsql
security definer
as $$
declare
  v_user_id uuid;
begin
  if new.status = 'completed' and (old.status is distinct from 'completed') then
    select user_id into v_user_id
    from public.affiliate_links
    where id = new.affiliate_link_id;

    insert into public.transactions (user_id, amount, type, status, created_at)
    values (v_user_id, new.commission_amount, 'affiliate_commission', 'completed', now());
  end if;
  return new;
end;
$$;

create trigger trg_affiliate_commission
  after insert or update of status on public.affiliate_sales
  for each row
  execute function public.post_affiliate_commission();


-- ============================================================================
-- 6. Admin write access
-- ============================================================================
-- Your profiles table already has is_admin — use it to gate writes,
-- consistent with the rest of the app.

create policy "Admins can manage products"
  on public.products for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

create policy "Admins can manage commission tiers"
  on public.commission_tiers for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

create policy "Admins can manage affiliate sales"
  on public.affiliate_sales for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

create policy "Admins can read all affiliate links"
  on public.affiliate_links for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));
