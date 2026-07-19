import React, { useState } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { PASSWORD_RULES, validatePassword } from '../core/password';
import { useAuth } from '../state/auth';
import { useTheme } from '../state/theme';
import { Card } from '../components/ui';
import { cardShadow, spacing } from '../theme';

/** Sign in / sign up gate shown before the app. */
export default function AuthScreen() {
  const { signIn, signUp, pendingEmail } = useAuth();
  const { colors } = useTheme();
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [awaitingConfirm, setAwaitingConfirm] = useState(false);

  const passwordCheck = validatePassword(password);

  const submit = async () => {
    setBusy(true);
    setError(null);
    const err =
      mode === 'signup' ? await signUp(name, email, password) : await signIn(email, password);
    setBusy(false);
    if (err) {
      setError(err);
    } else if (mode === 'signup') {
      setAwaitingConfirm(true);
    }
  };

  const inputStyle = [
    styles.input,
    { backgroundColor: colors.card, color: colors.ink },
    cardShadow,
  ];

  if (awaitingConfirm) {
    return (
      <View style={[styles.screen, styles.center, { backgroundColor: colors.bg }]}>
        <Text style={{ fontSize: 46 }}>📬</Text>
        <Text style={[styles.title, { color: colors.ink, textAlign: 'center' }]}>
          Check your email
        </Text>
        <Text style={[styles.sub, { color: colors.muted, textAlign: 'center' }]}>
          We sent a confirmation link to{'\n'}
          <Text style={{ fontWeight: '700', color: colors.ink }}>{pendingEmail ?? email}</Text>
          {'\n\n'}Tap the link to activate your account, then sign in here.
        </Text>
        <TouchableOpacity
          style={[styles.cta, { backgroundColor: colors.accent }]}
          onPress={() => {
            setAwaitingConfirm(false);
            setMode('signin');
          }}
        >
          <Text style={[styles.ctaText, { color: colors.onAccent }]}>I’ve confirmed — sign in</Text>
        </TouchableOpacity>
      </View>
    );
  }

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView
        style={[styles.screen, { backgroundColor: colors.bg }]}
        contentContainerStyle={{ flexGrow: 1, justifyContent: 'center' }}
        keyboardShouldPersistTaps="handled"
      >
        <Text style={[styles.logo, { color: colors.ink }]}>LifeOS</Text>
        <Text style={[styles.sub, { color: colors.muted }]}>
          Life’s big moments, minus the paperwork.
        </Text>

        <View style={[styles.toggle, { backgroundColor: colors.card }, cardShadow]}>
          {(['signin', 'signup'] as const).map((m) => (
            <TouchableOpacity
              key={m}
              style={[styles.toggleBtn, mode === m && { backgroundColor: colors.soft }]}
              onPress={() => {
                setMode(m);
                setError(null);
              }}
            >
              <Text
                style={[
                  styles.toggleText,
                  { color: mode === m ? colors.accent : colors.muted },
                ]}
              >
                {m === 'signin' ? 'Sign in' : 'Create account'}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        {mode === 'signup' && (
          <TextInput
            style={inputStyle}
            placeholder="Your name"
            placeholderTextColor={colors.muted}
            value={name}
            onChangeText={setName}
          />
        )}
        <TextInput
          style={inputStyle}
          placeholder="Email"
          placeholderTextColor={colors.muted}
          value={email}
          onChangeText={setEmail}
          autoCapitalize="none"
          keyboardType="email-address"
        />
        <TextInput
          style={inputStyle}
          placeholder="Password"
          placeholderTextColor={colors.muted}
          value={password}
          onChangeText={setPassword}
          secureTextEntry
        />

        {mode === 'signup' && (
          <Card style={{ paddingVertical: 10 }}>
            {PASSWORD_RULES.map((rule) => {
              const met = !passwordCheck.problems.includes(rule) && password.length > 0;
              return (
                <Text
                  key={rule}
                  style={[styles.rule, { color: met ? colors.success : colors.muted }]}
                >
                  {met ? '✓' : '○'} {rule}
                </Text>
              );
            })}
          </Card>
        )}

        {error && <Text style={[styles.error, { color: colors.danger }]}>{error}</Text>}

        <TouchableOpacity
          style={[
            styles.cta,
            { backgroundColor: colors.accent },
            busy && { opacity: 0.6 },
          ]}
          disabled={busy}
          onPress={submit}
        >
          <Text style={[styles.ctaText, { color: colors.onAccent }]}>
            {busy ? 'Please wait…' : mode === 'signin' ? 'Sign in' : 'Create account'}
          </Text>
        </TouchableOpacity>
        <Text style={[styles.hint, { color: colors.muted }]}>
          {mode === 'signup'
            ? 'We’ll email you a confirmation link before your first sign-in.'
            : 'Your plans sync securely to your account for backup.'}
        </Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.lg },
  center: { alignItems: 'center', justifyContent: 'center' },
  logo: { fontSize: 36, fontWeight: '800', textAlign: 'center' },
  sub: { fontSize: 14, textAlign: 'center', marginTop: 6, marginBottom: spacing.lg, lineHeight: 21 },
  toggle: { flexDirection: 'row', borderRadius: 999, padding: 4, marginBottom: spacing.md },
  toggleBtn: { flex: 1, borderRadius: 999, paddingVertical: 10, alignItems: 'center' },
  toggleText: { fontSize: 14, fontWeight: '700' },
  input: {
    borderRadius: 16,
    paddingHorizontal: 18,
    paddingVertical: 14,
    fontSize: 15,
    marginBottom: spacing.sm,
  },
  rule: { fontSize: 12, paddingVertical: 2 },
  error: { fontSize: 13, fontWeight: '600', marginBottom: spacing.sm, textAlign: 'center' },
  title: { fontSize: 24, fontWeight: '800', marginTop: spacing.sm },
  cta: { borderRadius: 24, padding: spacing.md, alignItems: 'center', marginTop: spacing.sm },
  ctaText: { fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, textAlign: 'center', marginTop: spacing.sm },
});
