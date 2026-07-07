/*
 * Cloud backend configuration.
 *
 * Leave both values empty to run in device-accounts mode (data stays in the
 * browser). To turn on cloud accounts with backup/restore — mandatory
 * email+password sign-up — create a free Supabase project and paste its URL
 * and anon (public) key here. Step-by-step instructions: SETUP-CLOUD.md.
 *
 * The anon key is safe to publish: it only allows what the database's
 * row-level-security policies permit (each user can touch only their own row).
 */
const CLOUD_CONFIG = {
  supabaseUrl: 'https://cljkprrtnmydroalzycw.supabase.co',
  supabaseAnonKey: 'sb_publishable_MnE-xOMeBF5iiQHD3zX9_Q_jDO0V4nn',
};
