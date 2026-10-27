-- =====================================================================
-- Meuro Market Run: Supabase database setup (Version 8)
-- Paste all of this into Supabase: SQL Editor > New query > Run.
-- It is safe to run more than once.
--
-- Security model
--  * Row Level Security is ON for every table.
--  * Players never write tables directly. Every change goes through a
--    checked function (RPC) that validates input and rate-limits.
--  * Emails live only in `profiles`, readable by the owner of the row and
--    by admins. Public tables (scores, daily_scores, crews) hold no emails.
--  * Admins are listed in `public.admins` (no emails in the website code).
--  * Live play runs on private Realtime channels: signed-in players only.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- admins
create table if not exists public.admins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.admins enable row level security;
-- No policies: nobody can read or change this table through the API.

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------- helpers
create or replace function public.clean_name(p text, p_min int, p_max int)
returns text language sql immutable as $$
  select nullif(left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[^[:alnum:] ._''-]', '', 'g'), '\s+', ' ', 'g')), p_max), '')
$$;

create or replace function public.utc_today()
returns date language sql stable as $$ select (now() at time zone 'utc')::date $$;

-- ---------------------------------------------------------------- profiles
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  name            text not null check (char_length(name) between 2 and 20 and name ~ '^[[:alnum:] ._''-]+$'),
  email           text not null check (char_length(email) <= 254),
  consent         boolean not null default false,
  keke_color      text not null default '#F2C230' check (keke_color ~ '^#[0-9A-F]{6}$'),
  rides           int not null default 0 check (rides >= 0),
  streak          int not null default 0 check (streak >= 0),
  best_streak     int not null default 0 check (best_streak >= 0),
  last_day        date,
  last_ride_at    timestamptz,
  challenges_done int not null default 0 check (challenges_done >= 0),
  badges          text[] not null default '{}',
  countries       text[] not null default '{}',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated using (id = auth.uid() or public.is_admin());

-- Create the profile automatically when someone signs up.
-- Name and consent come from the sign-up form; the email comes from Supabase Auth itself.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  v_name := public.clean_name(new.raw_user_meta_data->>'name', 2, 20);
  if v_name is null or char_length(v_name) < 2 then
    v_name := coalesce(public.clean_name(split_part(new.email, '@', 1), 2, 20), 'Rider');
    if char_length(v_name) < 2 then v_name := 'Rider'; end if;
  end if;
  insert into public.profiles (id, name, email, consent)
  values (new.id, v_name, lower(new.email), coalesce((new.raw_user_meta_data->>'consent')::boolean, false))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- crews
create table if not exists public.crews (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null unique references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 3 and 24 and name ~ '^[[:alnum:] ._''-]+$'),
  created_at timestamptz not null default now()
);
create unique index if not exists crews_name_unique on public.crews (lower(name));
alter table public.crews enable row level security;
drop policy if exists "crews are public" on public.crews;
create policy "crews are public" on public.crews for select to anon, authenticated using (true);

-- ---------------------------------------------------------------- scores (all-time leaderboard)
create table if not exists public.scores (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  best       int  not null default 0 check (best between 0 and 100),
  stars      int  not null default 0 check (stars between 0 and 3),
  dish       text not null default '' check (char_length(dish) <= 40),
  country    text not null default '' check (country ~ '^([a-z]{2})?$'),
  crew_id    uuid references public.crews(id) on delete set null,
  rides      int  not null default 0,
  hidden     boolean not null default false,
  updated_at timestamptz not null default now()
);
create index if not exists scores_best_idx on public.scores (best desc, updated_at);
create index if not exists scores_crew_idx on public.scores (crew_id);
alter table public.scores enable row level security;
drop policy if exists "scores are public" on public.scores;
create policy "scores are public" on public.scores for select to anon, authenticated using (not hidden);

-- ---------------------------------------------------------------- daily scores (Market of the Day)
create table if not exists public.daily_scores (
  day        date not null,
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  score      int  not null check (score between 0 and 100),
  stars      int  not null check (stars between 0 and 3),
  dish       text not null check (char_length(dish) <= 40),
  hidden     boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (day, user_id)
);
create index if not exists daily_scores_board_idx on public.daily_scores (day, score desc, updated_at);
alter table public.daily_scores enable row level security;
drop policy if exists "daily scores are public" on public.daily_scores;
create policy "daily scores are public" on public.daily_scores for select to anon, authenticated using (not hidden);

-- ---------------------------------------------------------------- price reports (players report real prices)
create table if not exists public.price_reports (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  country    text not null check (country ~ '^[a-z]{2}$'),
  item       text not null check (item ~ '^[a-z]{2,20}$'),
  amount     numeric(14,2) not null check (amount > 0 and amount < 100000000),
  currency   text not null check (currency ~ '^[A-Z]{3}$'),
  place      text check (place is null or char_length(place) <= 40),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);
create index if not exists price_reports_lookup_idx on public.price_reports (status, country, item, created_at desc);
create index if not exists price_reports_user_idx on public.price_reports (user_id, created_at desc);
alter table public.price_reports enable row level security;
drop policy if exists "read own price reports" on public.price_reports;
create policy "read own price reports" on public.price_reports
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------------------------------------------------------------- lock down direct access
revoke all on public.admins, public.profiles, public.crews, public.scores, public.daily_scores, public.price_reports from anon, authenticated;
grant select on public.crews, public.scores, public.daily_scores to anon, authenticated;
grant select on public.profiles, public.price_reports to authenticated;

-- =====================================================================
-- Player functions (RPC). Each one checks who is calling and what they send.
-- =====================================================================

create or replace function public.update_profile(p_name text, p_consent boolean, p_keke text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  v_name := public.clean_name(p_name, 2, 20);
  if v_name is null or char_length(v_name) < 2 then raise exception 'bad_name'; end if;
  if p_keke is not null and upper(p_keke) not in ('#F2C230','#4FA866','#2F7FD6','#E5533D','#9B59D0','#16B5A6','#E84393','#F27B2B','#1E1E1E','#F4F1EA') then
    raise exception 'bad_colour';
  end if;
  update public.profiles set name = v_name, consent = coalesce(p_consent, consent),
         keke_color = coalesce(upper(p_keke), keke_color), updated_at = now()
   where id = v_uid;
  update public.scores set name = v_name where user_id = v_uid;
  update public.daily_scores set name = v_name where user_id = v_uid and day = public.utc_today();
end $$;

-- Record a finished ride: updates streak, badges, all-time best and (if it was the
-- Market of the Day) today's board. Rate-limited to one ride per 20 seconds.
create or replace function public.record_ride(
  p_dish text, p_country text, p_score int, p_stars int, p_daily boolean,
  p_all_items boolean, p_budget_left numeric, p_veg int, p_junk int, p_challenge boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_today date := public.utc_today(); p public.profiles; v_badges text[]; v_streak int;
  v_expected_stars int;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_dish !~ '^[a-z0-9_-]{2,30}$' or p_country !~ '^[a-z]{2}$' then raise exception 'bad_input'; end if;
  if p_score is null or p_score < 0 or p_score > 100 then raise exception 'bad_score'; end if;
  v_expected_stars := case when p_score >= 85 then 3 when p_score >= 65 then 2 when p_score >= 40 then 1 else 0 end;
  if p_stars is distinct from v_expected_stars then raise exception 'bad_stars'; end if;
  if coalesce(p_veg, 0) not between 0 and 10 or coalesce(p_junk, 0) not between 0 and 40
     or coalesce(p_budget_left, 0) < -10 or coalesce(p_budget_left, 0) > 1 then raise exception 'bad_input'; end if;

  select * into p from public.profiles where id = v_uid for update;
  if not found then raise exception 'no_profile'; end if;
  if p.last_ride_at is not null and p.last_ride_at > now() - interval '20 seconds' then raise exception 'too_fast'; end if;

  v_streak := case when p.last_day = v_today then p.streak
                   when p.last_day = v_today - 1 then p.streak + 1
                   else 1 end;
  v_badges := p.badges;
  if not ('first_ride' = any(v_badges)) then v_badges := array_append(v_badges, 'first_ride'); end if;
  if p_all_items and not ('list_master' = any(v_badges)) then v_badges := array_append(v_badges, 'list_master'); end if;
  if p_all_items and p_budget_left >= 0.2 and not ('budget_boss' = any(v_badges)) then v_badges := array_append(v_badges, 'budget_boss'); end if;
  if p_veg >= 3 and not ('veg_lover' = any(v_badges)) then v_badges := array_append(v_badges, 'veg_lover'); end if;
  if v_streak >= 3 and not ('streak_3' = any(v_badges)) then v_badges := array_append(v_badges, 'streak_3'); end if;
  if v_streak >= 7 and not ('streak_7' = any(v_badges)) then v_badges := array_append(v_badges, 'streak_7'); end if;
  if p_daily and p_stars = 3 and not ('daily_star' = any(v_badges)) then v_badges := array_append(v_badges, 'daily_star'); end if;
  if p_challenge and p.challenges_done + 1 >= 5 and not ('challenger' = any(v_badges)) then v_badges := array_append(v_badges, 'challenger'); end if;

  update public.profiles set
    rides = rides + 1, last_ride_at = now(), last_day = v_today, streak = v_streak,
    best_streak = greatest(best_streak, v_streak),
    challenges_done = challenges_done + case when p_challenge then 1 else 0 end,
    countries = case when p_country = any(countries) then countries else array_append(countries, p_country) end,
    badges = v_badges, updated_at = now()
  where id = v_uid returning * into p;
  if array_length(p.countries, 1) >= 5 and not ('explorer' = any(p.badges)) then
    update public.profiles set badges = array_append(badges, 'explorer') where id = v_uid returning * into p;
  end if;

  insert into public.scores as s (user_id, name, best, stars, dish, country, rides, updated_at)
  values (v_uid, p.name, p_score, p_stars, p_dish, p_country, 1, now())
  on conflict (user_id) do update set
    name = excluded.name, rides = s.rides + 1, updated_at = now(),
    best = greatest(s.best, excluded.best),
    stars = case when excluded.best > s.best then excluded.stars else s.stars end,
    dish = case when excluded.best > s.best then excluded.dish else s.dish end,
    country = case when excluded.best > s.best then excluded.country else s.country end;

  if p_daily then
    insert into public.daily_scores as d (day, user_id, name, score, stars, dish)
    values (v_today, v_uid, p.name, p_score, p_stars, p_dish)
    on conflict (day, user_id) do update set
      name = excluded.name, updated_at = now(),
      score = greatest(d.score, excluded.score),
      stars = case when excluded.score > d.score then excluded.stars else d.stars end;
  end if;

  return jsonb_build_object('streak', p.streak, 'best_streak', p.best_streak, 'badges', p.badges,
    'countries', p.countries, 'rides', p.rides, 'challenges_done', p.challenges_done);
end $$;

create or replace function public.create_crew(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_name text; v_id uuid; p public.profiles;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  v_name := public.clean_name(p_name, 3, 24);
  if v_name is null or char_length(v_name) < 3 then raise exception 'bad_name'; end if;
  if exists (select 1 from public.crews where owner = v_uid) then raise exception 'already_has_crew'; end if;
  if exists (select 1 from public.crews where lower(name) = lower(v_name)) then raise exception 'name_taken'; end if;
  insert into public.crews (owner, name) values (v_uid, v_name) returning id into v_id;
  select * into p from public.profiles where id = v_uid;
  insert into public.scores (user_id, name, crew_id) values (v_uid, p.name, v_id)
  on conflict (user_id) do update set crew_id = v_id, updated_at = now();
  return v_id;
end $$;

create or replace function public.set_crew(p_crew uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p public.profiles;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_crew is not null and not exists (select 1 from public.crews where id = p_crew) then raise exception 'no_such_crew'; end if;
  select * into p from public.profiles where id = v_uid;
  if not found then raise exception 'no_profile'; end if;
  insert into public.scores (user_id, name, crew_id) values (v_uid, p.name, p_crew)
  on conflict (user_id) do update set crew_id = p_crew, updated_at = now();
end $$;

-- Crew board: each crew's top 5 riders, added up.
create or replace function public.crew_board()
returns table (crew_id uuid, name text, members int, points int)
language sql stable security definer set search_path = public as $$
  with ranked as (
    select s.crew_id, s.best, row_number() over (partition by s.crew_id order by s.best desc) as rn
    from public.scores s where s.crew_id is not null and not s.hidden)
  select c.id, c.name,
         (select count(*)::int from public.scores s2 where s2.crew_id = c.id and not s2.hidden),
         coalesce((select sum(r.best)::int from ranked r where r.crew_id = c.id and r.rn <= 5), 0)
  from public.crews c
  order by 4 desc, 3 desc, c.created_at
  limit 100;
$$;

-- Players report what they really paid. Max 10 reports per player per day.
create or replace function public.report_price(p_country text, p_item text, p_amount numeric, p_currency text, p_place text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if (select count(*) from public.price_reports where user_id = v_uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many_reports';
  end if;
  insert into public.price_reports (user_id, country, item, amount, currency, place)
  values (v_uid, p_country, p_item, p_amount, upper(p_currency), nullif(left(public.clean_name(p_place, 0, 40), 40), ''));
end $$;

-- Approved prices from the last 90 days (median per country and item). Public.
create or replace function public.approved_prices()
returns table (country text, item text, price numeric, reports int)
language sql stable security definer set search_path = public as $$
  select country, item, round(percentile_cont(0.5) within group (order by amount)::numeric, 2), count(*)::int
  from public.price_reports
  where status = 'approved' and created_at > now() - interval '90 days'
  group by country, item;
$$;

-- Players can delete their own account and everything linked to it.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  delete from auth.users where id = v_uid;
end $$;

-- =====================================================================
-- Admin functions (only people listed in public.admins)
-- =====================================================================
create or replace function public.admin_signups(p_limit int default 1000)
returns table (name text, email text, consent boolean, created_at timestamptz, rides int, streak int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select p.name, p.email, p.consent, p.created_at, p.rides, p.streak
    from public.profiles p order by p.created_at desc limit least(greatest(p_limit, 1), 5000);
end $$;

create or replace function public.admin_hide_score(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.scores set hidden = true where user_id = p_user;
  update public.daily_scores set hidden = true where user_id = p_user;
end $$;

create or replace function public.admin_pending_prices()
returns table (id bigint, country text, item text, amount numeric, currency text, place text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select r.id, r.country, r.item, r.amount, r.currency, r.place, r.created_at
    from public.price_reports r where r.status = 'pending' order by r.created_at limit 200;
end $$;

create or replace function public.admin_moderate_price(p_id bigint, p_approve boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.price_reports set status = case when p_approve then 'approved' else 'rejected' end where id = p_id;
end $$;

-- ---------------------------------------------------------------- function permissions
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.crew_board(), public.approved_prices() to anon, authenticated;
grant execute on function
  public.is_admin(), public.update_profile(text, boolean, text),
  public.record_ride(text, text, int, int, boolean, boolean, numeric, int, int, boolean),
  public.create_crew(text), public.set_crew(uuid),
  public.report_price(text, text, numeric, text, text), public.delete_my_account(),
  public.admin_signups(int), public.admin_hide_score(uuid), public.admin_pending_prices(),
  public.admin_moderate_price(bigint, boolean)
to authenticated;

-- =====================================================================
-- Live play: private Realtime channels for signed-in players only.
-- Topics used by the game: market:<n> (the shared market) and race:<code>.
-- =====================================================================
-- Supabase already switches on row level security for realtime.messages, and only its
-- internal owner may alter that table, so only the policies are set here.
drop policy if exists "meuro riders can listen" on realtime.messages;
create policy "meuro riders can listen" on realtime.messages for select to authenticated
  using (realtime.topic() ~ '^(market:[0-9]{1,2}|race:[a-z0-9-]{3,31})$');
drop policy if exists "meuro riders can send" on realtime.messages;
create policy "meuro riders can send" on realtime.messages for insert to authenticated
  with check (realtime.topic() ~ '^(market:[0-9]{1,2}|race:[a-z0-9-]{3,31})$');

-- =====================================================================
-- Make yourself an admin (run once, after you have signed up on the site):
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'you@example.com';
-- =====================================================================
