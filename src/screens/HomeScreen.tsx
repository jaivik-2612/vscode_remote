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
import { EVENT_CATALOG } from '../core/templates';
import { planProgress } from '../core/progress';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { Card, Chip, ProgressBar } from '../components/ui';
import { colors, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;

/**
 * The front door: "Tell me what happened." Free-form input is matched against
 * the event catalog; suggestions and active plans live below it.
 */
export default function HomeScreen() {
  const navigation = useNavigation<Nav>();
  const { state } = useStore();
  const [input, setInput] = useState('');
  const today = todayIso();

  const matches = useMemo(() => matchIntent(input).slice(0, 3), [input]);

  return (
    <KeyboardAvoidingView
      style={{ flex: 1 }}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView style={styles.screen} keyboardShouldPersistTaps="handled">
        <Text style={styles.heading}>What happened?</Text>
        <Text style={styles.subheading}>
          Tell LifeOS about a life event and it maps out everything affected — every institution,
          deadline and document.
        </Text>

        <TextInput
          style={styles.input}
          placeholder='Try "I moved" or "I started a business"…'
          placeholderTextColor={colors.textSecondary}
          value={input}
          onChangeText={setInput}
          multiline
        />

        {matches.length > 0 && (
          <Card>
            <Text style={styles.sectionTitle}>Sounds like…</Text>
            {matches.map((m) => (
              <TouchableOpacity
                key={m.event.id}
                style={styles.matchRow}
                onPress={() => navigation.navigate('Intake', { eventId: m.event.id })}
              >
                <Text style={styles.matchEmoji}>{m.event.emoji}</Text>
                <View style={{ flex: 1 }}>
                  <Text style={styles.matchName}>{m.event.name}</Text>
                  <Text style={styles.matchDetail} numberOfLines={2}>
                    {m.event.summary}
                  </Text>
                </View>
              </TouchableOpacity>
            ))}
          </Card>
        )}

        <Text style={styles.sectionTitle}>Or pick an event</Text>
        <View style={styles.chipWrap}>
          {EVENT_CATALOG.map((e) => (
            <Chip
              key={e.id}
              label={`${e.emoji} ${e.name}`}
              onPress={() => navigation.navigate('Intake', { eventId: e.id })}
            />
          ))}
        </View>

        <Text style={styles.sectionTitle}>Active plans</Text>
        {state.plans.length === 0 && (
          <Text style={styles.empty}>No plans yet. Start by telling LifeOS what happened.</Text>
        )}
        {state.plans.map((plan) => {
          const progress = planProgress(plan, today);
          return (
            <TouchableOpacity
              key={plan.id}
              onPress={() => navigation.navigate('Plan', { planId: plan.id })}
            >
              <Card>
                <View style={styles.planHeader}>
                  <Text style={styles.planName}>
                    {plan.emoji} {plan.eventName}
                  </Text>
                  <Text style={styles.planMeta}>
                    {progress.done}/{progress.total}
                  </Text>
                </View>
                <ProgressBar fraction={progress.fraction} />
                {progress.overdue > 0 && (
                  <Text style={styles.overdue}>
                    {progress.overdue} task{progress.overdue > 1 ? 's' : ''} overdue
                  </Text>
                )}
              </Card>
            </TouchableOpacity>
          );
        })}
        <View style={{ height: spacing.xl }} />
      </ScrollView>
    </KeyboardAvoidingView>
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
  input: {
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 14,
    padding: spacing.md,
    fontSize: 16,
    color: colors.text,
    minHeight: 56,
    marginBottom: spacing.md,
  },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '700',
    color: colors.textSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.sm,
    marginTop: spacing.sm,
  },
  chipWrap: { flexDirection: 'row', flexWrap: 'wrap', marginBottom: spacing.sm },
  matchRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: spacing.sm },
  matchEmoji: { fontSize: 24, marginRight: spacing.sm },
  matchName: { fontSize: 16, fontWeight: '600', color: colors.text },
  matchDetail: { fontSize: 13, color: colors.textSecondary, marginTop: 2 },
  empty: { color: colors.textSecondary, fontSize: 14, marginBottom: spacing.md },
  planHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: spacing.sm,
  },
  planName: { fontSize: 16, fontWeight: '600', color: colors.text },
  planMeta: { fontSize: 13, color: colors.textSecondary },
  overdue: { color: colors.danger, fontSize: 12, marginTop: spacing.sm, fontWeight: '600' },
});
