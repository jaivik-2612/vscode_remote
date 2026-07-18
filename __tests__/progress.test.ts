import { generatePlan } from '../src/core/planner';
import { buildTimeline, daysBetween, groupByDomain, planProgress } from '../src/core/progress';
import { getEventTemplate } from '../src/core/templates';

const moved = getEventTemplate('moved')!;
const canada = getEventTemplate('immigrate-canada')!;

describe('planProgress', () => {
  test('counts done and skipped as resolved, flags overdue', () => {
    const plan = generatePlan({ template: moved, eventDate: '2026-06-01' });
    plan.tasks[0].status = 'done';
    plan.tasks[1].status = 'skipped';
    const progress = planProgress(plan, '2026-07-18');
    expect(progress.total).toBe(plan.tasks.length);
    expect(progress.done).toBe(2);
    expect(progress.fraction).toBeCloseTo(2 / plan.tasks.length);
    // Every unresolved task in this plan was due on or before 2026-07-01.
    expect(progress.overdue).toBe(plan.tasks.length - 2);
  });
});

describe('groupByDomain', () => {
  test('groups cover all tasks and are ordered by earliest deadline', () => {
    const plan = generatePlan({
      template: moved,
      eventDate: '2026-08-01',
      answers: { owns_vehicle: true, renting: true },
    });
    const groups = groupByDomain(plan);
    const regrouped = groups.flatMap((g) => g.tasks);
    expect(regrouped).toHaveLength(plan.tasks.length);
    const firstDues = groups.map((g) => g.tasks[0].dueDate);
    expect([...firstDues].sort()).toEqual(firstDues);
    expect(new Set(groups.map((g) => g.domain)).size).toBe(groups.length);
  });
});

describe('buildTimeline', () => {
  test('merges plans, excludes resolved tasks, sorts by urgency', () => {
    const movePlan = generatePlan({ template: moved, eventDate: '2026-08-01' });
    const canadaPlan = generatePlan({ template: canada, eventDate: '2027-05-01' });
    movePlan.tasks[0].status = 'done';

    const timeline = buildTimeline([movePlan, canadaPlan], '2026-07-18');
    expect(timeline).toHaveLength(movePlan.tasks.length - 1 + canadaPlan.tasks.length);
    const days = timeline.map((e) => e.daysUntilDue);
    expect([...days].sort((a, b) => a - b)).toEqual(days);
    // Entries carry their origin plan for the UI.
    expect(new Set(timeline.map((e) => e.planId)).size).toBe(2);
  });

  test('daysBetween is calendar-exact', () => {
    expect(daysBetween('2026-07-18', '2026-07-18')).toBe(0);
    expect(daysBetween('2026-07-18', '2026-08-01')).toBe(14);
    expect(daysBetween('2026-07-18', '2026-07-01')).toBe(-17);
  });
});
