import React from 'react';
import { Alert, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { EVENT_CATALOG } from '../core/templates';
import { useStore } from '../state/store';
import { ThemeSetting, useTheme } from '../state/theme';
import { Card, Chip, SectionTitle } from '../components/ui';
import { spacing } from '../theme';

const THEME_OPTIONS: { value: ThemeSetting; label: string }[] = [
  { value: 'light', label: '☀️ Light' },
  { value: 'dark', label: '🌙 Dark' },
  { value: 'system', label: '⚙️ System' },
];

/** App settings: appearance, data, and about. */
export default function SettingsScreen() {
  const { state, dispatch } = useStore();
  const { colors, setting, setSetting } = useTheme();

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
  label: { fontSize: 15, fontWeight: '600', marginBottom: spacing.sm },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  dangerText: { fontSize: 15, fontWeight: '600', paddingVertical: 4 },
  hint: { fontSize: 12, marginTop: 2 },
  about: { fontSize: 13, lineHeight: 22 },
});
