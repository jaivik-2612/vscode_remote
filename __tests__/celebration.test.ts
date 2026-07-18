import { celebrationMessage, shouldCelebrate } from '../src/core/celebration';
import { generatePlan } from '../src/core/planner';
import { getEventTemplate } from '../src/core/templates';

function plan(eventId: string, answers: Record<string, string | boolean> = {}) {
  return generatePlan({ template: getEventTemplate(eventId)!, eventDate: '2026-09-01', answers });
}

describe('milestone celebrations', () => {
  test('milestone events celebrate', () => {
    expect(shouldCelebrate(plan('new-child'))).toBe(true);
    expect(shouldCelebrate(plan('got-married'))).toBe(true);
    expect(shouldCelebrate(plan('planning-wedding'))).toBe(true);
    expect(shouldCelebrate(plan('graduated-college'))).toBe(true);
  });

  test('divorce is a milestone but never congratulated', () => {
    const divorce = plan('got-divorced');
    expect(divorce.milestone).toBe(true);
    expect(shouldCelebrate(divorce)).toBe(false);
  });

  test('non-milestone events do not celebrate', () => {
    expect(shouldCelebrate(plan('moved'))).toBe(false);
    expect(shouldCelebrate(plan('lost-job'))).toBe(false);
  });

  test('milestone anniversaries celebrate, off-years do not', () => {
    expect(shouldCelebrate(plan('wedding-anniversary', { anniversary_year: '10' }))).toBe(true);
    expect(shouldCelebrate(plan('wedding-anniversary', { anniversary_year: '3' }))).toBe(false);
  });

  test('event-specific messages with a warm default', () => {
    expect(celebrationMessage('new-child')).toContain('growing family');
    expect(celebrationMessage('bought-house')).toContain('keys');
    expect(celebrationMessage('turned-50')).toContain('Congratulations');
  });
});
