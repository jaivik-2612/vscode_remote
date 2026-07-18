import React, { useState } from 'react';
import { ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { COUNTRIES, UserProfile } from '../core/resources';
import { useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, Chip } from '../components/ui';
import { spacing } from '../theme';

/**
 * The sign-up / profile form: basic details that let LifeOS localize task
 * guidance and product links to the user's country and region.
 */
export default function ProfileScreen() {
  const { state, dispatch } = useStore();
  const { colors } = useTheme();
  const existing = state.profile;
  const [name, setName] = useState(existing?.name ?? '');
  const [country, setCountry] = useState(existing?.country ?? '');
  const [region, setRegion] = useState(existing?.region ?? '');
  const [city, setCity] = useState(existing?.city ?? '');
  const [saved, setSaved] = useState(false);

  const regionLabel = COUNTRIES.find((c) => c.code === country)?.regionLabel ?? 'State / region';

  const save = () => {
    const profile: UserProfile = { name: name.trim(), country, region: region.trim(), city: city.trim() };
    dispatch({ type: 'setProfile', profile });
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  };

  const inputStyle = [
    styles.input,
    { backgroundColor: colors.bg, borderColor: colors.line, color: colors.ink },
  ];

  return (
    <ScrollView
      style={[styles.screen, { backgroundColor: colors.bg }]}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={[styles.heading, { color: colors.ink }]}>Your profile</Text>
      <Text style={[styles.subheading, { color: colors.muted }]}>
        Where you live decides which offices, forms and deadlines apply. LifeOS uses this to link
        each task to the right authority for you.
      </Text>

      <Card>
        <Text style={[styles.label, { color: colors.muted }]}>Name</Text>
        <TextInput style={inputStyle} value={name} onChangeText={setName} placeholder="Your name"
          placeholderTextColor={colors.muted} />

        <Text style={[styles.label, { color: colors.muted }]}>Country</Text>
        <View style={styles.chipWrap}>
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
      </Card>

      <TouchableOpacity style={[styles.cta, { backgroundColor: colors.accent }]} onPress={save}>
        <Text style={[styles.ctaText, { color: colors.onAccent }]}>
          {saved ? 'Saved ✓' : 'Save profile'}
        </Text>
      </TouchableOpacity>
      <Text style={[styles.hint, { color: colors.muted }]}>
        Stored only on this device. Task resources update immediately.
      </Text>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '800', marginTop: spacing.md },
  subheading: { fontSize: 14, marginTop: spacing.xs, marginBottom: spacing.md },
  label: {
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.xs,
    marginTop: spacing.sm,
  },
  input: { borderWidth: 1, borderRadius: 12, padding: spacing.sm, fontSize: 15 },
  chipWrap: { flexDirection: 'row', flexWrap: 'wrap' },
  cta: { borderRadius: 24, padding: spacing.md, alignItems: 'center', marginTop: spacing.sm },
  ctaText: { fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, marginTop: spacing.sm, textAlign: 'center' },
});
