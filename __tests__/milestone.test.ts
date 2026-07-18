import { generatePlan } from '../src/core/planner';
import { getEventTemplate } from '../src/core/templates';

describe('milestone plans', () => {
  const anniversary = getEventTemplate('wedding-anniversary')!;

  test('anniversary is an important-category event', () => {
    expect(anniversary.category).toBe('important');
  });

  test('5th/10th/25th anniversaries become milestone plans', () => {
    for (const year of ['5', '10', '25', '50', '5th', '10th anniversary']) {
      const plan = generatePlan({
        template: anniversary,
        eventDate: '2026-09-12',
        answers: { anniversary_year: year },
      });
      expect(plan.milestone).toBe(true);
    }
  });

  test('off-cycle anniversaries stay non-milestone', () => {
    for (const year of ['1', '3', '7', '12', '', 'soon']) {
      const plan = generatePlan({
        template: anniversary,
        eventDate: '2026-09-12',
        answers: { anniversary_year: year },
      });
      expect(plan.milestone).toBe(false);
    }
  });

  test('milestone-category events always produce milestone plans', () => {
    const grad = getEventTemplate('graduated-college')!;
    const plan = generatePlan({ template: grad, eventDate: '2026-06-01' });
    expect(plan.milestone).toBe(true);
  });

  test('ordinary important events stay non-milestone', () => {
    const movedTemplate = getEventTemplate('moved')!;
    const plan = generatePlan({ template: movedTemplate, eventDate: '2026-06-01' });
    expect(plan.milestone).toBe(false);
  });
});
