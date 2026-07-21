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
import { COUNTRIES, regionLabelFor, regionOptions, UserProfile } from '../core/resources';
import { EVENT_CATALOG } from '../core/templates';
import { useAuth } from '../state/auth';
import { useStore } from '../state/store';
import { ThemeSetting, useTheme } from '../state/theme';
import { SelectField } from '../components/pickers';
import { Card, Chip, SectionTitle } from '../components/ui';
import { spacing } from '../theme';

const COUNTRY_OPTIONS = COUNTRIES.map((c) => ({ value: c.code, label: c.name }));

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
  const [firstName, setFirstName] = useState(
    existing?.firstName ?? existing?.name?.trim().split(' ')[0] ?? ''
  );
  const [lastName, setLastName] = useState(
    existing?.lastName ?? existing?.name?.trim().split(' ').slice(1).join(' ') ?? ''
  );
  const [country, setCountry] = useState(existing?.country ?? '');
  const [region, setRegion] = useState(existing?.region ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [saved, setSaved] = useState(false);

  const regionLabel = regionLabelFor(country);
  const stateOptions = regionOptions(country);

  const saveProfile = () => {
    const profile: UserProfile = {
      name: `${firstName.trim()} ${lastName.trim()}`.trim(),
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      country,
      region: region.trim(),
      city: city.trim(),
    };
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
        <Text style={[styles.label, { color: colors.muted }]}>First name</Text>
        <TextInput style={inputStyle} value={firstName} onChangeText={setFirstName}
          placeholder="First name" placeholderTextColor={colors.muted} />

        <Text style={[styles.label, { color: colors.muted }]}>Last name</Text>
        <TextInput style={inputStyle} value={lastName} onChangeText={setLastName}
          placeholder="Last name" placeholderTextColor={colors.muted} />

        <Text style={[styles.label, { color: colors.muted }]}>Country</Text>
        <SelectField
          placeholder="Select country"
          title="Select your country"
          value={country}
          options={COUNTRY_OPTIONS}
          onSelect={(code) => {
            setCountry(code);
            setRegion('');
          }}
          style={inputStyle}
        />

        <Text style={[styles.label, { color: colors.muted }]}>{regionLabel}</Text>
        {stateOptions ? (
          <SelectField
            placeholder={`Select ${regionLabel.toLowerCase()}`}
            title={`Select your ${regionLabel.toLowerCase()}`}
            value={region}
            options={stateOptions.map((s) => ({ value: s, label: s }))}
            onSelect={setRegion}
            style={inputStyle}
          />
        ) : (
          <TextInput style={inputStyle} value={region} onChangeText={setRegion}
            placeholder={`e.g. ${country === 'GB' ? 'Greater London' : 'Bavaria'}`}
            placeholderTextColor={colors.muted} />
        )}

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
