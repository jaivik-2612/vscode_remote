import { CATEGORY_ORDER, EventCategory, LifeEventTemplate } from '../types';
import { moved } from './moved';
import { startedBusiness } from './startedBusiness';
import { immigrateCanada } from './immigrateCanada';
import { gotMarried } from './gotMarried';
import { newChild } from './newChild';
import { turned18, graduatedCollege, boughtHouse, gotDivorced, retired } from './milestones';
import { newJob, lostJob, boughtCar, lovedOnePassed } from './important';
import { tripAbroad, newPet, homeRenovation } from './leisure';

/** The catalog of life events the platform can administer, in category order. */
export const EVENT_CATALOG: LifeEventTemplate[] = [
  // Milestones — roughly in life order
  turned18,
  graduatedCollege,
  gotMarried,
  newChild,
  boughtHouse,
  immigrateCanada,
  gotDivorced,
  retired,
  // Important events
  moved,
  newJob,
  lostJob,
  startedBusiness,
  boughtCar,
  lovedOnePassed,
  // Leisure & lifestyle
  tripAbroad,
  newPet,
  homeRenovation,
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
