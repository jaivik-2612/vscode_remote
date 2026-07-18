import { RouteProp, useNavigation, useRoute } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React from 'react';
import { Alert, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { groupByDomain, planProgress } from '../core/progress';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { Card, ProgressBar, TaskRow } from '../components/ui';
import { colors, domainColors, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;
type Route = RouteProp<RootStackParamList, 'Plan'>;

/** One life event's full plan, grouped by administrative domain. */
export default function PlanScreen() {
  const navigation = useNavigation<Nav>();
  const { params } = useRoute<Route>();
  const { state, dispatch } = useStore();
  const plan = state.plans.find((p) => p.id === params.planId);
  const today = todayIso();

  if (!plan) {
    return (
      <View style={styles.screen}>
        <Text style={styles.planTitle}>Plan not found</Text>
      </View>
    );
  }

  const progress = planProgress(plan, today);
  const groups = groupByDomain(plan);

  const confirmDelete = () =>
    Alert.alert('Delete plan', `Remove "${plan.eventName}" and all its tasks?`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          dispatch({ type: 'removePlan', planId: plan.id });
          navigation.goBack();
        },
      },
    ]);

  return (
    <ScrollView style={styles.screen}>
      <Text style={styles.planTitle}>
        {plan.emoji} {plan.eventName}
      </Text>
      {plan.milestone && <Text style={styles.milestoneBadge}>⭐ Milestone</Text>}
      <Text style={styles.planMeta}>
        Event date {plan.eventDate} · {progress.done}/{progress.total} done
        {progress.overdue > 0 ? ` · ${progress.overdue} overdue` : ''}
      </Text>
      <View style={{ marginVertical: spacing.md }}>
        <ProgressBar fraction={progress.fraction} />
      </View>

      {groups.map((group) => (
        <Card key={group.domain}>
          <View style={styles.groupHeader}>
            <View style={[styles.groupDot, { backgroundColor: domainColors[group.domain] }]} />
            <Text style={styles.groupLabel}>{group.label}</Text>
            <Text style={styles.groupCount}>
              {group.tasks.filter((t) => t.status === 'done' || t.status === 'skipped').length}/
              {group.tasks.length}
            </Text>
          </View>
          {group.tasks.map((task) => (
            <TaskRow
              key={task.id}
              task={task}
              onPress={() =>
                navigation.navigate('TaskDetail', { planId: plan.id, taskId: task.id })
              }
            />
          ))}
        </Card>
      ))}

      <TouchableOpacity onPress={confirmDelete} style={styles.deleteButton}>
        <Text style={styles.deleteText}>Delete this plan</Text>
      </TouchableOpacity>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background, padding: spacing.md },
  planTitle: { fontSize: 24, fontWeight: '700', color: colors.text, marginTop: spacing.sm },
  planMeta: { fontSize: 13, color: colors.textSecondary, marginTop: spacing.xs },
  milestoneBadge: { fontSize: 12, fontWeight: '700', color: '#B8860B', marginTop: spacing.xs },
  groupHeader: { flexDirection: 'row', alignItems: 'center', marginBottom: spacing.xs },
  groupDot: { width: 12, height: 12, borderRadius: 6, marginRight: spacing.sm },
  groupLabel: { flex: 1, fontSize: 16, fontWeight: '700', color: colors.text },
  groupCount: { fontSize: 13, color: colors.textSecondary },
  deleteButton: { alignItems: 'center', padding: spacing.md },
  deleteText: { color: colors.danger, fontWeight: '600' },
});
