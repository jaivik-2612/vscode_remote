import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { useNavigation } from '@react-navigation/native';
import React, { useMemo, useState } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { matchIntent } from '../core/intent';
import { EVENT_CATALOG, featuredByCategory } from '../core/templates';
import { planProgress } from '../core/progress';
import { CATEGORY_LABELS } from '../core/types';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { LogoLockup } from '../components/Logo';
import { Card, SectionTitle } from '../components/ui';
import { cardShadow, radius, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;

/** The three most common events per category — the home Quick Add card. */
const QUICK_ADD: {
  label: string;
  category: string;
  items: { id: string; emoji: string; label: string }[];
}[] = [
  {
    label: 'Milestones',
    category: 'milestone',
    items: [
      { id: 'got-married', emoji: '💍', label: 'Married' },
      { id: 'new-child', emoji: '👶', label: 'Baby' },
      { id: 'bought-house', emoji: '🏠', label: 'House' },
    ],
  },
  {
    label: 'Important',
    category: 'important',
    items: [
      { id: 'moved', emoji: '📦', label: 'Moved' },
      { id: 'new-job', emoji: '💼', label: 'New job' },
      { id: 'bought-car', emoji: '🚗', label: 'Car' },
    ],
  },
  {
    label: 'Leisure',
    category: 'leisure',
    items: [
      { id: 'trip-abroad', emoji: '✈️', label: 'Trip' },
      { id: 'new-pet', emoji: '🐶', label: 'Pet' },
      { id: 'kids-birthday-party', emoji: '🎈', label: 'Party' },
    ],
  },
];

/** The Sky home: greeting, pill input, plan cards with progress, event tiles. */
export default function HomeScreen() {
  const navigation = useNavigation<Nav>();
  const { state } = useStore();
  const { colors } = useTheme();
  const [input, setInput] = useState('');
  const today = todayIso();

  const matches = useMemo(() => matchIntent(input).slice(0, 6), [input]);

  const hour = new Date().getHours();
  const daypart = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const firstName =
    state.profile?.firstName?.trim() ||
    (state.profile?.name ? state.profile.name.trim().split(' ')[0] : '');

  const goToBest = () => {
    const top = matches[0];
    if (top) navigation.navigate('Intake', { eventId: top.event.id });
  };

  const longTail =
    EVENT_CATALOG.length - featuredByCategory().reduce((n, g) => n + g.events.length, 0);

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView
        style={[styles.screen, { backgroundColor: colors.bg }]}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.brandRow}>
          <LogoLockup markSize={26} fontSize={19} />
        </View>
        <Text style={[styles.hello, { color: colors.ink }]}>
          {daypart}
          {firstName ? `,\n${firstName}` : ''}.
        </Text>
        <Text style={[styles.tag, { color: colors.muted }]}>
          What’s happening in your life? LifeOS handles the paperwork.
        </Text>

        {!state.profile?.country && (
          <TouchableOpacity
            style={[styles.nudge, { backgroundColor: colors.soft }]}
            onPress={() => (navigation as any).navigate('Settings')}
          >
            <Text style={[styles.nudgeText, { color: colors.accent }]}>
              👤 Set up your profile — country-specific links and guidance on every task →
            </Text>
          </TouchableOpacity>
        )}

        <View style={styles.inputRow}>
          <TextInput
            style={[
              styles.input,
              cardShadow,
              { backgroundColor: colors.card, color: colors.ink },
            ]}
            placeholder='Try "I moved" or "I started a business"…'
            placeholderTextColor={colors.muted}
            value={input}
            onChangeText={setInput}
            multiline
            blurOnSubmit
            returnKeyType="go"
            onSubmitEditing={goToBest}
          />
          <TouchableOpacity
            style={[
              styles.goButton,
              { backgroundColor: colors.accent },
              matches.length === 0 && { opacity: 0.4 },
            ]}
            disabled={matches.length === 0}
            onPress={goToBest}
            accessibilityLabel="Go"
          >
            <Text style={[styles.goText, { color: colors.onAccent }]}>→</Text>
          </TouchableOpacity>
        </View>

        {matches.length > 0 && (
          <Card style={{ paddingVertical: 4 }}>
            {matches.map((m) => (
              <TouchableOpacity
                key={m.event.id}
                style={[styles.matchRow, { borderBottomColor: colors.line }]}
                onPress={() => navigation.navigate('Intake', { eventId: m.event.id })}
              >
                <Text style={styles.matchEmoji}>{m.event.emoji}</Text>
                <Text style={[styles.matchName, { color: colors.ink }]} numberOfLines={1}>
                  {m.event.name}
                </Text>
                <Text style={[styles.matchCategory, { color: categoryColor(m.event.category, colors) }]}>
                  {CATEGORY_LABELS[m.event.category].split(' ')[0]}
                </Text>
              </TouchableOpacity>
            ))}
          </Card>
        )}

        {state.plans.length > 0 && (
          <>
            <SectionTitle>Active plans</SectionTitle>
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.planScroll}>
              {state.plans.map((plan) => {
                const progress = planProgress(plan, today);
                const pct = Math.round(progress.fraction * 100);
                return (
                  <TouchableOpacity
                    key={plan.id}
                    style={[styles.planCard, cardShadow, { backgroundColor: colors.card }]}
                    onPress={() => navigation.navigate('Plan', { planId: plan.id })}
                  >
                    <View style={[styles.pctCircle, { backgroundColor: colors.soft }]}>
                      <Text style={[styles.pctText, { color: colors.accent }]}>{pct}%</Text>
                    </View>
                    <Text style={[styles.planName, { color: colors.ink }]} numberOfLines={2}>
                      {plan.emoji} {plan.eventName}
                      {plan.milestone ? ' ⭐' : ''}
                    </Text>
                    <Text
                      style={[
                        styles.planMeta,
                        { color: progress.overdue ? colors.danger : colors.muted },
                      ]}
                    >
                      {progress.overdue
                        ? `${progress.overdue} overdue`
                        : `${progress.done}/${progress.total} done`}
                    </Text>
                  </TouchableOpacity>
                );
              })}
            </ScrollView>
          </>
        )}

        <SectionTitle>Quick add</SectionTitle>
        <Card>
          <View style={styles.quickCols}>
            {QUICK_ADD.map((col) => (
              <View key={col.label} style={styles.quickCol}>
                <Text style={[styles.quickHead, { color: categoryColor(col.category, colors) }]}>
                  {col.label}
                </Text>
                {col.items.map((item) => (
                  <TouchableOpacity
                    key={item.id}
                    style={[styles.quickBtn, { backgroundColor: colors.bg }]}
                    onPress={() => navigation.navigate('Intake', { eventId: item.id })}
                  >
                    <Text style={{ fontSize: 15 }}>{item.emoji}</Text>
                    <Text style={[styles.quickLabel, { color: colors.ink }]} numberOfLines={1}>
                      {item.label}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
            ))}
          </View>
          <Text style={[styles.catalogHint, { color: colors.muted }]}>
            …and {longTail}+ more events — just describe what happened above.
          </Text>
        </Card>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function categoryColor(category: string, colors: { gold: string; accent: string; success: string }) {
  if (category === 'milestone') return colors.gold;
  if (category === 'leisure') return colors.success;
  return colors.accent;
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  brandRow: { marginTop: spacing.sm },
  hello: { fontSize: 30, fontWeight: '800', marginTop: spacing.lg, lineHeight: 36 },
  tag: { fontSize: 14, marginTop: 6, marginBottom: spacing.lg },
  nudge: { borderRadius: radius.small, padding: spacing.sm, marginBottom: spacing.md },
  nudgeText: { fontSize: 13, fontWeight: '600' },
  inputRow: { flexDirection: 'row', alignItems: 'center', marginBottom: spacing.md },
  input: {
    flex: 1,
    borderRadius: 28,
    paddingHorizontal: 20,
    paddingVertical: 16,
    fontSize: 15,
    minHeight: 56,
  },
  goButton: {
    width: 54,
    height: 54,
    borderRadius: 27,
    justifyContent: 'center',
    alignItems: 'center',
    marginLeft: spacing.sm,
  },
  goText: { fontSize: 24, fontWeight: '700' },
  matchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  matchEmoji: { fontSize: 18, marginRight: spacing.sm },
  matchName: { flex: 1, fontSize: 14, fontWeight: '600' },
  matchCategory: { fontSize: 9, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.5 },
  planScroll: { marginBottom: spacing.sm },
  planCard: {
    width: 150,
    borderRadius: radius.card,
    padding: spacing.md,
    marginRight: spacing.md,
    marginBottom: spacing.sm,
  },
  pctCircle: {
    width: 52,
    height: 52,
    borderRadius: 26,
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: spacing.sm,
  },
  pctText: { fontSize: 12, fontWeight: '800' },
  planName: { fontSize: 13, fontWeight: '700', lineHeight: 17 },
  planMeta: { fontSize: 11, fontWeight: '600', marginTop: 4 },
  quickCols: { flexDirection: 'row', gap: 10 },
  quickCol: { flex: 1, minWidth: 0 },
  quickHead: {
    fontSize: 10,
    fontWeight: '800',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginBottom: 8,
  },
  quickBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    borderRadius: 12,
    paddingVertical: 8,
    paddingHorizontal: 8,
    marginBottom: 6,
  },
  quickLabel: { flex: 1, fontSize: 12, fontWeight: '600' },
  catalogHint: { fontSize: 10, marginTop: spacing.xs },
});
