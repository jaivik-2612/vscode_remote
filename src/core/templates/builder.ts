import {
  Domain,
  EventCategory,
  IntakeQuestion,
  LifeEventTemplate,
  Priority,
  TaskTemplate,
} from '../types';

/**
 * Compact authoring for the long tail of the catalog. Archetype packs below
 * generate real 4–6 task plans from one-line event definitions, so the
 * catalog can grow into the hundreds without hand-writing every task.
 * Deeply-authored events (the featured ones) don't use this.
 */

/** [id, title, description, domain, priority, startOffset, dueOffset, deps?, docs?] */
export type T = [string, string, string, Domain, Priority, number, number, string[]?, string[]?];

function expand(eventId: string, specs: T[]): TaskTemplate[] {
  return specs.map(([id, title, description, domain, priority, start, due, deps, docs]) => ({
    id: `${eventId}.${id}`,
    title,
    description,
    domain,
    priority,
    startOffsetDays: start,
    dueOffsetDays: due,
    dependsOn: deps?.map((d) => `${eventId}.${d}`),
    documents: docs,
  }));
}

export interface EventSpec {
  id: string;
  name: string;
  emoji: string;
  category: EventCategory;
  tasks: T[];
  phrases: string[];
  keywords: string[];
  summary?: string;
  questions?: IntakeQuestion[];
  featured?: boolean;
  isMilestone?: LifeEventTemplate['isMilestone'];
}

export function E(spec: EventSpec): LifeEventTemplate {
  const questions: IntakeQuestion[] = spec.questions ? [...spec.questions] : [];
  if (!questions.some((q) => q.kind === 'date')) {
    questions.unshift({ id: 'event_date', prompt: 'When is (was) it?', kind: 'date' });
  }
  return {
    id: spec.id,
    name: spec.name,
    emoji: spec.emoji,
    category: spec.category,
    featured: spec.featured ?? false,
    isMilestone: spec.isMilestone,
    summary:
      spec.summary ??
      `A coordinated checklist for this: budget, bookings, paperwork and deadlines, in the order they depend on each other.`,
    triggerPhrases: spec.phrases,
    keywords: spec.keywords,
    questions,
    tasks: expand(spec.id, spec.tasks),
  };
}

/* ============ archetype task packs ============ */

/** Parties and ceremonies. */
export function celebration(s: string): T[] {
  return [
    ['plan', `Set the date, budget and guest list for ${s}`, `Everything else hangs off these three decisions — lock them first.`, 'finance', 'critical', -60, -45],
    ['venue', `Book the venue or prepare the space`, `Popular venues and weekends book out far ahead; confirm capacity, deposit and cancellation terms in writing.`, 'social', 'high', -45, -30, ['plan']],
    ['invites', `Send invitations and track RSVPs`, `Send early enough for people to plan; keep one list of RSVPs, dietary needs and plus-ones.`, 'social', 'high', -30, -14, ['venue']],
    ['catering', `Arrange food, drinks and the cake`, `Confirm final headcount with caterers about a week out; ask guests about allergies before fixing the menu.`, 'social', 'high', -21, -7, ['plan']],
    ['program', `Plan the program, music and photos`, `Decide the running order, who speaks, and who is capturing photos so the day runs itself.`, 'social', 'medium', -21, -7],
    ['runsheet', `Confirm all vendors and write the day-of run sheet`, `One page: times, contacts, deliveries, and who is responsible for what.`, 'social', 'medium', -7, -1, ['invites']],
  ];
}

/** Children's parties — celebration plus kid-specific safety. */
export function kidParty(s: string): T[] {
  return [
    ['plan', `Pick the date, theme and budget for ${s}`, `Check the school and sports calendar for clashes, agree the guest list with your kid, and set the budget.`, 'finance', 'critical', -45, -30],
    ['venue', `Book the venue or plan the home setup`, `Party venues for popular weekend slots go fast; for home parties plan the space, weather backup and seating.`, 'social', 'high', -30, -21, ['plan']],
    ['invites', `Send invitations and track RSVPs`, `Via the class group or parents directly; collect RSVPs and each child's pickup arrangements.`, 'social', 'high', -21, -10, ['venue']],
    ['allergies', `Collect allergies and dietary needs from parents`, `Nut allergies and intolerances are common — ask every parent explicitly, and plan the menu around the answers.`, 'health', 'critical', -14, -7, ['invites']],
    ['food_cake', `Order the cake and plan food and favors`, `Order the cake a week ahead; keep food simple and label anything allergen-relevant.`, 'social', 'high', -10, -3, ['allergies']],
    ['activities', `Plan activities, entertainment and supervision`, `Age-appropriate games or an entertainer, plus enough adults for supervision and a first-aid kit on hand.`, 'social', 'medium', -14, -2],
  ];
}

/** Trips; abroad adds documents & insurance. */
export function trip(s: string, abroad: boolean): T[] {
  const base: T[] = [
    ['plan', `Set dates, budget and destination details for ${s}`, `Fix the dates with everyone traveling, set the budget, and check seasonal factors (weather, peak pricing, closures).`, 'travel', 'critical', -60, -45],
    ['book', `Book transport and accommodation`, `Book with names matching ID documents exactly, and keep confirmations in one place.`, 'travel', 'critical', -45, -21, ['plan']],
    ['activities', `Reserve key activities and local transport`, `The things that sell out — tours, restaurants, rental cars, park passes — get booked now, the rest stays flexible.`, 'travel', 'medium', -21, -7, ['book']],
    ['home_prep', `Prepare the home front`, `Mail hold, plants, pets, deliveries paused, and someone with a key who knows you're away.`, 'housing', 'medium', -14, -1],
  ];
  if (abroad) {
    base.splice(1, 0,
      ['docs', `Check passports, visas and entry rules`, `Six months passport validity, visas or e-authorizations for every traveler, and entry requirements for each country on the route.`, 'government', 'critical', -75, -30, ['plan']],
      ['insurance', `Get travel and medical insurance`, `Domestic health coverage usually stops at the border — cover medical, cancellation and baggage.`, 'insurance', 'high', -30, -14, ['plan']]);
  }
  return base;
}

/** Significant purchases. */
export function purchase(s: string, opts?: { register?: boolean; insure?: boolean }): T[] {
  const t: T[] = [
    ['research', `Research and compare options for ${s}`, `Set requirements, compare models/providers and total cost of ownership, and read the fine print before deciding.`, 'finance', 'high', -30, -14],
    ['budget', `Confirm the budget and how you'll pay`, `Cash, financing or lease — settle it before negotiating, and leave room for the costs that follow the purchase.`, 'finance', 'high', -21, -7, ['research']],
    ['buy', `Complete the purchase and keep the paperwork`, `Invoice, warranty registration and receipts filed where you can find them — warranty claims die on missing paperwork.`, 'finance', 'critical', 0, 7, ['budget']],
    ['setup', `Set up, install and learn the essentials`, `Do the setup properly once: installation, safety basics, and any manufacturer registration for recalls.`, 'housing', 'medium', 0, 21, ['buy']],
  ];
  if (opts?.insure) t.push(['insure', `Insure it or add it to an existing policy`, `Check whether home/contents coverage already applies or a rider is needed.`, 'insurance', 'high', 0, 14, ['buy']]);
  if (opts?.register) t.push(['register', `Register it with the relevant authority`, `Registration deadlines are typically 10–30 days with late fees after.`, 'government', 'high', 0, 30, ['buy']]);
  return t;
}

/** Government / institutional applications. */
export function application(s: string, authority: string): T[] {
  return [
    ['eligibility', `Confirm eligibility and requirements for ${s}`, `Read the current official requirements — rules and fees change, and secondhand advice ages badly.`, 'government', 'critical', -30, -21],
    ['documents', `Gather the required documents`, `Work from the official checklist; order anything with lead time (certificates, translations, photos) first.`, 'government', 'critical', -21, -7, ['eligibility']],
    ['submit', `Complete and submit the application`, `Answer exactly and consistently with your documents; keep a full copy of what you submitted.`, 'government', 'critical', 0, 7, ['documents'], ['Application forms', 'Supporting documents', 'Fee payment']],
    ['track', `Track status and respond to requests fast`, `Requests for more information have short response windows — check the portal or mail regularly.`, 'government', 'high', 7, 60, ['submit']],
    ['store', `Store the result with your key documents`, `The approval/licence/certificate joins your permanent records; note any renewal date.`, 'legal', 'low', 30, 90, ['track']],
  ];
}

/** Medical procedures and treatments. */
export function medical(s: string): T[] {
  return [
    ['consult', `Get the consultation and referral for ${s}`, `Understand options, risks and recovery time; get the referral chain your insurer requires.`, 'health', 'critical', -30, -14],
    ['approval', `Confirm insurance coverage / pre-approval`, `Pre-authorization requirements are strict — confirm in writing what is covered and what you'll owe.`, 'insurance', 'critical', -21, -7, ['consult']],
    ['schedule', `Schedule it and follow the prep instructions`, `Book the date, arrange transport home if needed, and follow pre-procedure instructions exactly.`, 'health', 'critical', -14, -1, ['approval']],
    ['work', `Arrange time off and support`, `Sick leave or accommodations with your employer, and help at home for the recovery window.`, 'employment', 'high', -14, -1],
    ['recovery', `Manage recovery, follow-ups and claims`, `Follow-up appointments, prescriptions, and submitting/tracking the insurance claims.`, 'health', 'high', 0, 30, ['schedule']],
  ];
}

/** Courses, programs, school enrollment. */
export function enrollment(s: string): T[] {
  return [
    ['research', `Research programs and requirements for ${s}`, `Compare programs, deadlines, costs and prerequisites; talk to people who've done it.`, 'education', 'high', -90, -60],
    ['apply', `Apply with all required documents`, `Applications, transcripts, references and test scores — submitted before the deadline with copies kept.`, 'education', 'critical', -60, -30, ['research']],
    ['funding', `Sort funding, aid or payment plans`, `Scholarships, aid applications and payment schedules have their own deadlines, usually earlier than you think.`, 'finance', 'high', -45, -14, ['research']],
    ['confirm', `Accept, register and confirm the start`, `Accept the offer, register for the schedule, and complete any orientation requirements.`, 'education', 'critical', -14, 0, ['apply']],
    ['logistics', `Sort day-one logistics`, `Transport or parking, materials and equipment, and the calendar for the term.`, 'education', 'medium', -14, 7, ['confirm']],
  ];
}

/** Legal processes. */
export function legal(s: string): T[] {
  return [
    ['collect', `Collect every document related to ${s}`, `Contracts, correspondence, records and evidence — organized chronologically before anyone bills you by the hour.`, 'legal', 'critical', 0, 14],
    ['advice', `Get qualified legal advice`, `A focused consultation with the documents prepared; understand your options, costs and deadlines.`, 'legal', 'high', 7, 30, ['collect']],
    ['file', `File / execute the required paperwork`, `Court filings, notarizations or registrations done correctly the first time — rejected filings cost weeks.`, 'legal', 'critical', 14, 45, ['advice']],
    ['deadlines', `Calendar every legal deadline`, `Response windows, hearing dates and limitation periods, with reminders well ahead of each.`, 'legal', 'high', 14, 60, ['file']],
    ['records', `Keep the complete record`, `Everything filed and received, stored where you can produce it years later.`, 'legal', 'medium', 30, 90],
  ];
}

/** Job and career transitions. */
export function career(s: string): T[] {
  return [
    ['documents', `Update your professional documents for ${s}`, `Résumé, portfolio and profiles current and consistent; references warned and willing.`, 'employment', 'high', -30, -14],
    ['process', `Work the process: applications, interviews, negotiation`, `Track every application and conversation; negotiate before accepting — leverage disappears after.`, 'employment', 'critical', -30, 0, ['documents']],
    ['transition', `Handle the transition professionally`, `Proper notice, clean handover, and exit paperwork (final pay, unused leave, references) in writing.`, 'employment', 'critical', -14, 7],
    ['money', `Update pay, benefits and retirement contributions`, `New direct deposit, benefit elections within their windows, and retirement contributions restarted.`, 'finance', 'high', 0, 30, ['transition']],
    ['tax', `Check the tax withholding consequences`, `Mid-year changes routinely under- or over-withhold — check and adjust.`, 'tax', 'medium', 0, 60, ['money']],
  ];
}

/** Home improvement projects. */
export function homeProject(s: string, permits: boolean): T[] {
  const t: T[] = [
    ['scope', `Fix the scope and budget for ${s}`, `Written scope, itemized budget, and 15–20% contingency — every later decision points back here.`, 'finance', 'critical', -45, -30],
    ['quotes', `Get quotes / plan the work`, `Three comparable quotes from licensed, insured people — or a realistic DIY plan with materials list.`, 'legal', 'high', -30, -14, ['scope']],
    ['insurer', `Check your home insurance implications`, `Significant work can need disclosure or a rider; the finished value may change the policy.`, 'insurance', 'medium', -21, -7],
    ['execute', `Schedule and oversee the work`, `Milestone-based payments, progress checks, and snag list before final payment.`, 'housing', 'high', 0, 60, ['quotes']],
  ];
  if (permits) t.splice(2, 0, ['permits', `Get the required permits`, `Structural, electrical and plumbing work usually needs municipal permits; unpermitted work resurfaces at sale time.`, 'legal', 'critical', -30, -7, ['scope']]);
  return t;
}

/** Financial setups and changes. */
export function finance(s: string): T[] {
  return [
    ['assess', `Assess your current position for ${s}`, `Numbers on paper: balances, rates, terms, obligations. Decisions improve when the facts are in one place.`, 'finance', 'high', 0, 14],
    ['compare', `Compare options and decide`, `Providers, rates, fees and exit terms compared like-for-like before committing.`, 'finance', 'high', 7, 30, ['assess']],
    ['paperwork', `Complete the paperwork and switch`, `Applications, transfers and account changes executed and confirmed in writing.`, 'finance', 'critical', 21, 45, ['compare']],
    ['update', `Update autopays, beneficiaries and records`, `Everything pointing at the old arrangement — payments, deposits, beneficiaries — repointed at the new one.`, 'finance', 'high', 30, 60, ['paperwork']],
    ['verify', `Verify the first full cycle`, `Check the first statement/payment cycle end-to-end; this is where setup errors surface.`, 'finance', 'medium', 45, 90, ['update']],
  ];
}

/** Care arrangements (family members, health situations, habits). */
export function care(s: string): T[] {
  return [
    ['assess', `Assess the needs and situation for ${s}`, `An honest inventory of needs, capabilities, and what support already exists.`, 'health', 'critical', 0, 14],
    ['providers', `Find and vet providers or programs`, `Compare options, check references and credentials, and visit before committing.`, 'health', 'high', 7, 30, ['assess']],
    ['legal_docs', `Put the legal documents in place`, `Consents, powers of attorney, or care agreements — the paperwork that lets you act when needed.`, 'legal', 'high', 14, 60, ['assess']],
    ['funding', `Sort funding, benefits and insurance`, `What insurance covers, what benefits exist, and what you'll pay — applications in early.`, 'government', 'high', 14, 60, ['assess']],
    ['schedule', `Set the schedule and review rhythm`, `Who does what, when — and a regular check that the arrangement still fits the need.`, 'health', 'medium', 30, 90, ['providers']],
  ];
}

/** Hobbies, classes, memberships. */
export function hobby(s: string): T[] {
  return [
    ['research', `Choose where and how to start ${s}`, `Classes, clubs or self-taught — compare cost, schedule and level; ask to trial before committing.`, 'education', 'high', -14, 0],
    ['gear', `Get the starter gear or supplies`, `Buy the beginner tier, borrow or rent where possible — upgrade only once you know you'll stick with it.`, 'finance', 'medium', -14, 7],
    ['signup', `Sign up and handle the paperwork`, `Membership, waivers and payment schedule; note the cancellation terms.`, 'education', 'high', -7, 7, ['research']],
    ['schedule', `Protect the time in your calendar`, `A recurring slot you defend — the habit is the actual project.`, 'education', 'medium', 0, 21, ['signup']],
  ];
}

/** Licences and certifications (drone, scuba, pilot, hunting…). */
export function licence(s: string, authority: string): T[] {
  return [
    ['requirements', `Learn the legal requirements for ${s}`, `Age, training hours, exams, and where it's valid — from the authority's current official source.`, 'government', 'high', -30, -14],
    ['training', `Complete the required training or study`, `Book the course or study program and put the hours in before the exam.`, 'education', 'high', -30, 0, ['requirements']],
    ['exam', `Pass the exam / assessment and apply`, `Sit the test, submit the application with documents and fees.`, 'government', 'critical', 0, 14, ['training'], ['ID', 'Training certificate', 'Fee payment']],
    ['maintain', `Note renewal dates and usage rules`, `Renewal cycles, logbooks and where/how you may legally use it — calendar the renewal now.`, 'government', 'low', 14, 60, ['exam']],
  ];
}

/** Digital projects (content, accounts, tech setups). */
export function digital(s: string): T[] {
  return [
    ['plan', `Plan the setup for ${s}`, `What you're making, which platform/tools, and the naming that you'll live with.`, 'utilities', 'high', -14, 0],
    ['setup', `Set up accounts, tools and equipment`, `Accounts registered, tools configured, and the workspace or equipment ready.`, 'utilities', 'critical', 0, 14, ['plan']],
    ['security', `Lock down security and ownership`, `Unique passwords, 2FA, recovery emails you control, and clarity on who owns what.`, 'utilities', 'high', 0, 14, ['setup']],
    ['launch', `Publish / go live and set the rhythm`, `Ship the first thing and set a sustainable schedule; backups and analytics from day one.`, 'utilities', 'medium', 14, 45, ['setup']],
  ];
}

/** Lost/stolen documents, cards, devices, identity. */
export function lossRecovery(s: string): T[] {
  return [
    ['report', `Report ${s} to the police / issuing authority`, `The report number unlocks replacements and disputes — file it first, even for small losses.`, 'government', 'critical', 0, 2],
    ['block', `Block, freeze and lock everything exposed`, `Cards cancelled, accounts frozen, devices remotely locked, passwords rotated — within hours, not days.`, 'finance', 'critical', 0, 2],
    ['replace', `Order replacements`, `Replacement documents/cards/devices, with the police report attached where it speeds things up.`, 'government', 'critical', 2, 21, ['report']],
    ['monitor', `Monitor for fraud for the next 60 days`, `Statements, credit report and unfamiliar account activity — dispute anything unrecognized immediately.`, 'finance', 'high', 2, 60, ['block']],
  ];
}

/** Home emergencies: fire, flood, burglary, disaster. */
export function emergency(s: string): T[] {
  return [
    ['secure', `Make the property safe and prevent further damage`, `Safety first, then mitigation (board up, shut off water/power, dry out) — insurers expect reasonable mitigation.`, 'housing', 'critical', 0, 2],
    ['document', `Document everything before touching anything`, `Photos, video and an inventory of damage/losses — the claim is built on this evidence.`, 'legal', 'critical', 0, 3],
    ['claim', `Open the insurance claim`, `Notify the insurer immediately, get the claim number, and log every conversation.`, 'insurance', 'critical', 0, 14, ['document']],
    ['restore', `Arrange repairs and restoration`, `Approved contractors, itemized quotes, and insurer sign-off before major work.`, 'housing', 'high', 7, 60, ['claim']],
    ['prevent', `Reduce the odds of a repeat`, `Alarms, detectors, locks, drainage — whatever addresses this event's root cause.`, 'housing', 'medium', 30, 90],
  ];
}

/** Athletic events and training goals. */
export function sport(s: string): T[] {
  return [
    ['register', `Register for ${s}`, `Spots and early-bird pricing go first; registration usually requires a waiver and sometimes a medical certificate.`, 'social', 'critical', -120, -90],
    ['medical', `Get the medical green light`, `A check-up appropriate to the effort, especially if you're new to this volume of training.`, 'health', 'high', -120, -90],
    ['train', `Follow a structured training plan`, `A progressive plan with rest weeks; the plan is what gets you to the start line uninjured.`, 'health', 'critical', -90, -7, ['medical']],
    ['gear', `Sort gear, nutrition and logistics`, `Nothing new on event day — gear and nutrition tested in training; travel and bib pickup planned.`, 'travel', 'medium', -30, -7, ['register']],
  ];
}

/** Renting a home. */
export function renting(s: string): T[] {
  return [
    ['search', `Search and view places for ${s}`, `Set the budget ceiling (rent plus utilities plus insurance), shortlist, and view with a checklist.`, 'housing', 'critical', -60, -30],
    ['apply', `Apply with your documents ready`, `Income proof, references and ID ready to go — good places go to the first complete application.`, 'housing', 'critical', -30, -14, ['search'], ['Income proof', 'References', 'ID']],
    ['lease', `Read and sign the lease carefully`, `Term, notice period, deposit terms and what you're liable for — photographed condition report before moving in.`, 'legal', 'critical', -14, 0, ['apply']],
    ['insurance', `Get renter's/contents insurance`, `Often required by the lease; cheap relative to what it covers.`, 'insurance', 'high', -14, 0, ['lease']],
    ['setup', `Set up utilities and services`, `Electricity, internet and anything not included in rent, active from day one.`, 'utilities', 'high', -14, 7, ['lease']],
  ];
}

/** Decade birthdays and age milestones. */
export function birthday(age: number, financeNote: string, healthNote: string): T[] {
  return [
    ['celebrate', `Plan the ${age}th birthday celebration`, `However you mark it — party, trip or dinner — decide and book it early enough to do it well.`, 'social', 'medium', -45, -7],
    ['documents', `Check documents and renewals around this birthday`, `IDs, passports, licences and any age-linked registrations that expire or change around this age.`, 'government', 'medium', -30, 30],
    ['money', `Do the ${age}-year financial checkpoint`, financeNote, 'finance', 'high', -14, 60],
    ['health', `Do the age-appropriate health checks`, healthNote, 'health', 'high', 0, 90],
  ];
}
