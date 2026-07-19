import { Plan } from '../core/types';
import { UserProfile } from '../core/resources';
import { getSupabase } from './supabase';

/**
 * Cloud backup: one JSONB row per user in public.user_backups (RLS-protected,
 * see supabase/schema.sql). The device remains the source of truth; the
 * backup exists so a reinstall or new device can restore.
 */

export interface BackupPayload {
  version: 1;
  profile: UserProfile | null;
  plans: Plan[];
}

let timer: ReturnType<typeof setTimeout> | null = null;

/** Debounced upsert of the user's state; safe to call on every change. */
export function queueBackup(userId: string, payload: BackupPayload): void {
  const supabase = getSupabase();
  if (!supabase) return;
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    supabase
      .from('user_backups')
      .upsert({ user_id: userId, payload, updated_at: new Date().toISOString() })
      .then(({ error }) => {
        if (error) console.warn('backup failed:', error.message);
      });
  }, 2000);
}

/** Fetch the user's backup, or null when none exists. */
export async function fetchBackup(userId: string): Promise<BackupPayload | null> {
  const supabase = getSupabase();
  if (!supabase) return null;
  const { data, error } = await supabase
    .from('user_backups')
    .select('payload')
    .eq('user_id', userId)
    .maybeSingle();
  if (error || !data) return null;
  return data.payload as BackupPayload;
}
