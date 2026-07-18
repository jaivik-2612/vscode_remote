import { DOMAIN_LABELS, Domain, Plan, PlanTask } from './types';

/** Aggregations the UI renders: overall progress, per-domain groups, and the cross-plan timeline. */

export interface PlanProgress {
  total: number;
  done: number;
  /** 0..1, skipped tasks count as resolved. */
  fraction: number;
  overdue: number;
}

export function planProgress(plan: Plan, todayIso: string): PlanProgress {
  const total = plan.tasks.length;
  const resolved = plan.tasks.filter((t) => t.status === 'done' || t.status === 'skipped');
  const overdue = plan.tasks.filter(
    (t) => t.status !== 'done' && t.status !== 'skipped' && t.dueDate < todayIso
  ).length;
  return {
    total,
    done: resolved.length,
    fraction: total === 0 ? 1 : resolved.length / total,
    overdue,
  };
}

export interface DomainGroup {
  domain: Domain;
  label: string;
  tasks: PlanTask[];
}

/** Group a plan's tasks by domain, groups ordered by their earliest due date. */
export function groupByDomain(plan: Plan): DomainGroup[] {
  const groups = new Map<Domain, PlanTask[]>();
  for (const task of plan.tasks) {
    const list = groups.get(task.domain) ?? [];
    list.push(task);
    groups.set(task.domain, list);
  }
  return [...groups.entries()]
    .map(([domain, tasks]) => ({ domain, label: DOMAIN_LABELS[domain], tasks }))
    .sort((a, b) => (a.tasks[0].dueDate < b.tasks[0].dueDate ? -1 : 1));
}

export interface TimelineEntry {
  planId: string;
  planName: string;
  emoji: string;
  task: PlanTask;
  daysUntilDue: number;
}

export function daysBetween(fromIso: string, toIso: string): number {
  const from = new Date(fromIso + 'T00:00:00Z').getTime();
  const to = new Date(toIso + 'T00:00:00Z').getTime();
  return Math.round((to - from) / 86_400_000);
}

/**
 * The unified deadline feed across all active plans: every unresolved task,
 * soonest deadline first.
 */
export function buildTimeline(plans: Plan[], todayIso: string): TimelineEntry[] {
  const entries: TimelineEntry[] = [];
  for (const plan of plans) {
    for (const task of plan.tasks) {
      if (task.status === 'done' || task.status === 'skipped') continue;
      entries.push({
        planId: plan.id,
        planName: plan.eventName,
        emoji: plan.emoji,
        task,
        daysUntilDue: daysBetween(todayIso, task.dueDate),
      });
    }
  }
  return entries.sort((a, b) => a.daysUntilDue - b.daysUntilDue);
}
