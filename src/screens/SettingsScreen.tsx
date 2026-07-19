import React, { useState } from 'react';
import {
  Alert,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { COUNTRIES, UserProfile } from '../core/resources';
import { EVENT_CATALOG } from '../core/templates';
import { useAuth } from '../state/auth';
import { useStore } from '../state/store';
import { ThemeSetting, useTheme } from '../state/theme';
import { Card, Chip, SectionTitle } from '../components/ui';
import { spacing } from '../theme';

const THEME_OPTIONS: { value: ThemeSetting; label: string }[] = [
  { value: 'light', label: '☀️ Light' },
  { value: 'dark', label: '🌙 Dark' },
  { value: 'system', label: '⚙️ System' },
];

/** App settings: profile, appearance, data, and about. */
export default function SettingsScreen() {
  const { state, dispatch } = useStore();
  const { colors, setting, setSetting } = useTheme();
  const { status: authStatus, session, signOut } = useAuth();

  const existing = state.profile;
  const [name, setName] = useState(existing?.name ?? '');
  const [country, setCountry] = useState(existing?.country ?? '');
  const [region, setRegion] = useState(existing?.region ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [saved, setSaved] = useState(false);

  const regionLabel = COUNTRIES.find((c) => c.code === country)?.regionLabel ?? 'State / region';

  const saveProfile = () => {
    const profile: UserProfile = { name: name.trim(), country, region: region.trim(), city: city.trim() };
    dispatch({ type: 'setProfile', profile });
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  const inputStyle = [
    styles.input,
    { backgroundColor: colors.bg, borderColor: colors.line, color: colors.ink },
  ];

  const stats = EVENT_CATALOG.reduce(
    (a, e) => ({
      tasks: a.tasks + e.tasks.length,
      steps: a.steps + e.tasks.reduce((n, t) => n + (t.steps?.length ?? 0), 0),
    }),
    { tasks: 0, steps: 0 }
  );

  const clearPlans = () =>
    Alert.alert('Delete all plans', 'Remove every plan and its progress? Profile and settings are kept.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete all',
        style: 'destructive',
        onPress: () => {
          for (const plan of state.plans) dispatch({ type: 'removePlan', planId: plan.id });
        },
      },
    ]);

  return (
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Text style={[styles.heading, { color: colors.ink }]}>Settings</Text>

      <SectionTitle>Account</SectionTitle>
      <Card>
        {authStatus === 'local-only' ? (
          <Text style={[styles.hint, { color: colors.muted, marginTop: 0 }]}>
            Running in local-only mode — plans stay on this device. Cloud accounts and backup
            activate once the backend is configured.
          </Text>
        ) : (
          <>
            <Text style={[styles.accountEmail, { color: colors.ink }]}>
              {session?.user?.email ?? '—'}
            </Text>
            <Text style={[styles.hint, { color: colors.muted }]}>
              Plans back up to your account automatically.
            </Text>
            <TouchableOpacity onPress={signOut}>
              <Text style={[styles.dangerText, { color: colors.danger }]}>Sign out</Text>
            </TouchableOpacity>
          </>
        )}
      </Card>

      <SectionTitle>Profile</SectionTitle>
      <Card>
        <Text style={[styles.label, { color: colors.muted }]}>Name</Text>
        <TextInput style={inputStyle} value={name} onChangeText={setName} placeholder="Your name"
          placeholderTextColor={colors.muted} />

        <Text style={[styles.label, { color: colors.muted }]}>Country</Text>
        <View style={styles.chipRow}>
          {COUNTRIES.map((c) => (
            <Chip key={c.code} label={c.name} selected={country === c.code} onPress={() => setCountry(c.code)} />
          ))}
        </View>

        <Text style={[styles.label, { color: colors.muted }]}>{regionLabel}</Text>
        <TextInput style={inputStyle} value={region} onChangeText={setRegion}
          placeholder={`e.g. ${country === 'CA' ? 'Ontario' : country === 'GB' ? 'Greater London' : 'California'}`}
          placeholderTextColor={colors.muted} />

        <Text style={[styles.label, { color: colors.muted }]}>City</Text>
        <TextInput style={inputStyle} value={city} onChangeText={setCity} placeholder="City"
          placeholderTextColor={colors.muted} />

        <TouchableOpacity style={[styles.cta, { backgroundColor: colors.accent }]} onPress={saveProfile}>
          <Text style={[styles.ctaText, { color: colors.onAccent }]}>
            {saved ? 'Saved ✓' : 'Save profile'}
          </Text>
        </TouchableOpacity>
        <Text style={[styles.hint, { color: colors.muted }]}>
          Powers country-specific task links and product storefronts. Stored only on this device.
        </Text>
      </Card>

      <SectionTitle>Appearance</SectionTitle>
      <Card>
        <Text style={[styles.label, { color: colors.ink }]}>Theme</Text>
        <View style={styles.chipRow}>
          {THEME_OPTIONS.map((opt) => (
            <Chip
              key={opt.value}
              label={opt.label}
              selected={setting === opt.value}
              onPress={() => setSetting(opt.value)}
            />
          ))}
        </View>
      </Card>

      <SectionTitle>Data</SectionTitle>
      <Card>
        <TouchableOpacity onPress={clearPlans}>
          <Text style={[styles.dangerText, { color: colors.danger }]}>Delete all plans</Text>
        </TouchableOpacity>
        <Text style={[styles.hint, { color: colors.muted }]}>Profile and settings are kept.</Text>
      </Card>

      <SectionTitle>About</SectionTitle>
      <Card>
        <Text style={[styles.about, { color: colors.muted }]}>
          LifeOS 0.1.0 — Universal Life Administration Platform.{'\n'}
          {EVENT_CATALOG.length} life events · {stats.tasks} tasks · {stats.steps} checkable steps.
          {'\n'}All data stays on this device.
        </Text>
      </Card>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '800', marginTop: spacing.md, marginBottom: spacing.sm },
  label: {
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.xs,
    marginTop: spacing.sm,
  },
  input: { borderWidth: 1, borderRadius: 12, padding: spacing.sm, fontSize: 15 },
  cta: { borderRadius: 24, padding: spacing.md, alignItems: 'center', marginTop: spacing.md },
  ctaText: { fontSize: 16, fontWeight: '700' },
  themeLabel: { fontSize: 15, fontWeight: '600', marginBottom: spacing.sm },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  dangerText: { fontSize: 15, fontWeight: '600', paddingVertical: 4 },
  accountEmail: { fontSize: 15, fontWeight: '700' },
  hint: { fontSize: 12, marginTop: 2 },
  about: { fontSize: 13, lineHeight: 22 },
});
