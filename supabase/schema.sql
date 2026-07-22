-- LifeOS Supabase schema. Run this in the SQL editor of your Supabase project.
--
-- Auth itself (users, passwords, email confirmation) is handled by Supabase
-- Auth — no tables needed here. This file adds the backup storage.

-- One backup row per user: the full app state as JSON.
create table if not exists public.user_backups (
  user_id uuid primary key references auth.users (id) on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

-- Row-level security: users can only touch their own backup.
alter table public.user_backups enable row level security;

create policy "users manage own backup"
  on public.user_backups
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Dashboard checklist (Authentication → Providers → Email):
--   1. "Confirm email" must be ON (it is by default) so sign-ups get a
--      confirmation link before they can sign in.
--   2. Authentication → URL Configuration: set the Site URL to your landing
--      page (the confirmation link redirects there after activating).
--   3. Optional: Authentication → Passwords — set minimum length to 8 to
--      match the client-side policy.
