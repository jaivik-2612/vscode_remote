import { Plan } from './types';

/**
 * Milestone celebrations: when a newly created plan marks a milestone,
 * the app congratulates the user before showing the admin. Some milestones
 * are life-defining but not congratulatory — those are excluded.
 */

const NON_CELEBRATORY = new Set(['got-divorced']);

export function shouldCelebrate(plan: Plan): boolean {
  return plan.milestone === true && !NON_CELEBRATORY.has(plan.eventId);
}

const MESSAGES: Record<string, string> = {
  'new-child': 'A new life, a new chapter — congratulations to your growing family!',
  'got-married': 'Here’s to the two of you. Congratulations!',
  'planning-wedding': 'What a moment! Enjoy every bit of the planning.',
  'got-engaged': 'You said yes! Congratulations!',
  'bought-house': 'Home sweet home — congratulations on the keys!',
  'graduated-college': 'You earned every bit of this. Congratulations, graduate!',
  'turned-18': 'Welcome to adulthood — the world is yours now.',
  retired: 'A lifetime of work, well done. Enjoy every day of it!',
  'immigrate-canada': 'A brave new chapter ahead. Good luck on the journey!',
  'became-citizen': 'A new home, officially yours. Congratulations!',
  'paid-off-mortgage': 'The house is truly yours now. Incredible work!',
  'debt-free': 'Freedom feels good. Congratulations on getting there!',
  'wedding-anniversary': 'A milestone worth celebrating — happy anniversary!',
  'first-marathon': 'Every mile earned. Congratulations, runner!',
  'quit-smoking': 'One of the hardest things there is — and you’re doing it.',
};

const DEFAULT_MESSAGE = 'That’s a big one. Congratulations on this milestone!';

export function celebrationMessage(eventId: string): string {
  return MESSAGES[eventId] ?? DEFAULT_MESSAGE;
}
