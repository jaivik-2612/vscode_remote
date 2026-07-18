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
import { generatePlan } from '../core/planner';
import { getEventTemplate } from '../core/templates';
import { IntakeQuestion } from '../core/types';
import { RootStackParamList } from '../navigation';
import { todayIso, useStore } from '../state/store';
import { Card, Chip } from '../components/ui';
import { colors, spacing } from '../theme';

type Nav = NativeStackNavigationProp<RootStackParamList>;
type Route = RouteProp<RootStackParamList, 'Intake'>;

/**
 * A few tailoring questions before the plan is generated. Date questions
 * default to today; the first date answer becomes the plan's event date.
 */
export default function IntakeScreen() {
  const navigation = useNavigation<Nav>();
  const { params } = useRoute<Route>();
  const { dispatch } = useStore();
  const template = getEventTemplate(params.eventId);
  const [answers, setAnswers] = useState<Record<string, string | boolean>>({});

  if (!template) {
    return (
      <View style={styles.screen}>
        <Text style={styles.title}>Unknown event</Text>
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
    navigation.replace('Plan', { planId: plan.id });
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
      case 'date':
        return (
          <TextInput
            style={styles.input}
            placeholder={`YYYY-MM-DD (default: ${todayIso()})`}
            placeholderTextColor={colors.textSecondary}
            value={typeof answers[q.id] === 'string' ? (answers[q.id] as string) : ''}
            onChangeText={(v) => setAnswer(q.id, v)}
            autoCapitalize="none"
          />
        );
      default:
        return (
          <TextInput
            style={styles.input}
            placeholder="Type here…"
            placeholderTextColor={colors.textSecondary}
            value={typeof answers[q.id] === 'string' ? (answers[q.id] as string) : ''}
            onChangeText={(v) => setAnswer(q.id, v)}
          />
        );
    }
  };

  return (
    <ScrollView style={styles.screen} keyboardShouldPersistTaps="handled">
      <Text style={styles.title}>
        {template.emoji} {template.name}
      </Text>
      <Text style={styles.summary}>{template.summary}</Text>

      {template.questions.map((q) => (
        <Card key={q.id}>
          <Text style={styles.prompt}>{q.prompt}</Text>
          {renderQuestion(q)}
        </Card>
      ))}

      <TouchableOpacity style={styles.cta} onPress={createPlan}>
        <Text style={styles.ctaText}>Build my plan</Text>
      </TouchableOpacity>
      <Text style={styles.hint}>
        Unanswered yes/no questions are treated as "No" — you can always regenerate the plan.
      </Text>
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background, padding: spacing.md },
  title: { fontSize: 24, fontWeight: '700', color: colors.text, marginTop: spacing.sm },
  summary: { fontSize: 15, color: colors.textSecondary, marginVertical: spacing.md },
  prompt: { fontSize: 15, fontWeight: '600', color: colors.text, marginBottom: spacing.sm },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  input: {
    backgroundColor: colors.background,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    padding: spacing.sm,
    fontSize: 15,
    color: colors.text,
  },
  cta: {
    backgroundColor: colors.accent,
    borderRadius: 14,
    padding: spacing.md,
    alignItems: 'center',
    marginTop: spacing.sm,
  },
  ctaText: { color: '#fff', fontSize: 16, fontWeight: '700' },
  hint: { fontSize: 12, color: colors.textSecondary, marginTop: spacing.sm, textAlign: 'center' },
});
