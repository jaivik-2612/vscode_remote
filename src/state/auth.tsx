import AsyncStorage from '@react-native-async-storage/async-storage';
import { Session } from '@supabase/supabase-js';
import React, { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { isSupabaseConfigured } from '../config';
import { isValidEmail, validatePassword } from '../core/password';
import { TERMS_VERSION } from '../core/terms';
import { getSupabase } from './supabase';

/**
 * Authentication state. When Supabase isn't configured the app runs in
 * local-only mode: no gate, no backups — everything else works.
 *
 * Flow: sign up (password policy enforced) → Supabase emails a confirmation
 * link → user confirms → signs in → accepts Terms once → app.
 */

const TOS_KEY = (userId: string) => `lifeos.tos.${TERMS_VERSION}.${userId}`;

export type AuthStatus =
  | 'local-only'   // no backend configured; skip the gate
  | 'loading'
  | 'signed-out'
  | 'needs-terms'
  | 'ready';

/** Profile details collected at sign-up, stored in the auth user's metadata. */
export interface SignUpDetails {
  firstName: string;
  lastName: string;
  country: string;
  region: string;
}

interface AuthValue {
  status: AuthStatus;
  session: Session | null;
  /** Set after a successful sign-up, so the UI can show "check your email". */
  pendingEmail: string | null;
  signUp: (email: string, password: string, details: SignUpDetails) => Promise<string | null>;
  signIn: (email: string, password: string) => Promise<string | null>;
  signOut: () => Promise<void>;
  acceptTerms: () => Promise<void>;
}

const AuthContext = createContext<AuthValue | undefined>(undefined);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const supabase = getSupabase();
  const [session, setSession] = useState<Session | null>(null);
  const [tosAccepted, setTosAccepted] = useState(false);
  const [loading, setLoading] = useState(isSupabaseConfigured());
  const [pendingEmail, setPendingEmail] = useState<string | null>(null);

  useEffect(() => {
    if (!supabase) return;
    supabase.auth
      .getSession()
      .then(({ data }) => setSession(data.session))
      .finally(() => setLoading(false));
    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
    });
    return () => sub.subscription.unsubscribe();
  }, [supabase]);

  useEffect(() => {
    if (!session?.user) {
      setTosAccepted(false);
      return;
    }
    AsyncStorage.getItem(TOS_KEY(session.user.id))
      .then((raw) => setTosAccepted(raw === 'accepted'))
      .catch(() => setTosAccepted(false));
  }, [session?.user?.id]);

  const signUp = async (
    email: string,
    password: string,
    details: SignUpDetails
  ): Promise<string | null> => {
    if (!supabase) return 'Backend not configured.';
    if (!isValidEmail(email)) return 'Enter a valid email address.';
    const check = validatePassword(password);
    if (!check.ok) return check.problems.join(' · ');
    const firstName = details.firstName.trim();
    const lastName = details.lastName.trim();
    const { error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        data: {
          name: `${firstName} ${lastName}`.trim(),
          first_name: firstName,
          last_name: lastName,
          country: details.country,
          region: details.region.trim(),
        },
      },
    });
    if (error) return error.message;
    setPendingEmail(email.trim());
    return null;
  };

  const signIn = async (email: string, password: string): Promise<string | null> => {
    if (!supabase) return 'Backend not configured.';
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) return error.message;
    setPendingEmail(null);
    return null;
  };

  const signOut = async () => {
    if (supabase) await supabase.auth.signOut();
    setSession(null);
  };

  const acceptTerms = async () => {
    if (session?.user) {
      await AsyncStorage.setItem(TOS_KEY(session.user.id), 'accepted').catch(() => {});
    }
    setTosAccepted(true);
  };

  const status: AuthStatus = !isSupabaseConfigured()
    ? 'local-only'
    : loading
      ? 'loading'
      : !session
        ? 'signed-out'
        : !tosAccepted
          ? 'needs-terms'
          : 'ready';

  const value = useMemo(
    () => ({ status, session, pendingEmail, signUp, signIn, signOut, acceptTerms }),
    [status, session, pendingEmail]
  );
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthValue {
  const value = useContext(AuthContext);
  if (!value) throw new Error('useAuth must be used inside AuthProvider');
  return value;
}
