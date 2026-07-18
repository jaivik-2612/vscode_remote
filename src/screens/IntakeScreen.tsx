import { RouteProp, useNavigation, useRoute } from '@react-navigation/native';
import { NativeStackNavigationProp } from '@react-navigation/native-stack';
import React, { useState } from 'react';
import {
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { shouldCelebrate } from '../core/celebration';
import { generatePlan } from '../core/planner';
import { getEventTemplate } from '../core/templates';
import { IntakeQuestion } from '../core/types';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, Chip } from '../components/ui';
import { spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;
type Route = RouteProp<RootStackParamList, 'Intake'>;

/** A few tailoring questions (max 5) before the plan is generated. */
export default function IntakeScreen() {
  const navigation = useNavigation<Nav>();
  const { params } = useRoute<Route>();
  const { dispatch } = useStore();
  const { colors } = useTheme();
  const template = getEventTemplate(params.eventId);
  const [answers, setAnswers] = useState<Record<string, string | boolean>>({});

  if (!template) {
    return (
      <View style={[styles.screen, { backgroundColor: colors.bg }]}>
        <Text style={[styles.title, { color: colors.ink }]}>Unknown event</Text>
      </View>
    );
  }

  const dateQuestion = template.questions.find((q) => q.kind === 'date');
  const eventDate =
    (dateQuestion && typeof answers[dateQuestion.id] === 'string'
      ? (answers[dateQuestion.id] as string)
      : '') || todayIso();

  const setAnswer = (id: string, value: string | boolean) =>
    setAnswers((prev) => ({ ...prev, [id]: value }));

  const createPlan = () => {
    const plan = generatePlan({ template, eventDate, answers });
    dispatch({ type: 'addPlan', plan });
    navigation.replace('Plan', { planId: plan.id, celebrate: shouldCelebrate(plan) });
  };

  const renderQuestion = (q: IntakeQuestion) => {
    switch (q.kind) {
      case 'boolean':
        return (
          <View style={styles.chipRow}>
            <Chip label="Yes" selected={answers[q.id] === true} onPress={() => setAnswer(q.id, true)} />
            <Chip label="No" selected={answers[q.id] === false} onPress={() => setAnswer(q.id, false)} />
          </View>
        );
      case 'choice':
        return (
          <View style={styles.chipRow}>
            {(q.choices ?? []).map((c) => (
              <Chip key={c} label={c} selected={answers[q.id] === c} onPress={() => setAnswer(q.id, c)} />
            ))}
          </View>
        );
      default:
        return (
          <TextInput
            style={[
              styles.input,
              { backgroundColor: colors.bg, borderColor: colors.line, color: colors.ink },
            ]}
            placeholder={q.kind === 'date' ? `YYYY-MM-DD (default: ${todayIso()})` : 'Type here…'}
            placeholderTextColor={colors.muted}
            value={typeof answers[q.id] === 'string' ? (answers[q.id] as string) : ''}
            onChangeText={(v) => setAnswer(q.id, v)}
            autoCapitalize={q.kind === 'date' ? 'none' : 'sentences'}
          />
        );
    }
  };

  return (
    <ScrollView
      style={[styles.screen, { backgroundColor: colors.bg }]}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={[styles.title, { color: colors.ink }]}>
        {template.emoji} {template.name}
      </Text>
      <Text style={[styles.summary, { color: colors.muted }]}>{template.summary}</Text>

      {template.questions.map((q) => (
        <Card key={q.id}>
          <Text style={[styles.prompt, { color: colors.ink }]}>{q.prompt}</Text>
          {renderQuestion(q)}
        </Card>
      ))}

      <TouchableOpacity
        style={[styles.cta, { backgroundColor: colors.accent }]}
        onPress={createPlan}
      >
        <Text style={[styles.ctaText, { color: colors.onAccent }]}>Build my plan</Text>
      </TouchableOpacity>
      <Text style={[styles.hint, { color: colors.muted }]}>
        Unanswered yes/no questions are treated as "No" — you can always regenerate the plan.
      </Text>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  title: { fontSize: 24, fontWeight: '800', marginTop: spacing.sm },
  summary: { fontSize: 15, marginVertical: spacing.md },
  prompt: { fontSize: 15, fontWeight: '600', marginBottom: spacing.sm },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  input: { borderWidth: 1, borderRadius: 12, padding: spacing.sm, fontSize: 15 },
  cta: { borderRadius: 24, padding: spacing.md, alignItems: 'center', marginTop: spacing.sm },
  ctaText: { fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, marginTop: spacing.sm, textAlign: 'center' },
});
