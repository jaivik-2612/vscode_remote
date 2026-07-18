import { RouteProp, useRoute } from '@react-navigation/native';
import React from 'react';
import { Linking, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { countryName, resolveResources } from '../core/resources';
import { TaskStatus } from '../core/types';
import { RootStackParamList } from '../navigation';
import { useStore } from '../state/store';
import { Card, Chip, PriorityBadge } from '../components/ui';
import { DOMAIN_LABELS } from '../core/types';
import { colors, spacing } from '../theme';

type Route = RouteProp<RootStackParamList, 'TaskDetail'>;

const STATUS_OPTIONS: { status: TaskStatus; label: string }[] = [
  { status: 'pending', label: 'To do' },
  { status: 'in_progress', label: 'In progress' },
  { status: 'done', label: 'Done' },
  { status: 'skipped', label: 'Not applicable' },
];

/** One obligation: what, who, by when, with which documents. */
export default function TaskDetailScreen() {
  const { params } = useRoute<Route>();
  const { state, dispatch } = useStore();
  const plan = state.plans.find((p) => p.id === params.planId);
  const task = plan?.tasks.find((t) => t.id === params.taskId);

  if (!plan || !task) {
    return (
      <View style={styles.screen}>
        <Text style={styles.title}>Task not found</Text>
      </View>
    );
  }

  const blockers = task.dependsOn
    .map((id) => plan.tasks.find((t) => t.id === id))
    .filter((t) => t && t.status !== 'done' && t.status !== 'skipped');

  const resources = resolveResources(task, state.profile);

  return (
    <ScrollView style={styles.screen}>
      <Text style={styles.title}>{task.title}</Text>
      <View style={styles.metaRow}>
        <Text style={styles.meta}>{DOMAIN_LABELS[task.domain]}</Text>
        <PriorityBadge priority={task.priority} />
      </View>

      <Card>
        <Text style={styles.description}>{task.description}</Text>
        {task.authority && <Text style={styles.authority}>Handled by: {task.authority}</Text>}
        <Text style={styles.dates}>
          Start {task.startDate} · Due {task.dueDate}
        </Text>
      </Card>

      <Card>
        <Text style={styles.sectionTitle}>ⓘ How & where to do this</Text>
        {resources.map((r) => (
          <TouchableOpacity
            key={r.url}
            style={styles.resourceRow}
            onPress={() => Linking.openURL(r.url).catch(() => {})}
          >
            <Text style={styles.resourceIcon}>{r.kind === 'search' ? '🔎' : '🔗'}</Text>
            <Text style={styles.resourceLabel} numberOfLines={2}>
              {r.label}
            </Text>
          </TouchableOpacity>
        ))}
        <Text style={styles.resourceHint}>
          {state.profile?.country
            ? `Localized for ${[state.profile.region, countryName(state.profile.country)]
                .filter(Boolean)
                .join(', ')} — change in Profile.`
            : 'Set your country in the Profile tab for official local links.'}
        </Text>
      </Card>

      {task.status === 'blocked' && blockers.length > 0 && (
        <Card>
          <Text style={styles.sectionTitle}>Waiting on</Text>
          {blockers.map((b) => (
            <Text key={b!.id} style={styles.blocker}>
              🔒 {b!.title}
            </Text>
          ))}
        </Card>
      )}

      <Card>
        <Text style={styles.sectionTitle}>Status</Text>
        <View style={styles.chipRow}>
          {STATUS_OPTIONS.map((opt) => (
            <Chip
              key={opt.status}
              label={opt.label}
              selected={task.status === opt.status}
              onPress={() =>
                dispatch({
                  type: 'setTaskStatus',
                  planId: plan.id,
                  taskId: task.id,
                  status: opt.status,
                })
              }
            />
          ))}
        </View>
        {task.status === 'blocked' && (
          <Text style={styles.hint}>
            This task is blocked until its prerequisites are done, but you can still set a status
            manually.
          </Text>
        )}
      </Card>

      {task.steps.length > 0 && (
        <Card>
          <Text style={styles.sectionTitle}>
            Steps ({task.steps.filter((s) => s.done).length}/{task.steps.length})
          </Text>
          {task.steps.map((step) => (
            <TouchableOpacity
              key={step.name}
              style={styles.docRow}
              onPress={() =>
                dispatch({
                  type: 'toggleStep',
                  planId: plan.id,
                  taskId: task.id,
                  stepName: step.name,
                })
              }
            >
              <Text style={styles.docCheck}>{step.done ? '☑' : '☐'}</Text>
              <Text style={[styles.docName, step.done && styles.docNameDone]}>{step.name}</Text>
            </TouchableOpacity>
          ))}
        </Card>
      )}

      {task.documents.length > 0 && (
        <Card>
          <Text style={styles.sectionTitle}>Documents needed</Text>
          {task.documents.map((doc) => (
            <TouchableOpacity
              key={doc.name}
              style={styles.docRow}
              onPress={() =>
                dispatch({
                  type: 'toggleDocument',
                  planId: plan.id,
                  taskId: task.id,
                  documentName: doc.name,
                })
              }
            >
              <Text style={styles.docCheck}>{doc.collected ? '☑' : '☐'}</Text>
              <Text style={[styles.docName, doc.collected && styles.docNameDone]}>{doc.name}</Text>
            </TouchableOpacity>
          ))}
        </Card>
      )}
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background, padding: spacing.md },
  title: { fontSize: 22, fontWeight: '700', color: colors.text, marginTop: spacing.sm },
  metaRow: { flexDirection: 'row', alignItems: 'center', marginVertical: spacing.sm },
  meta: { fontSize: 13, color: colors.textSecondary },
  description: { fontSize: 15, color: colors.text, lineHeight: 22 },
  authority: { fontSize: 13, color: colors.textSecondary, marginTop: spacing.sm },
  dates: { fontSize: 13, color: colors.textSecondary, marginTop: spacing.xs, fontWeight: '600' },
  sectionTitle: {
    fontSize: 13,
    fontWeight: '700',
    color: colors.textSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginBottom: spacing.sm,
  },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  blocker: { fontSize: 14, color: colors.text, paddingVertical: 4 },
  hint: { fontSize: 12, color: colors.textSecondary, marginTop: spacing.xs },
  resourceRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 7 },
  resourceIcon: { fontSize: 14, marginRight: spacing.sm },
  resourceLabel: { flex: 1, fontSize: 14, color: colors.accent, fontWeight: '600' },
  resourceHint: { fontSize: 11, color: colors.textSecondary, marginTop: spacing.xs },
  docRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 6 },
  docCheck: { fontSize: 18, marginRight: spacing.sm, color: colors.accent },
  docName: { fontSize: 15, color: colors.text },
  docNameDone: { color: colors.textSecondary, textDecorationLine: 'line-through' },
});
