/**
 * Runtime configuration. Supabase credentials come from Expo public env vars
 * (set in .env / EAS secrets — see supabase/README section in the repo README).
 * Until they are set, the app runs in local-only mode with no sign-in gate,
 * so development and the web bench keep working without a backend.
 */

export const SUPABASE_URL = process.env.EXPO_PUBLIC_SUPABASE_URL ?? '';
export const SUPABASE_ANON_KEY = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY ?? '';

export function isSupabaseConfigured(): boolean {
  return SUPABASE_URL.startsWith('https://') && SUPABASE_ANON_KEY.length > 20;
}
