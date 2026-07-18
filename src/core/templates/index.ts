import { LifeEventTemplate } from '../types';
import { moved } from './moved';
import { startedBusiness } from './startedBusiness';
import { immigrateCanada } from './immigrateCanada';
import { gotMarried } from './gotMarried';
import { newChild } from './newChild';

/** The catalog of life events the platform can administer. */
export const EVENT_CATALOG: LifeEventTemplate[] = [
  moved,
  startedBusiness,
  immigrateCanada,
  gotMarried,
  newChild,
];

export function getEventTemplate(id: string): LifeEventTemplate | undefined {
  return EVENT_CATALOG.find((e) => e.id === id);
}
