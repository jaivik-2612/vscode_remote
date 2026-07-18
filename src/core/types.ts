/**
 * Core domain model for the Universal Life Administration Platform.
 *
 * The world is administratively fragmented: one life event (moving, starting a
 * business, immigrating) fans out into obligations across many unrelated
 * institutions. These types model that fan-out declaratively so a single
 * planner can turn "what happened" into a coordinated, deadline-aware plan.
 */

/** An administrative sphere of life affected by an event. */
export type Domain =
  | 'government'
  | 'finance'
  | 'insurance'
  | 'tax'
  | 'employment'
  | 'utilities'
  | 'housing'
  | 'health'
  | 'legal'
  | 'immigration'
  | 'business'
  | 'education'
  | 'travel'
  | 'social';

export const DOMAIN_LABELS: Record<Domain, string> = {
  government: 'Government records',
  finance: 'Banks & finance',
  insurance: 'Insurance',
  tax: 'Tax',
  employment: 'Employer & work',
  utilities: 'Utilities & services',
  housing: 'Housing',
  health: 'Health',
  legal: 'Legal',
  immigration: 'Immigration',
  business: 'Business',
  education: 'Education',
  travel: 'Travel & bookings',
  social: 'Events & celebrations',
};

/**
 * The catalog is organized in three shelves: milestones (the big life
 * transitions), important events (high-stakes admin that isn't a lifelong
 * marker), and leisure (chosen projects that still carry real admin).
 */
export type EventCategory = 'milestone' | 'important' | 'leisure';

export const CATEGORY_LABELS: Record<EventCategory, string> = {
  milestone: 'Milestone events',
  important: 'Important events',
  leisure: 'Leisure & lifestyle',
};

export const CATEGORY_ORDER: EventCategory[] = ['milestone', 'important', 'leisure'];

export type Priority = 'critical' | 'high' | 'medium' | 'low';

/** A question asked before generating a plan, to tailor it. */
export interface IntakeQuestion {
  id: string;
  prompt: string;
  kind: 'text' | 'date' | 'choice' | 'boolean';
  choices?: string[];
  /** Task ids that are only included when the boolean answer is true. */
  gatesTasks?: string[];
}

/** A template for one obligation triggered by a life event. */
export interface TaskTemplate {
  id: string;
  title: string;
  description: string;
  domain: Domain;
  priority: Priority;
  /** The institution or authority involved, e.g. "DMV", "IRCC", "Your bank". */
  authority?: string;
  /** Days relative to the event date when work can start (negative = before). */
  startOffsetDays: number;
  /** Days relative to the event date when this is due. */
  dueOffsetDays: number;
  /** Documents needed to complete this task. */
  documents?: string[];
  /** Ids of tasks (same template) that must be completed first. */
  dependsOn?: string[];
}

/** A life event the platform knows how to administer. */
export interface LifeEventTemplate {
  id: string;
  name: string;
  emoji: string;
  summary: string;
  category: EventCategory;
  /** Featured events appear in the home-screen picker; the rest are reachable by typing. */
  featured?: boolean;
  /**
   * Optional rule that upgrades a generated plan to milestone status based on
   * intake answers (e.g. a 5th/10th/25th wedding anniversary).
   */
  isMilestone?: (answers: Record<string, string | boolean>) => boolean;
  /** Phrases and keywords used by the intent matcher. */
  triggerPhrases: string[];
  keywords: string[];
  questions: IntakeQuestion[];
  tasks: TaskTemplate[];
}

export type TaskStatus = 'pending' | 'blocked' | 'in_progress' | 'done' | 'skipped';

/** A concrete task instance inside a generated plan. */
export interface PlanTask {
  id: string;
  templateId: string;
  title: string;
  description: string;
  domain: Domain;
  priority: Priority;
  authority?: string;
  /** ISO dates resolved against the event date. */
  startDate: string;
  dueDate: string;
  status: TaskStatus;
  dependsOn: string[];
  documents: DocumentItem[];
}

export interface DocumentItem {
  name: string;
  collected: boolean;
}

/** A generated, live plan for one life event. */
export interface Plan {
  id: string;
  eventId: string;
  eventName: string;
  emoji: string;
  createdAt: string;
  /** ISO date the event takes / took effect. */
  eventDate: string;
  /** True for milestone-category events or when the template's isMilestone rule fires. */
  milestone: boolean;
  answers: Record<string, string | boolean>;
  tasks: PlanTask[];
}

/** Result of matching free-form user input against the event catalog. */
export interface IntentMatch {
  event: LifeEventTemplate;
  score: number;
  /** Which phrases/keywords produced the match, for explainability. */
  matchedOn: string[];
}
