import React from 'react';
import { StyleSheet, Text, TouchableOpacity, View, ViewStyle } from 'react-native';
import { PlanTask, Priority } from '../core/types';
import { colors, domainColors, priorityColors, priorityLabels, spacing } from '../theme';

export function Card({ children, style }: { children: React.ReactNode; style?: ViewStyle }) {
  return <View style={[styles.card, style]}>{children}</View>;
}

export function Chip({
  label,
  onPress,
  selected,
}: {
  label: string;
  onPress?: () => void;
  selected?: boolean;
}) {
  return (
    <TouchableOpacity
      onPress={onPress}
      disabled={!onPress}
      style={[styles.chip, selected && styles.chipSelected]}
    >
      <Text style={[styles.chipText, selected && styles.chipTextSelected]}>{label}</Text>
    </TouchableOpacity>
  );
}

export function PriorityBadge({ priority }: { priority: Priority }) {
  return (
    <Text style={[styles.priority, { color: priorityColors[priority] }]}>
      {priorityLabels[priority]}
    </Text>
  );
}

export function ProgressBar({ fraction }: { fraction: number }) {
  return (
    <View style={styles.progressTrack}>
      <View style={[styles.progressFill, { width: `${Math.round(fraction * 100)}%` }]} />
    </View>
  );
}

export function statusGlyph(status: PlanTask['status']): string {
  switch (status) {
    case 'done':
      return '✓';
    case 'skipped':
      return '–';
    case 'in_progress':
      return '◐';
    case 'blocked':
      return '🔒';
    default:
      return '○';
  }
}

export function TaskRow({
  task,
  onPress,
  subtitle,
}: {
  task: PlanTask;
  onPress: () => void;
  subtitle?: string;
}) {
  const resolved = task.status === 'done' || task.status === 'skipped';
  const stepsNote =
    task.steps.length > 0 && !resolved
      ? ` · ${task.steps.filter((s) => s.done).length}/${task.steps.length} steps`
      : '';
  return (
    <TouchableOpacity onPress={onPress} style={styles.taskRow}>
      <View style={[styles.domainDot, { backgroundColor: domainColors[task.domain] }]} />
      <View style={{ flex: 1 }}>
        <Text style={[styles.taskTitle, resolved && styles.taskTitleDone]} numberOfLines={2}>
          {statusGlyph(task.status)} {task.title}
        </Text>
        <Text style={styles.taskSubtitle} numberOfLines={1}>
          {(subtitle ?? `Due ${task.dueDate}${task.authority ? ` · ${task.authority}` : ''}`) +
            stepsNote}
        </Text>
      </View>
      <PriorityBadge priority={task.priority} />
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.card,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    marginBottom: spacing.md,
  },
  chip: {
    borderRadius: 999,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.card,
    paddingVertical: 8,
    paddingHorizontal: 14,
    marginRight: spacing.sm,
    marginBottom: spacing.sm,
  },
  chipSelected: { backgroundColor: colors.accentSoft, borderColor: colors.accent },
  chipText: { color: colors.text, fontSize: 14 },
  chipTextSelected: { color: colors.accent, fontWeight: '600' },
  priority: { fontSize: 11, fontWeight: '700', marginLeft: spacing.sm },
  progressTrack: {
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.border,
    overflow: 'hidden',
  },
  progressFill: { height: 8, borderRadius: 4, backgroundColor: colors.accent },
  taskRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  domainDot: { width: 10, height: 10, borderRadius: 5, marginRight: spacing.sm },
  taskTitle: { fontSize: 15, color: colors.text },
  taskTitleDone: { color: colors.textSecondary, textDecorationLine: 'line-through' },
  taskSubtitle: { fontSize: 12, color: colors.textSecondary, marginTop: 2 },
});
