import { CATEGORY_ORDER, EventCategory, LifeEventTemplate } from '../types';
import { moved } from './moved';
import { startedBusiness } from './startedBusiness';
import { immigrateCanada } from './immigrateCanada';
import { gotMarried } from './gotMarried';
import { newChild } from './newChild';
import {
  turned18,
  graduatedCollege,
  planningMarriage,
  boughtHouse,
  gotDivorced,
  retired,
} from './milestones';
import { newJob, lostJob, boughtCar, lovedOnePassed } from './important';
import { tripAbroad, newPet, homeRenovation } from './leisure';
import { extraMilestones } from './extraMilestones';
import { extraImportant } from './extraImportant';
import { extraLeisure } from './extraLeisure';
import { TASK_STEPS } from './steps';

/**
 * The catalog of life events the platform can administer. Featured events
 * (deeply authored) come first per category; the archetype-based long tail
 * follows and is reachable through typing / intent matching.
 */
export const EVENT_CATALOG: LifeEventTemplate[] = [
  // Featured milestones — roughly in life order
  turned18,
  graduatedCollege,
  planningMarriage,
  gotMarried,
  newChild,
  boughtHouse,
  immigrateCanada,
  gotDivorced,
  retired,
  // Featured important events
  moved,
  newJob,
  lostJob,
  startedBusiness,
  boughtCar,
  lovedOnePassed,
  // Featured leisure & lifestyle
  tripAbroad,
  newPet,
  homeRenovation,
  // The long tail
  ...extraMilestones,
  ...extraImportant,
  ...extraLeisure,
];

// Featured events author their sub-steps in steps.ts (archetype events carry
// them inline); attach them here so every task in the catalog has a checklist.
for (const event of EVENT_CATALOG) {
  for (const task of event.tasks) {
    if (!task.steps) task.steps = TASK_STEPS[task.id];
  }
}

export function getEventTemplate(id: string): LifeEventTemplate | undefined {
  return EVENT_CATALOG.find((e) => e.id === id);
}

/** Catalog grouped by category, categories in canonical order. */
export function eventsByCategory(): { category: EventCategory; events: LifeEventTemplate[] }[] {
  return CATEGORY_ORDER.map((category) => ({
    category,
    events: EVENT_CATALOG.filter((e) => e.category === category),
  })).filter((g) => g.events.length > 0);
}

/** Only featured events, grouped — what the home-screen picker shows. */
export function featuredByCategory(): { category: EventCategory; events: LifeEventTemplate[] }[] {
  return CATEGORY_ORDER.map((category) => ({
    category,
    events: EVENT_CATALOG.filter((e) => e.category === category && e.featured === true),
  })).filter((g) => g.events.length > 0);
}
