-- ============================================================
-- Pickr — Supabase Schema
-- Run once in the Supabase SQL Editor
-- ============================================================

-- ── profiles ────────────────────────────────────────────────
create table if not exists public.profiles (
  id                 uuid references auth.users on delete cascade primary key,
  email              text,
  display_name       text,
  age_group          text,
  gender             text,
  country            text,
  marketing_consent  boolean not null default false,
  data_share_consent boolean not null default false,
  consent_date       timestamptz,
  profile_complete   boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "owner_all" on public.profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);

-- ── taste_profiles ───────────────────────────────────────────
-- Stores the full TasteProfile JSON as text (preserves Int dict keys)
create table if not exists public.taste_profiles (
  user_id    uuid references auth.users on delete cascade primary key,
  data       text not null default '{}',
  updated_at timestamptz not null default now()
);

alter table public.taste_profiles enable row level security;

create policy "owner_all" on public.taste_profiles
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── watchlist ────────────────────────────────────────────────
create table if not exists public.watchlist (
  id        uuid default gen_random_uuid() primary key,
  user_id   uuid references auth.users on delete cascade not null,
  tmdb_id   integer not null,
  added_at  timestamptz not null default now(),
  unique (user_id, tmdb_id)
);

alter table public.watchlist enable row level security;

create policy "owner_all" on public.watchlist
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── auto-update updated_at ───────────────────────────────────
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function update_updated_at();

create trigger taste_profiles_updated_at
  before update on public.taste_profiles
  for each row execute function update_updated_at();

-- ── auto-create profile row on new sign-up ───────────────────
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();
