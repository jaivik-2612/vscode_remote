import { RouteProp, useRoute } from '@react-navigation/native';
import React from 'react';
import { Linking, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { AFFILIATE_DISCLOSURE, productUrl, productsForTask } from '../core/products';
import { countryName, resolveResources } from '../core/resources';
import { DOMAIN_LABELS, TaskStatus } from '../core/types';
import { RootStackParamList } from '../navigation';
import { useStore } from '../state/store';
import { useTheme } from '../state/theme';
import { Card, Chip, PriorityBadge, SectionTitle } from '../components/ui';
import { spacing } from '../theme';

type Route = RouteProp<RootStackParamList, 'TaskDetail'>;

const STATUS_OPTIONS: { status: TaskStatus; label: string }[] = [
  { status: 'pending', label: 'To do' },
  { status: 'in_progress', label: 'In progress' },
  { status: 'done', label: 'Done' },
  { status: 'skipped', label: 'Not applicable' },
];

/** One obligation: what, who, by when, with which steps, documents and help. */
export default function TaskDetailScreen() {
  const { params } = useRoute<Route>();
  const { state, dispatch } = useStore();
  const { colors } = useTheme();
  const plan = state.plans.find((p) => p.id === params.planId);
  const task = plan?.tasks.find((t) => t.id === params.taskId);

  if (!plan || !task) {
    return (
      <View style={[styles.screen, { backgroundColor: colors.bg }]}>
        <Text style={[styles.title, { color: colors.ink }]}>Task not found</Text>
      </View>
    );
  }

  const blockers = task.dependsOn
    .map((id) => plan.tasks.find((t) => t.id === id))
    .filter((t) => t && t.status !== 'done' && t.status !== 'skipped');

  const resources = resolveResources(task, state.profile);
  const products = productsForTask(plan.eventId, task.templateId);

  return (
    <ScrollView style={[styles.screen, { backgroundColor: colors.bg }]}>
      <Text style={[styles.title, { color: colors.ink }]}>{task.title}</Text>
      <View style={styles.metaRow}>
        <Text style={[styles.meta, { color: colors.muted }]}>{DOMAIN_LABELS[task.domain]}</Text>
        <PriorityBadge priority={task.priority} />
      </View>

      <Card>
        <Text style={[styles.description, { color: colors.ink }]}>{task.description}</Text>
        {task.authority && (
          <Text style={[styles.authority, { color: colors.muted }]}>
            Handled by: {task.authority}
          </Text>
        )}
        <Text style={[styles.dates, { color: colors.muted }]}>
          Start {task.startDate} · Due {task.dueDate}
        </Text>
      </Card>

      <Card>
        <SectionTitle>ⓘ How & where to do this</SectionTitle>
        {resources.map((r) => (
          <TouchableOpacity
            key={r.url}
            style={styles.resourceRow}
            onPress={() => Linking.openURL(r.url).catch(() => {})}
          >
            <Text style={styles.resourceIcon}>{r.kind === 'search' ? '🔎' : '🔗'}</Text>
            <Text style={[styles.resourceLabel, { color: colors.accent }]} numberOfLines={2}>
              {r.label}
            </Text>
          </TouchableOpacity>
        ))}
        <Text style={[styles.hint, { color: colors.muted }]}>
          {state.profile?.country
            ? `Localized for ${[state.profile.region, countryName(state.profile.country)]
                .filter(Boolean)
                .join(', ')} — change in Profile.`
            : 'Set your country in the Profile tab for official local links.'}
        </Text>
      </Card>

      {products.length > 0 && (
        <Card>
          <SectionTitle>🛍️ Helpful products</SectionTitle>
          {products.map((p) => (
            <TouchableOpacity
              key={p.label}
              style={styles.resourceRow}
              onPress={() => Linking.openURL(productUrl(p, state.profile)).catch(() => {})}
            >
              <Text style={styles.resourceIcon}>🛍️</Text>
              <Text style={[styles.resourceLabel, { color: colors.accent }]}>{p.label}</Text>
            </TouchableOpacity>
          ))}
          <Text style={[styles.hint, { color: colors.muted }]}>{AFFILIATE_DISCLOSURE}</Text>
        </Card>
      )}

      {task.status === 'blocked' && blockers.length > 0 && (
        <Card>
          <SectionTitle>Waiting on</SectionTitle>
          {blockers.map((b) => (
            <Text key={b!.id} style={[styles.blocker, { color: colors.ink }]}>
              🔒 {b!.title}
            </Text>
          ))}
        </Card>
      )}

      <Card>
        <SectionTitle>Status</SectionTitle>
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
          <Text style={[styles.hint, { color: colors.muted }]}>
            This task is blocked until its prerequisites are done, but you can still set a status
            manually.
          </Text>
        )}
      </Card>

      {task.steps.length > 0 && (
        <Card>
          <SectionTitle>
            Steps ({task.steps.filter((s) => s.done).length}/{task.steps.length})
          </SectionTitle>
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
              <Text style={[styles.docCheck, { color: colors.accent }]}>
                {step.done ? '☑' : '☐'}
              </Text>
              <Text
                style={[
                  styles.docName,
                  { color: step.done ? colors.muted : colors.ink },
                  step.done && styles.docNameDone,
                ]}
              >
                {step.name}
              </Text>
            </TouchableOpacity>
          ))}
        </Card>
      )}

      {task.documents.length > 0 && (
        <Card>
          <SectionTitle>Documents needed</SectionTitle>
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
              <Text style={[styles.docCheck, { color: colors.accent }]}>
                {doc.collected ? '☑' : '☐'}
              </Text>
              <Text
                style={[
                  styles.docName,
                  { color: doc.collected ? colors.muted : colors.ink },
                  doc.collected && styles.docNameDone,
                ]}
              >
                {doc.name}
              </Text>
            </TouchableOpacity>
          ))}
        </Card>
      )}
      <View style={{ height: spacing.xl }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: spacing.md },
  title: { fontSize: 22, fontWeight: '800', marginTop: spacing.sm },
  metaRow: { flexDirection: 'row', alignItems: 'center', marginVertical: spacing.sm },
  meta: { fontSize: 13 },
  description: { fontSize: 15, lineHeight: 22 },
  authority: { fontSize: 13, marginTop: spacing.sm },
  dates: { fontSize: 13, marginTop: spacing.xs, fontWeight: '600' },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap' },
  blocker: { fontSize: 14, paddingVertical: 4 },
  hint: { fontSize: 11, marginTop: spacing.xs },
  resourceRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 7 },
  resourceIcon: { fontSize: 14, marginRight: spacing.sm },
  resourceLabel: { flex: 1, fontSize: 14, fontWeight: '600' },
  docRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 6 },
  docCheck: { fontSize: 17, marginRight: spacing.sm },
  docName: { fontSize: 15 },
  docNameDone: { textDecorationLine: 'line-through' },
});
