# Turning on cloud accounts & backup (Supabase)

Out of the box the app runs in **device mode**: sign-up is still mandatory,
but accounts and data live only in the browser. Follow these steps once to
switch on **cloud mode** — real email+password accounts with automatic backup
to a database you own, and restore on any device.

Total time: about 5 minutes. Cost: free (Supabase's free tier is far more
than this app needs — each user stores one small JSON row).

## 1. Create the Supabase project

1. Go to <https://supabase.com> → **Start your project** → sign up (GitHub or
   email).
2. **New project** → pick any name (e.g. `carbon-tracker`), a database
   password (store it somewhere safe; the app never uses it), and the region
   closest to your users — **Canada (Central)** for Canada/US, which also
   keeps the stored data resident in Canada → **Create**.

## 2. Create the backups table

1. In the project's left sidebar open **SQL Editor** → **New query**.
2. Paste this and press **Run**:

```sql
create table public.backups (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  payload    jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.backups enable row level security;

create policy "read own backup"
  on public.backups for select
  using (auth.uid() = user_id);

create policy "insert own backup"
  on public.backups for insert
  with check (auth.uid() = user_id);

create policy "update own backup"
  on public.backups for update
  using (auth.uid() = user_id);
```

The row-level-security policies are what make the published key safe: every
user can only ever read and write **their own** row.

## 3. Email confirmation (this project: ON)

By default Supabase sends a confirmation email before the first sign-in,
and this project **keeps that on** — users must verify they own their email
address before they can sign in. The app handles the flow: after sign-up it
shows "check your email", and sign-in attempts before confirming show
"Email not confirmed".

Because of this, one more setting matters — **where the confirmation link
sends people**. Once the app is hosted:

- **Authentication → URL Configuration → Site URL** → set it to the app's
  public URL (e.g. `https://<your-site>/carbon-tracker/`).

Until that's set, confirmation links redirect to Supabase's default
(`localhost:3000`), which shows users a broken page after confirming —
their account still gets confirmed and sign-in works, but it looks wrong.
Optionally also customise the email template under
**Authentication → Emails**.

(For a personal/family deployment you could instead turn "Confirm email"
off under **Authentication → Sign In / Up → Email** to remove the step
entirely.)

## 4. Paste the keys into the app

1. **Project Settings → API**. Copy:
   - **Project URL** (like `https://abcdefgh.supabase.co`)
   - **anon public** key (the long string — *not* the `service_role` key,
     which must never be published)
2. Edit `carbon-tracker/config.js`:

```js
const CLOUD_CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',
  supabaseAnonKey: 'eyJhbGciOi…',
};
```

3. Commit/redeploy. Done — the app now requires email+password sign-up, and
   every change is backed up to your cloud a couple of seconds later.

## How it behaves

- **Backup**: after any change (log, edit, settings, template) the app waits
  ~2.5 s and uploads the full data snapshot to the user's row. Settings →
  Account shows the last backup time, plus **Back up now** and **Restore from
  cloud** buttons.
- **Restore**: signing in on a fresh device automatically pulls the cloud
  backup. On a device that already has data, use **Restore from cloud**
  (asks for a confirming second tap since it overwrites the device's copy).
- **Offline**: everything keeps working from the on-device copy; backup
  retries automatically when the connection returns.

## Notes & limits

- One snapshot per user, last write wins. If the same account edits on two
  devices at the same time, the later backup overwrites the earlier one —
  fine for backup/restore, not a collaborative sync engine.
- The claude.ai preview artifact cannot reach external servers, so cloud mode
  only works on a real host (GitHub Pages, Netlify, etc.).
- Password resets: Supabase can send reset emails, but the app has no reset
  screen yet — that's a sensible next feature once cloud mode is live.
