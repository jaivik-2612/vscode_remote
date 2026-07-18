import React, { useState } from 'react';
import { ScrollView, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { COUNTRIES, UserProfile } from '../core/resources';
import { useStore } from '../state/store';
import { Card, Chip } from '../components/ui';
import { colors, spacing } from '../theme';

/**
 * The sign-up / profile form: basic details that let LifeOS localize task
 * guidance (and, later, tailor whole plans) to the user's country and region.
 */
export default function ProfileScreen() {
  const { state, dispatch } = useStore();
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

  return (
    <ScrollView style={styles.screen} keyboardShouldPersistTaps="handled">
      <Text style={styles.heading}>Your profile</Text>
      <Text style={styles.subheading}>
        Where you live decides which offices, forms and deadlines apply. LifeOS uses this to link
        each task to the right authority for you.
      </Text>

      <Card>
        <Text style={styles.label}>Name</Text>
        <TextInput style={styles.input} value={name} onChangeText={setName} placeholder="Your name"
          placeholderTextColor={colors.textSecondary} />

        <Text style={styles.label}>Country</Text>
        <View style={styles.chipWrap}>
          {COUNTRIES.map((c) => (
            <Chip key={c.code} label={c.name} selected={country === c.code} onPress={() => setCountry(c.code)} />
          ))}
        </View>

        <Text style={styles.label}>{regionLabel}</Text>
        <TextInput style={styles.input} value={region} onChangeText={setRegion}
          placeholder={`e.g. ${country === 'CA' ? 'Ontario' : country === 'GB' ? 'Greater London' : 'California'}`}
          placeholderTextColor={colors.textSecondary} />

        <Text style={styles.label}>City</Text>
        <TextInput style={styles.input} value={city} onChangeText={setCity} placeholder="City"
          placeholderTextColor={colors.textSecondary} />
      </Card>

      <TouchableOpacity style={styles.cta} onPress={save}>
        <Text style={styles.ctaText}>{saved ? 'Saved ✓' : 'Save profile'}</Text>
      </TouchableOpacity>
      <Text style={styles.hint}>
        Stored only on this device. Task resources update immediately.
      </Text>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '700', color: colors.text, marginTop: spacing.md },
  subheading: {
    fontSize: 15, color: colors.textSecondary, marginTop: spacing.xs, marginBottom: spacing.md,
  },
  label: { fontSize: 13, fontWeight: '700', color: colors.textSecondary, marginBottom: spacing.xs, marginTop: spacing.sm },
  input: {
    backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border,
    borderRadius: 10, padding: spacing.sm, fontSize: 15, color: colors.text,
  },
  chipWrap: { flexDirection: 'row', flexWrap: 'wrap' },
  cta: {
    backgroundColor: colors.accent, borderRadius: 14, padding: spacing.md,
    alignItems: 'center', marginTop: spacing.sm,
  },
  ctaText: { color: '#fff', fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, color: colors.textSecondary, marginTop: spacing.sm, textAlign: 'center' },
});
