import { RouteProp, useNavigation, useRoute } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React from 'react';
import {
  Alert,
  Linking,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { groupByDomain, planProgress } from '../core/progress';
import { AFFILIATE_DISCLOSURE, amazonUrl, productsForPlan } from '../core/products';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, ProgressBar, SectionTitle, TaskRow } from '../components/ui';
import { cardShadow, domainColors, radius, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;
type Route = RouteProp<RootStackParamList, 'Plan'>;

/** One life event's full plan, grouped by administrative domain. */
export default function PlanScreen() {
  const navigation = useNavigation<Nav>();
  const { params } = useRoute<Route>();
  const { state, dispatch } = useStore();
  const { colors } = useTheme();
  const plan = state.plans.find((p) => p.id === params.planId);
  const today = todayIso();

  if (!plan) {
    return (
      <View style={[styles.screen, { backgroundColor: colors.bg }]}>
        <Text style={[styles.planTitle, { color: colors.ink }]}>Plan not found</Text>
      </View>
    );
  }

  const progress = planProgress(plan, today);
  const groups = groupByDomain(plan);
  const products = productsForPlan(plan.eventId);

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
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Text style={[styles.planTitle, { color: colors.ink }]}>
        {plan.emoji} {plan.eventName}
      </Text>
      {plan.milestone && (
        <Text style={[styles.milestoneBadge, { color: colors.gold }]}>⭐ Milestone</Text>
      )}
      <Text style={[styles.planMeta, { color: colors.muted }]}>
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
            <Text style={[styles.groupLabel, { color: colors.ink }]}>{group.label}</Text>
            <Text style={[styles.groupCount, { color: colors.muted }]}>
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

      {products.length > 0 && (
        <>
          <SectionTitle>🛍️ Things you might need</SectionTitle>
          <ScrollView horizontal showsHorizontalScrollIndicator={false}>
            {products.map((p) => (
              <TouchableOpacity
                key={p.label}
                style={[styles.productCard, cardShadow, { backgroundColor: colors.card }]}
                onPress={() => Linking.openURL(amazonUrl(p.query, state.profile)).catch(() => {})}
              >
                <Text style={{ fontSize: 19 }}>🛍️</Text>
                <Text style={[styles.productLabel, { color: colors.ink }]} numberOfLines={2}>
                  {p.label}
                </Text>
                <Text style={[styles.productMeta, { color: colors.muted }]}>Amazon ↗</Text>
              </TouchableOpacity>
            ))}
          </ScrollView>
          <Text style={[styles.disclosure, { color: colors.muted }]}>{AFFILIATE_DISCLOSURE}</Text>
        </>
      )}

      <TouchableOpacity onPress={confirmDelete} style={styles.deleteButton}>
        <Text style={[styles.deleteText, { color: colors.danger }]}>Delete this plan</Text>
      </TouchableOpacity>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  planTitle: { fontSize: 24, fontWeight: '800', marginTop: spacing.sm },
  milestoneBadge: { fontSize: 12, fontWeight: '700', marginTop: spacing.xs },
  planMeta: { fontSize: 13, marginTop: spacing.xs },
  groupHeader: { flexDirection: 'row', alignItems: 'center', marginBottom: spacing.xs },
  groupDot: { width: 12, height: 12, borderRadius: 6, marginRight: spacing.sm },
  groupLabel: { flex: 1, fontSize: 16, fontWeight: '700' },
  groupCount: { fontSize: 13 },
  productCard: {
    width: 118,
    borderRadius: radius.card,
    padding: spacing.md,
    marginRight: spacing.sm,
    marginBottom: spacing.sm,
    gap: 5,
  },
  productLabel: { fontSize: 12, fontWeight: '600', lineHeight: 15 },
  productMeta: { fontSize: 10 },
  disclosure: { fontSize: 10, marginTop: 2, marginBottom: spacing.sm },
  deleteButton: { alignItems: 'center', padding: spacing.md },
  deleteText: { fontWeight: '600' },
});
