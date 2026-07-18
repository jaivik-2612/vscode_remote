import { useNavigation } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { buildTimeline } from '../core/progress';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { Card, TaskRow } from '../components/ui';
import { colors, spacing } from '../theme';

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
  const today = todayIso();
  const timeline = buildTimeline(state.plans, today);

  const overdue = timeline.filter((e) => e.daysUntilDue < 0);
  const upcoming = timeline.filter((e) => e.daysUntilDue >= 0);

  return (
    <ScrollView style={styles.screen}>
      <Text style={styles.heading}>Timeline</Text>
      <Text style={styles.subheading}>
        Every deadline from every plan, in one place.
      </Text>

      {timeline.length === 0 && (
        <Text style={styles.empty}>Nothing due — create a plan from the Home tab.</Text>
      )}

      {overdue.length > 0 && (
        <Card style={{ borderColor: colors.danger }}>
          <Text style={[styles.sectionTitle, { color: colors.danger }]}>Overdue</Text>
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
          <Text style={styles.sectionTitle}>Upcoming</Text>
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
  screen: { flex: 1, backgroundColor: colors.background, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '700', color: colors.text, marginTop: spacing.md },
  subheading: {
    fontSize: 15,
    color: colors.textSecondary,
    marginTop: spacing.xs,
    marginBottom: spacing.md,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '700',
    color: colors.textSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.xs,
  },
  empty: { color: colors.textSecondary, fontSize: 14 },
});
