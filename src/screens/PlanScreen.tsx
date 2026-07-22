import { RouteProp, useNavigation, useRoute } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React, { useState } from 'react';
import {
  Alert,
  Linking,
  Modal,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { celebrationMessage } from '../core/celebration';
import { groupByDomain, planProgress } from '../core/progress';
import { AFFILIATE_DISCLOSURE, productUrl, productsForPlan } from '../core/products';
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
  const [celebrating, setCelebrating] = useState(params.celebrate === true);

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

  const firstName =
    state.profile?.firstName?.trim() ||
    (state.profile?.name ? state.profile.name.trim().split(' ')[0] : '');

  return (
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Modal
        visible={celebrating}
        transparent
        animationType="fade"
        onRequestClose={() => setCelebrating(false)}
      >
        <View style={styles.celebrateOverlay}>
          <View style={[styles.celebrateCard, { backgroundColor: colors.card }]}>
            <Text style={styles.celebrateConfetti}>🎊 ✨ 🎉 ✨ 🎊</Text>
            <Text style={styles.celebrateEmoji}>{plan.emoji}</Text>
            <Text style={[styles.celebrateTitle, { color: colors.ink }]}>
              Congratulations{firstName ? `, ${firstName}` : ''}!
            </Text>
            <Text style={[styles.celebrateMsg, { color: colors.ink }]}>
              {celebrationMessage(plan.eventId)}
            </Text>
            <Text style={[styles.celebrateSub, { color: colors.muted }]}>
              Your plan is ready — LifeOS handles the paperwork while you enjoy the moment.
            </Text>
            <TouchableOpacity
              style={[styles.celebrateCta, { backgroundColor: colors.accent }]}
              onPress={() => setCelebrating(false)}
            >
              <Text style={[styles.celebrateCtaText, { color: colors.onAccent }]}>
                See my plan 🎉
              </Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

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
                onPress={() => Linking.openURL(productUrl(p, state.profile)).catch(() => {})}
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
  celebrateOverlay: {
    flex: 1,
    backgroundColor: 'rgba(10, 15, 30, 0.5)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.lg,
  },
  celebrateCard: {
    width: '100%',
    borderRadius: 24,
    padding: spacing.lg,
    alignItems: 'center',
  },
  celebrateConfetti: { fontSize: 16, marginBottom: spacing.sm },
  celebrateEmoji: { fontSize: 46 },
  celebrateTitle: { fontSize: 22, fontWeight: '800', marginTop: spacing.sm },
  celebrateMsg: { fontSize: 14, fontWeight: '600', textAlign: 'center', marginTop: 6, lineHeight: 20 },
  celebrateSub: { fontSize: 12, textAlign: 'center', marginTop: 6, lineHeight: 17 },
  celebrateCta: {
    borderRadius: 24,
    paddingVertical: 14,
    paddingHorizontal: 28,
    marginTop: spacing.md,
  },
  celebrateCtaText: { fontSize: 15, fontWeight: '700' },
});
