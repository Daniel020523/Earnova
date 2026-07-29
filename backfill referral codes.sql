-- Run this AFTER the fix_handle_new_user.sql above.
-- Regenerates a fresh unique referral_code for every existing profile,
-- since the old values were never actually their own code (see bug above).
update public.profiles
set referral_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

-- Optional but recommended: enforce uniqueness going forward.
alter table public.profiles
  add constraint profiles_referral_code_key unique (referral_code);
