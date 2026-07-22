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
import { COUNTRIES, regionLabelFor, regionOptions } from '../core/resources';
import { useAuth } from '../state/auth';
import { useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { LogoMark } from '../components/Logo';
import { SelectField } from '../components/pickers';
import { Card } from '../components/ui';
import { cardShadow, spacing } from '../theme';

const COUNTRY_OPTIONS = COUNTRIES.map((c) => ({ value: c.code, label: c.name }));

/** Sign in / sign up gate shown before the app. */
export default function AuthScreen() {
  const { signIn, signUp, pendingEmail } = useAuth();
  const { dispatch } = useStore();
  const { colors } = useTheme();
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [country, setCountry] = useState('');
  const [region, setRegion] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [awaitingConfirm, setAwaitingConfirm] = useState(false);

  const passwordCheck = validatePassword(password);
  const stateOptions = regionOptions(country);

  const submit = async () => {
    setError(null);
    if (mode === 'signup') {
      if (password !== confirm) {
        setError('Passwords do not match.');
        return;
      }
      if (!firstName.trim()) {
        setError('Enter your first name.');
        return;
      }
      if (!country) {
        setError('Select your country.');
        return;
      }
    }
    setBusy(true);
    const err =
      mode === 'signup'
        ? await signUp(email, password, {
            firstName,
            lastName,
            country,
            region,
          })
        : await signIn(email, password);
    setBusy(false);
    if (err) {
      setError(err);
    } else if (mode === 'signup') {
      // Seed the local profile so localized links and product storefronts
      // work from the very first session.
      dispatch({
        type: 'setProfile',
        profile: {
          name: `${firstName.trim()} ${lastName.trim()}`.trim(),
          firstName: firstName.trim(),
          lastName: lastName.trim(),
          country,
          region: region.trim(),
          city: '',
        },
      });
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
        contentContainerStyle={{ flexGrow: 1, justifyContent: 'center', paddingVertical: spacing.lg }}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.logoWrap}>
          <LogoMark size={72} />
        </View>
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
          <>
            <TextInput
              style={inputStyle}
              placeholder="Confirm password"
              placeholderTextColor={colors.muted}
              value={confirm}
              onChangeText={setConfirm}
              secureTextEntry
            />

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
              <Text
                style={[
                  styles.rule,
                  {
                    color:
                      confirm.length > 0
                        ? confirm === password
                          ? colors.success
                          : colors.danger
                        : colors.muted,
                  },
                ]}
              >
                {confirm.length > 0 && confirm === password ? '✓' : '○'} Passwords match
              </Text>
            </Card>

            <Text style={[styles.sectionLabel, { color: colors.muted }]}>About you</Text>
            <View style={styles.nameRow}>
              <TextInput
                style={[...inputStyle, styles.nameField]}
                placeholder="First name"
                placeholderTextColor={colors.muted}
                value={firstName}
                onChangeText={setFirstName}
              />
              <TextInput
                style={[...inputStyle, styles.nameField]}
                placeholder="Last name"
                placeholderTextColor={colors.muted}
                value={lastName}
                onChangeText={setLastName}
              />
            </View>
            <SelectField
              placeholder="Country"
              title="Select your country"
              value={country}
              options={COUNTRY_OPTIONS}
              onSelect={(code) => {
                setCountry(code);
                setRegion('');
              }}
              style={inputStyle}
            />
            {country !== '' &&
              (stateOptions ? (
                <SelectField
                  placeholder={regionLabelFor(country)}
                  title={`Select your ${regionLabelFor(country).toLowerCase()}`}
                  value={region}
                  options={stateOptions.map((s) => ({ value: s, label: s }))}
                  onSelect={setRegion}
                  style={inputStyle}
                />
              ) : (
                <TextInput
                  style={inputStyle}
                  placeholder={regionLabelFor(country)}
                  placeholderTextColor={colors.muted}
                  value={region}
                  onChangeText={setRegion}
                />
              ))}
            <Text style={[styles.hint, { color: colors.muted, marginTop: 0, marginBottom: spacing.sm }]}>
              Your country and state localize task guidance and product links.
            </Text>
          </>
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
  logoWrap: { alignItems: 'center', marginBottom: spacing.sm },
  logo: { fontSize: 32, fontWeight: '800', textAlign: 'center', letterSpacing: -0.5 },
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
  sectionLabel: {
    fontSize: 11,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginTop: spacing.xs,
    marginBottom: spacing.sm,
  },
  nameRow: { flexDirection: 'row', gap: spacing.sm },
  nameField: { flex: 1 },
  rule: { fontSize: 12, paddingVertical: 2 },
  error: { fontSize: 13, fontWeight: '600', marginBottom: spacing.sm, textAlign: 'center' },
  title: { fontSize: 24, fontWeight: '800', marginTop: spacing.sm },
  cta: { borderRadius: 24, padding: spacing.md, alignItems: 'center', marginTop: spacing.sm },
  ctaText: { fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, textAlign: 'center', marginTop: spacing.sm },
});
