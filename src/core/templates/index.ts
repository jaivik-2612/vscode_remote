import { CATEGORY_ORDER, EventCategory, LifeEventTemplate } from '../types';
import { moved } from './moved';
import { startedBusiness } from './startedBusiness';
import { immigrateCanada } from './immigrateCanada';
import { gotMarried } from './gotMarried';
import { newChild } from './newChild';
import { turned18, graduatedCollege, boughtHouse, gotDivorced, retired } from './milestones';
import { newJob, lostJob, boughtCar, lovedOnePassed } from './important';
import { tripAbroad, newPet, homeRenovation } from './leisure';
import { extraMilestones } from './extraMilestones';
import { extraImportant } from './extraImportant';
import { extraLeisure } from './extraLeisure';

/**
 * The catalog of life events the platform can administer. Featured events
 * (deeply authored) come first per category; the archetype-based long tail
 * follows and is reachable through typing / intent matching.
 */
export const EVENT_CATALOG: LifeEventTemplate[] = [
  // Featured milestones — roughly in life order
  turned18,
  graduatedCollege,
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
