import { useNavigation } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { buildTimeline, planProgress } from '../core/progress';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, ProgressBar, SectionTitle, TaskRow } from '../components/ui';
import { cardShadow, radius, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;

/** My Dashboard: the user's life admin at a glance — stats, plans, ongoing tasks. */
export default function DashboardScreen() {
  const navigation = useNavigation<Nav>();
  const { state } = useStore();
  const { colors } = useTheme();
  const today = todayIso();

  const timeline = buildTimeline(state.plans, today);
  let done = 0;
  let total = 0;
  const inProgress: { planId: string; planName: string; emoji: string; task: (typeof timeline)[number]['task'] }[] = [];
  for (const plan of state.plans) {
    for (const task of plan.tasks) {
      total++;
      if (task.status === 'done' || task.status === 'skipped') done++;
      if (task.status === 'in_progress') {
        inProgress.push({ planId: plan.id, planName: plan.eventName, emoji: plan.emoji, task });
      }
    }
  }
  const due7 = timeline.filter((e) => e.daysUntilDue >= 0 && e.daysUntilDue <= 7).length;
  const overdue = timeline.filter((e) => e.daysUntilDue < 0).length;

  const statTile = (value: string | number, label: string, bad = false) => (
    <View style={[styles.statTile, cardShadow, { backgroundColor: colors.card }]}>
      <Text style={[styles.statValue, { color: bad && Number(value) > 0 ? colors.danger : colors.accent }]}>
        {value}
      </Text>
      <Text style={[styles.statLabel, { color: colors.muted }]}>{label}</Text>
    </View>
  );

  return (
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Text style={[styles.heading, { color: colors.ink }]}>My dashboard</Text>
      <Text style={[styles.subheading, { color: colors.muted }]}>
        Your life admin at a glance.
      </Text>

      {state.plans.length === 0 ? (
        <Text style={[styles.empty, { color: colors.muted }]}>
          No plans yet — add an event from the Home tab and your progress will show up here.
        </Text>
      ) : (
        <>
          <View style={styles.statGrid}>
            {statTile(state.plans.length, 'Active plans')}
            {statTile(`${done}/${total}`, 'Tasks done')}
            {statTile(due7, 'Due in 7 days')}
            {statTile(overdue, 'Overdue', true)}
          </View>

          <Card>
            <SectionTitle>Plans</SectionTitle>
            {state.plans.map((plan) => {
              const progress = planProgress(plan, today);
              return (
                <TouchableOpacity
                  key={plan.id}
                  style={[styles.planRow, { borderBottomColor: colors.line }]}
                  onPress={() => navigation.navigate('Plan', { planId: plan.id })}
                >
                  <Text style={[styles.planName, { color: colors.ink }]} numberOfLines={1}>
                    {plan.emoji} {plan.eventName}
                    {plan.milestone ? ' ⭐' : ''}
                  </Text>
                  <View style={styles.planBar}>
                    <ProgressBar fraction={progress.fraction} />
                  </View>
                  <Text style={[styles.planCount, { color: colors.muted }]}>
                    {progress.done}/{progress.total}
                  </Text>
                </TouchableOpacity>
              );
            })}
          </Card>

          <Card>
            <SectionTitle>Ongoing tasks</SectionTitle>
            {inProgress.length > 0 ? (
              inProgress.map((entry) => (
                <TaskRow
                  key={`${entry.planId}:${entry.task.id}`}
                  task={entry.task}
                  subtitle={`${entry.emoji} ${entry.planName} · due ${entry.task.dueDate}`}
                  onPress={() =>
                    navigation.navigate('TaskDetail', { planId: entry.planId, taskId: entry.task.id })
                  }
                />
              ))
            ) : (
              <>
                <Text style={[styles.empty, { color: colors.muted, marginBottom: 6 }]}>
                  Nothing marked in progress — here’s what’s next:
                </Text>
                {timeline.slice(0, 3).map((entry) => (
                  <TaskRow
                    key={`${entry.planId}:${entry.task.id}`}
                    task={entry.task}
                    subtitle={`${entry.emoji} ${entry.planName} · due ${entry.task.dueDate}`}
                    onPress={() =>
                      navigation.navigate('TaskDetail', {
                        planId: entry.planId,
                        taskId: entry.task.id,
                      })
                    }
                  />
                ))}
              </>
            )}
          </Card>
        </>
      )}
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  heading: { fontSize: 28, fontWeight: '800', marginTop: spacing.md },
  subheading: { fontSize: 14, marginTop: spacing.xs, marginBottom: spacing.md },
  empty: { fontSize: 14 },
  statGrid: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between' },
  statTile: {
    width: '48.5%',
    borderRadius: radius.card,
    padding: spacing.md,
    marginBottom: spacing.md,
  },
  statValue: { fontSize: 24, fontWeight: '800', fontVariant: ['tabular-nums'] },
  statLabel: {
    fontSize: 10,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginTop: 2,
  },
  planRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  planName: { flex: 1, fontSize: 13, fontWeight: '600' },
  planBar: { width: 64 },
  planCount: { fontSize: 11, fontVariant: ['tabular-nums'] },
});
