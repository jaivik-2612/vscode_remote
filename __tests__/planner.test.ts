import { addDays, generatePlan, reconcileBlocked } from '../src/core/planner';
import { getEventTemplate } from '../src/core/templates';
import { Plan } from '../src/core/types';

const moved = getEventTemplate('moved')!;
const business = getEventTemplate('started-business')!;
const canada = getEventTemplate('immigrate-canada')!;

describe('addDays', () => {
  test('adds and subtracts across month boundaries', () => {
    expect(addDays('2026-07-18', 14)).toBe('2026-08-01');
    expect(addDays('2026-07-18', -21)).toBe('2026-06-27');
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
  });
});

describe('generatePlan', () => {
  test('resolves offsets against the event date', () => {
    const plan = generatePlan({ template: moved, eventDate: '2026-08-01' });
    const licence = plan.tasks.find((t) => t.id === 'moved.licence_address')!;
    expect(licence.startDate).toBe('2026-08-01');
    expect(licence.dueDate).toBe('2026-08-15');
  });

  test('boolean answers gate optional tasks out by default', () => {
    const plan = generatePlan({ template: moved, eventDate: '2026-08-01' });
    const ids = plan.tasks.map((t) => t.id);
    expect(ids).not.toContain('moved.new_licence');
    expect(ids).not.toContain('moved.vehicle_reregister');
    expect(ids).not.toContain('moved.renters_insurance');
  });

  test('boolean answers gate optional tasks in when true', () => {
    const plan = generatePlan({
      template: moved,
      eventDate: '2026-08-01',
      answers: { crossed_state: true, owns_vehicle: true, renting: true },
    });
    const ids = plan.tasks.map((t) => t.id);
    expect(ids).toContain('moved.new_licence');
    expect(ids).toContain('moved.vehicle_reregister');
    expect(ids).toContain('moved.renters_insurance');
  });

  test('dependencies on excluded tasks are dropped', () => {
    // biz.payroll depends on biz.employer_accounts which is gated by has_employees.
    // With has_employees=false both are excluded; nothing should reference them.
    const plan = generatePlan({
      template: business,
      eventDate: '2026-09-01',
      answers: { has_employees: false },
    });
    const ids = new Set(plan.tasks.map((t) => t.id));
    for (const task of plan.tasks) {
      for (const dep of task.dependsOn) {
        expect(ids.has(dep)).toBe(true);
      }
    }
  });

  test('tasks with pending dependencies start blocked, others pending', () => {
    const plan = generatePlan({ template: business, eventDate: '2026-09-01' });
    const nameCheck = plan.tasks.find((t) => t.id === 'biz.name_check')!;
    const register = plan.tasks.find((t) => t.id === 'biz.register')!;
    expect(nameCheck.status).toBe('pending');
    expect(register.status).toBe('blocked');
  });

  test('tasks are sorted by due date', () => {
    const plan = generatePlan({ template: canada, eventDate: '2027-03-01' });
    const dues = plan.tasks.map((t) => t.dueDate);
    expect([...dues].sort()).toEqual(dues);
  });

  test('immigration plan spans eligibility through status monitoring', () => {
    const plan = generatePlan({
      template: canada,
      eventDate: '2027-03-01',
      answers: { has_degree: true, has_spouse: false },
    });
    const ids = plan.tasks.map((t) => t.id);
    expect(ids).toContain('imm.eligibility');
    expect(ids).toContain('imm.eca');
    expect(ids).toContain('imm.application');
    expect(ids).toContain('imm.monitor');
    expect(ids).not.toContain('imm.spouse_docs');
  });

  test('document checklists are instantiated uncollected', () => {
    const plan = generatePlan({ template: moved, eventDate: '2026-08-01' });
    const licence = plan.tasks.find((t) => t.id === 'moved.licence_address')!;
    expect(licence.documents.length).toBeGreaterThan(0);
    expect(licence.documents.every((d) => d.collected === false)).toBe(true);
  });
});

describe('reconcileBlocked', () => {
  function setStatus(plan: Plan, id: string, status: Plan['tasks'][number]['status']): Plan {
    return {
      ...plan,
      tasks: plan.tasks.map((t) => (t.id === id ? { ...t, status } : t)),
    };
  }

  test('completing a dependency unblocks its dependents', () => {
    let plan = generatePlan({ template: business, eventDate: '2026-09-01' });
    expect(plan.tasks.find((t) => t.id === 'biz.register')!.status).toBe('blocked');
    plan = reconcileBlocked(setStatus(plan, 'biz.name_check', 'done'));
    expect(plan.tasks.find((t) => t.id === 'biz.register')!.status).toBe('pending');
    // Grandchild still blocked: tax_id depends on register.
    expect(plan.tasks.find((t) => t.id === 'biz.tax_id')!.status).toBe('blocked');
  });

  test('skipped dependencies also unblock', () => {
    let plan = generatePlan({ template: business, eventDate: '2026-09-01' });
    plan = reconcileBlocked(setStatus(plan, 'biz.name_check', 'skipped'));
    expect(plan.tasks.find((t) => t.id === 'biz.register')!.status).toBe('pending');
  });

  test('un-completing a dependency re-blocks dependents', () => {
    let plan = generatePlan({ template: business, eventDate: '2026-09-01' });
    plan = reconcileBlocked(setStatus(plan, 'biz.name_check', 'done'));
    plan = reconcileBlocked(setStatus(plan, 'biz.name_check', 'pending'));
    expect(plan.tasks.find((t) => t.id === 'biz.register')!.status).toBe('blocked');
  });

  test('does not touch tasks the user marked in_progress or done', () => {
    let plan = generatePlan({ template: business, eventDate: '2026-09-01' });
    plan = setStatus(plan, 'biz.register', 'in_progress');
    plan = reconcileBlocked(plan);
    expect(plan.tasks.find((t) => t.id === 'biz.register')!.status).toBe('in_progress');
  });
});
