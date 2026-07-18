import {
  DocumentItem,
  IntakeQuestion,
  LifeEventTemplate,
  Plan,
  PlanTask,
  StepItem,
  TaskTemplate,
} from './types';

/**
 * Turns a life-event template + intake answers + event date into a concrete,
 * deadline-aware plan:
 *  - boolean intake answers gate optional tasks in or out
 *  - offsets resolve to real ISO dates against the event date
 *  - dependencies on excluded tasks are dropped
 *  - tasks whose dependencies are incomplete start as 'blocked'
 */

export function addDays(isoDate: string, days: number): string {
  const d = new Date(isoDate + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Task ids excluded because a gating boolean question was answered false (or unanswered). */
function excludedTaskIds(
  questions: IntakeQuestion[],
  answers: Record<string, string | boolean>
): Set<string> {
  const excluded = new Set<string>();
  for (const q of questions) {
    if (q.kind === 'boolean' && q.gatesTasks) {
      if (answers[q.id] !== true) {
        for (const id of q.gatesTasks) excluded.add(id);
      }
    }
  }
  return excluded;
}

function toDocuments(template: TaskTemplate): DocumentItem[] {
  return (template.documents ?? []).map((name) => ({ name, collected: false }));
}

function toSteps(template: TaskTemplate): StepItem[] {
  return (template.steps ?? []).map((name) => ({ name, done: false }));
}

export interface GeneratePlanInput {
  template: LifeEventTemplate;
  /** ISO date (YYYY-MM-DD) the event takes effect. */
  eventDate: string;
  answers?: Record<string, string | boolean>;
  /** Injectable for testability; defaults to a random-ish id. */
  planId?: string;
  /** ISO timestamp of creation; injectable for testability. */
  createdAt?: string;
}

export function generatePlan(input: GeneratePlanInput): Plan {
  const { template, eventDate } = input;
  const answers = input.answers ?? {};
  const excluded = excludedTaskIds(template.questions, answers);

  const included = template.tasks.filter((t) => !excluded.has(t.id));
  const includedIds = new Set(included.map((t) => t.id));

  const tasks: PlanTask[] = included.map((t) => {
    const dependsOn = (t.dependsOn ?? []).filter((id) => includedIds.has(id));
    return {
      id: t.id,
      templateId: t.id,
      title: t.title,
      description: t.description,
      domain: t.domain,
      priority: t.priority,
      authority: t.authority,
      startDate: addDays(eventDate, t.startOffsetDays),
      dueDate: addDays(eventDate, t.dueOffsetDays),
      status: dependsOn.length > 0 ? 'blocked' : 'pending',
      dependsOn,
      documents: toDocuments(t),
      steps: toSteps(t),
    };
  });

  tasks.sort((a, b) => (a.dueDate < b.dueDate ? -1 : a.dueDate > b.dueDate ? 1 : 0));

  return {
    id: input.planId ?? `plan-${template.id}-${Math.random().toString(36).slice(2, 10)}`,
    eventId: template.id,
    eventName: template.name,
    emoji: template.emoji,
    createdAt: input.createdAt ?? new Date().toISOString(),
    eventDate,
    milestone:
      template.category === 'milestone' ||
      (template.isMilestone ? template.isMilestone(answers) === true : false),
    answers,
    tasks,
  };
}

/**
 * Recompute blocked/pending across a plan after any status change:
 * a task is blocked while any dependency is not done/skipped. Tasks the user
 * explicitly set to in_progress/done/skipped are left alone.
 */
export function reconcileBlocked(plan: Plan): Plan {
  const byId = new Map(plan.tasks.map((t) => [t.id, t]));
  const tasks = plan.tasks.map((t) => {
    if (t.status !== 'pending' && t.status !== 'blocked') return t;
    const blocked = t.dependsOn.some((id) => {
      const dep = byId.get(id);
      return dep !== undefined && dep.status !== 'done' && dep.status !== 'skipped';
    });
    const status: PlanTask['status'] = blocked ? 'blocked' : 'pending';
    return status === t.status ? t : { ...t, status };
  });
  return { ...plan, tasks };
}
