import { EVENT_CATALOG, eventsByCategory } from '../src/core/templates';
import { CATEGORY_ORDER, DOMAIN_LABELS } from '../src/core/types';

/**
 * Integrity checks for the event database. As the catalog grows these catch
 * the failure modes hand-authored data is prone to: duplicate ids, dangling
 * dependency/gate references, and impossible date windows.
 */

describe('event catalog integrity', () => {
  test('event ids are unique', () => {
    const ids = EVENT_CATALOG.map((e) => e.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  test('every event has a valid category', () => {
    for (const event of EVENT_CATALOG) {
      expect(CATEGORY_ORDER).toContain(event.category);
    }
  });

  test('eventsByCategory covers the whole catalog in canonical order', () => {
    const groups = eventsByCategory();
    expect(groups.map((g) => g.category)).toEqual(
      CATEGORY_ORDER.filter((c) => EVENT_CATALOG.some((e) => e.category === c))
    );
    const total = groups.reduce((n, g) => n + g.events.length, 0);
    expect(total).toBe(EVENT_CATALOG.length);
  });

  test('task ids are globally unique', () => {
    const ids = EVENT_CATALOG.flatMap((e) => e.tasks.map((t) => t.id));
    expect(new Set(ids).size).toBe(ids.length);
  });

  test('every dependsOn points at a task in the same template', () => {
    for (const event of EVENT_CATALOG) {
      const ids = new Set(event.tasks.map((t) => t.id));
      for (const task of event.tasks) {
        for (const dep of task.dependsOn ?? []) {
          if (!ids.has(dep)) {
            throw new Error(`${event.id}: task ${task.id} depends on unknown ${dep}`);
          }
        }
      }
    }
  });

  test('every gatesTasks entry points at a task in the same template', () => {
    for (const event of EVENT_CATALOG) {
      const ids = new Set(event.tasks.map((t) => t.id));
      for (const q of event.questions) {
        for (const gated of q.gatesTasks ?? []) {
          if (!ids.has(gated)) {
            throw new Error(`${event.id}: question ${q.id} gates unknown task ${gated}`);
          }
        }
      }
    }
  });

  test('every task window is possible (start <= due) and uses a known domain', () => {
    for (const event of EVENT_CATALOG) {
      for (const task of event.tasks) {
        if (task.startOffsetDays > task.dueOffsetDays) {
          throw new Error(`${event.id}: task ${task.id} starts after its due date`);
        }
        expect(DOMAIN_LABELS[task.domain]).toBeDefined();
      }
    }
  });

  test('every event has trigger phrases, keywords, a date question, and tasks', () => {
    for (const event of EVENT_CATALOG) {
      expect(event.triggerPhrases.length).toBeGreaterThan(0);
      expect(event.keywords.length).toBeGreaterThan(0);
      expect(event.tasks.length).toBeGreaterThanOrEqual(4);
      expect(event.questions.some((q) => q.kind === 'date')).toBe(true);
    }
  });

  test('the catalog spans all three categories', () => {
    const cats = new Set(EVENT_CATALOG.map((e) => e.category));
    expect(cats).toEqual(new Set(['milestone', 'important', 'leisure']));
  });
});
