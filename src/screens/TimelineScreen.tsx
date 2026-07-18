import { useNavigation } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { buildTimeline } from '../core/progress';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, SectionTitle, TaskRow } from '../components/ui';
import { spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;

function urgencyLabel(days: number): string {
  if (days < 0) return `${-days}d overdue`;
  if (days === 0) return 'due today';
  return `in ${days}d`;
}

/** Every unresolved deadline across every plan, soonest first. */
export default function TimelineScreen() {
  const navigation = useNavigation<Nav>();
  const { state } = useStore();
  const { colors } = useTheme();
  const today = todayIso();
  const timeline = buildTimeline(state.plans, today);

  const overdue = timeline.filter((e) => e.daysUntilDue < 0);
  const upcoming = timeline.filter((e) => e.daysUntilDue >= 0);

  return (
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Text style={[styles.heading, { color: colors.ink }]}>Timeline</Text>
      <Text style={[styles.subheading, { color: colors.muted }]}>
        Every deadline from every plan, in one place.
      </Text>

      {timeline.length === 0 && (
        <Text style={[styles.empty, { color: colors.muted }]}>
          Nothing due — create a plan from the Home tab.
        </Text>
      )}

      {overdue.length > 0 && (
        <Card>
          <Text style={[styles.overdueTitle, { color: colors.danger }]}>OVERDUE</Text>
          {overdue.map((entry) => (
            <TaskRow
              key={`${entry.planId}:${entry.task.id}`}
              task={entry.task}
              subtitle={`${entry.emoji} ${entry.planName} · ${urgencyLabel(entry.daysUntilDue)}`}
              onPress={() =>
                navigation.navigate('TaskDetail', {
                  planId: entry.planId,
                  taskId: entry.task.id,
                })
              }
            />
          ))}
        </Card>
      )}

      {upcoming.length > 0 && (
        <Card>
          <SectionTitle>Upcoming</SectionTitle>
          {upcoming.map((entry) => (
            <TaskRow
              key={`${entry.planId}:${entry.task.id}`}
              task={entry.task}
              subtitle={`${entry.emoji} ${entry.planName} · ${urgencyLabel(entry.daysUntilDue)}`}
              onPress={() =>
                navigation.navigate('TaskDetail', {
                  planId: entry.planId,
                  taskId: entry.task.id,
                })
              }
            />
          ))}
        </Card>
      )}
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '800', marginTop: spacing.md },
  subheading: { fontSize: 14, marginTop: spacing.xs, marginBottom: spacing.md },
  overdueTitle: {
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.6,
    marginBottom: spacing.xs,
  },
  empty: { fontSize: 14 },
});
