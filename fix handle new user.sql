create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_own_code text;
  v_referrer_id uuid;
begin
  -- Generate this user's own unique shareable code (independent of
  -- whatever code, if any, they entered at signup).
  v_own_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  insert into public.profiles (id, full_name, email, phone, referral_code, is_partner, business_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', ''),
    v_own_code,
    coalesce((new.raw_user_meta_data->>'is_partner')::boolean, false),
    nullif(new.raw_user_meta_data->>'business_name', '')
  );

  -- If they signed up using someone else's code, record the relationship.
  if nullif(new.raw_user_meta_data->>'referral_code', '') is not null then
    select id into v_referrer_id
    from public.profiles
    where referral_code = new.raw_user_meta_data->>'referral_code';

    if v_referrer_id is not null and v_referrer_id <> new.id then
      insert into public.referrals (referrer_id, referred_id)
      values (v_referrer_id, new.id);
    end if;
  end if;

  return new;
end;
$function$;
