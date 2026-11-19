-- GigGrade cloud sync setup (single user, no login).
-- Paste ALL of this into Supabase → SQL Editor → Run. Safe to run again; it starts fresh.
-- Only your secret key (kept in Codemagic) can read or write these. The public key can't.

drop table if exists public.offers cascade;
drop table if exists public.app_state cascade;
drop policy if exists "Own screenshots read" on storage.objects;
drop policy if exists "Own screenshots add" on storage.objects;
drop policy if exists "Own screenshots change" on storage.objects;
drop policy if exists "Own screenshots remove" on storage.objects;

-- Every offer the screen reader sees
create table public.offers (
  id uuid primary key,
  date timestamptz not null,
  app text not null,
  pay double precision not null,
  miles double precision,
  minutes integer,
  pickup_text text,
  dropoff_text text,
  grade text not null,
  category text not null,
  dollars_per_hour double precision,
  dollars_per_mile double precision,
  route_note text,
  screenshot_path text,
  decision text not null default 'pending',
  pickup_stop jsonb,
  dropoff_stop jsonb,
  updated_at timestamptz not null default now()
);
create index offers_date on public.offers (date);
alter table public.offers enable row level security;   -- no policies = public key locked out

-- Your settings, banner choices, route, location and recording timer (one row)
create table public.app_state (
  id text primary key default 'me',
  settings jsonb,
  notification_prefs jsonb,
  stops jsonb,
  location jsonb,
  broadcast_started_at timestamptz,
  broadcast_heartbeat timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.app_state enable row level security;

-- Private folder for offer screenshots
insert into storage.buckets (id, name, public) values ('screenshots', 'screenshots', false)
on conflict (id) do nothing;

-- Version 4.7: offers the screen reader saw but couldn't read (for diagnosing missed banners)
create table if not exists public.missed_offers (
  id uuid primary key,
  date timestamptz not null,
  reason text not null,
  ocr_text text not null,
  screenshot_path text
);
create index if not exists missed_offers_date on public.missed_offers (date);
alter table public.missed_offers enable row level security;
grant all on public.missed_offers to service_role;
notify pgrst, 'reload schema';
