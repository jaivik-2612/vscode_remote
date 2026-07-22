import React from 'react';
import { StyleSheet, Text, TouchableOpacity, View, ViewStyle } from 'react-native';
import { PlanTask, Priority } from '../core/types';
import { useTheme } from '../state/theme';
import { cardShadow, domainColors, priorityColor, priorityLabels, radius, spacing } from '../theme';

export function Card({ children, style }: { children: React.ReactNode; style?: ViewStyle }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.card, cardShadow, { backgroundColor: colors.card }, style]}>
      {children}
    </View>
  );
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
  const { colors } = useTheme();
  return (
    <TouchableOpacity
      onPress={onPress}
      disabled={!onPress}
      style={[
        styles.chip,
        { backgroundColor: colors.card, borderColor: colors.line },
        selected && { backgroundColor: colors.soft, borderColor: colors.accent },
      ]}
    >
      <Text style={[styles.chipText, { color: selected ? colors.accent : colors.ink }, selected && styles.chipTextSelected]}>
        {label}
      </Text>
    </TouchableOpacity>
  );
}

export function PriorityBadge({ priority }: { priority: Priority }) {
  const { colors } = useTheme();
  return (
    <Text style={[styles.priority, { color: priorityColor(priority, colors) }]}>
      {priorityLabels[priority]}
    </Text>
  );
}

export function ProgressBar({ fraction }: { fraction: number }) {
  const { colors } = useTheme();
  return (
    <View style={[styles.progressTrack, { backgroundColor: colors.line }]}>
      <View
        style={[
          styles.progressFill,
          { backgroundColor: colors.accent, width: `${Math.round(fraction * 100)}%` },
        ]}
      />
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
  const { colors } = useTheme();
  const resolved = task.status === 'done' || task.status === 'skipped';
  const stepsNote =
    task.steps.length > 0 && !resolved
      ? ` · ${task.steps.filter((s) => s.done).length}/${task.steps.length} steps`
      : '';
  return (
    <TouchableOpacity onPress={onPress} style={[styles.taskRow, { borderBottomColor: colors.line }]}>
      <View style={[styles.domainDot, { backgroundColor: domainColors[task.domain] }]} />
      <View style={{ flex: 1 }}>
        <Text
          style={[
            styles.taskTitle,
            { color: resolved ? colors.muted : colors.ink },
            resolved && styles.taskTitleDone,
          ]}
          numberOfLines={2}
        >
          {statusGlyph(task.status)} {task.title}
        </Text>
        <Text style={[styles.taskSubtitle, { color: colors.muted }]} numberOfLines={1}>
          {(subtitle ?? `Due ${task.dueDate}${task.authority ? ` · ${task.authority}` : ''}`) +
            stepsNote}
        </Text>
      </View>
      <PriorityBadge priority={task.priority} />
    </TouchableOpacity>
  );
}

export function SectionTitle({ children }: { children: React.ReactNode }) {
  const { colors } = useTheme();
  return <Text style={[styles.sectionTitle, { color: colors.muted }]}>{children}</Text>;
}

const styles = StyleSheet.create({
  card: {
    borderRadius: radius.card,
    padding: spacing.md,
    marginBottom: spacing.md,
  },
  chip: {
    borderRadius: radius.chip,
    borderWidth: 1,
    paddingVertical: 8,
    paddingHorizontal: 14,
    marginRight: spacing.sm,
    marginBottom: spacing.sm,
  },
  chipText: { fontSize: 14 },
  chipTextSelected: { fontWeight: '600' },
  priority: { fontSize: 11, fontWeight: '700', marginLeft: spacing.sm },
  progressTrack: { height: 8, borderRadius: 4, overflow: 'hidden' },
  progressFill: { height: 8, borderRadius: 4 },
  taskRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  domainDot: { width: 10, height: 10, borderRadius: 5, marginRight: spacing.sm },
  taskTitle: { fontSize: 15 },
  taskTitleDone: { textDecorationLine: 'line-through' },
  taskSubtitle: { fontSize: 12, marginTop: 2 },
  sectionTitle: {
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginBottom: spacing.sm,
    marginTop: spacing.sm,
  },
});
