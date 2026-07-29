-- Fixes: "Could not find a relationship between 'payout_requests' and
-- 'profiles' in the schema cache"
--
-- admin.html embeds profiles and linked_accounts under payout_requests
-- (e.g. .select('..., profiles ( full_name ), linked_accounts (...)')).
-- PostgREST can only auto-resolve that kind of embedded join when an
-- actual foreign key exists. transactions.user_id already has one
-- (that's why the Earnings section works) — payout_requests.user_id
-- doesn't yet.

-- 1. Link payout_requests.user_id -> profiles.id
alter table payout_requests
  add constraint payout_requests_user_id_fkey
  foreign key (user_id) references profiles(id);

-- 2. If payout_requests.user_id is not already backed by a unique/PK
--    index on the referenced side, the constraint above will fail —
--    but profiles.id is the primary key, so this should be fine.

-- 3. Ask PostgREST to refresh its schema cache so it picks up the new
--    relationship immediately instead of waiting for the next auto
--    refresh. (In the Supabase dashboard this also happens automatically
--    a few seconds after a DDL change, but this makes it immediate.)
notify pgrst, 'reload schema';
