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
 * generate real plans — tasks with checkable sub-steps, plus intake
 * questions that gate optional tasks — from one-line event definitions.
 * Deeply-authored (featured) events don't use this.
 */

/** A task within a pack, ids local to the pack (prefixed per-event by E()). */
interface PackTask {
  id: string;
  title: string;
  description: string;
  domain: Domain;
  priority: Priority;
  start: number;
  due: number;
  steps: string[];
  deps?: string[];
  docs?: string[];
}

export interface Pack {
  tasks: PackTask[];
  /** Questions whose gatesTasks reference local task ids. */
  questions: IntakeQuestion[];
}

function t(
  id: string,
  title: string,
  description: string,
  domain: Domain,
  priority: Priority,
  start: number,
  due: number,
  steps: string[],
  extra?: { deps?: string[]; docs?: string[] }
): PackTask {
  return { id, title, description, domain, priority, start, due, steps, ...extra };
}

export interface EventSpec {
  id: string;
  name: string;
  emoji: string;
  category: EventCategory;
  pack: Pack;
  phrases: string[];
  keywords: string[];
  summary?: string;
  /** Custom questions come before pack questions; total is capped at 5. */
  questions?: IntakeQuestion[];
  featured?: boolean;
  isMilestone?: LifeEventTemplate['isMilestone'];
}

const MAX_QUESTIONS = 5;

export function E(spec: EventSpec): LifeEventTemplate {
  const localIds = new Set(spec.pack.tasks.map((task) => task.id));
  const prefix = (id: string) => (localIds.has(id) ? `${spec.id}.${id}` : id);

  const tasks: TaskTemplate[] = spec.pack.tasks.map((task) => ({
    id: `${spec.id}.${task.id}`,
    title: task.title,
    description: task.description,
    domain: task.domain,
    priority: task.priority,
    startOffsetDays: task.start,
    dueOffsetDays: task.due,
    steps: task.steps,
    dependsOn: task.deps?.map(prefix),
    documents: task.docs,
  }));

  const custom: IntakeQuestion[] = spec.questions ? [...spec.questions] : [];
  if (!custom.some((q) => q.kind === 'date')) {
    custom.unshift({ id: 'event_date', prompt: 'When is (was) it?', kind: 'date' });
  }
  const packQs = spec.pack.questions.map((q) => ({
    ...q,
    gatesTasks: q.gatesTasks?.map(prefix),
  }));
  const questions = [...custom, ...packQs].slice(0, MAX_QUESTIONS);

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
    tasks,
  };
}

/* ============ archetype packs ============ */

/** Parties and ceremonies. */
export function celebration(s: string): Pack {
  return {
    questions: [
      { id: 'guest_count', prompt: 'Roughly how many guests?', kind: 'choice', choices: ['Under 15', '15–40', '40–100', '100+'] },
      { id: 'out_of_town_guests', prompt: 'Are guests traveling from out of town?', kind: 'boolean', gatesTasks: ['lodging'] },
      { id: 'want_photos', prompt: 'Do you want a photographer / videographer?', kind: 'boolean', gatesTasks: ['photographer'] },
    ],
    tasks: [
      t('plan', `Set the date, budget and guest list for ${s}`, `Everything else hangs off these three decisions — lock them first.`, 'finance', 'critical', -60, -45,
        ['Date fixed with key people', 'Budget number agreed', 'Guest list drafted']),
      t('venue', `Book the venue or prepare the space`, `Popular venues and weekends book out far ahead; confirm capacity, deposit and cancellation terms in writing.`, 'social', 'high', -45, -30,
        ['Venue shortlisted', 'Availability confirmed', 'Deposit paid', 'Cancellation terms saved'], { deps: ['plan'] }),
      t('invites', `Send invitations and track RSVPs`, `Send early enough for people to plan; keep one list of RSVPs, dietary needs and plus-ones.`, 'social', 'high', -30, -14,
        ['Invitations sent', 'RSVP tracker set up', 'Dietary needs collected'], { deps: ['venue'] }),
      t('catering', `Arrange food, drinks and the cake`, `Confirm final headcount with caterers about a week out; ask guests about allergies before fixing the menu.`, 'social', 'high', -21, -7,
        ['Menu chosen', 'Caterer / cooking plan booked', 'Cake ordered', 'Final headcount confirmed'], { deps: ['plan'] }),
      t('program', `Plan the program, music and decorations`, `Decide the running order, who speaks, and how the space will look and sound.`, 'social', 'medium', -21, -7,
        ['Running order written', 'Music / playlist sorted', 'Decorations bought']),
      t('lodging', `Arrange lodging for out-of-town guests`, `Block hotel rooms or line up stays near the venue, and share arrival logistics with travelers.`, 'travel', 'medium', -30, -14,
        ['Room block / stays arranged', 'Directions shared with guests'], { deps: ['venue'] }),
      t('photographer', `Book the photographer / videographer`, `Good ones book out months ahead — confirm the shot list and timings in writing.`, 'social', 'medium', -45, -21,
        ['Photographer booked', 'Shot list agreed', 'Timings confirmed'], { deps: ['plan'] }),
      t('runsheet', `Confirm all vendors and write the day-of run sheet`, `One page: times, contacts, deliveries, and who is responsible for what.`, 'social', 'medium', -7, -1,
        ['All vendors reconfirmed', 'Run sheet written', 'Helpers briefed'], { deps: ['invites'] }),
    ],
  };
}

/** Children's parties — celebration plus kid-specific safety. */
export function kidParty(s: string): Pack {
  return {
    questions: [
      { id: 'kid_age', prompt: 'How old is the birthday kid turning?', kind: 'text' },
      { id: 'guest_count', prompt: 'Roughly how many kids?', kind: 'choice', choices: ['Under 8', '8–15', '15–25', '25+'] },
      { id: 'want_entertainer', prompt: 'Do you want an entertainer (magician, face painter…)?', kind: 'boolean', gatesTasks: ['entertainer'] },
    ],
    tasks: [
      t('plan', `Pick the date, theme and budget for ${s}`, `Check the school and sports calendar for clashes, agree the guest list with your kid, and set the budget.`, 'finance', 'critical', -45, -30,
        ['Date checked against school calendar', 'Theme picked together', 'Budget set']),
      t('venue', `Book the venue or plan the home setup`, `Party venues for popular weekend slots go fast; for home parties plan the space, weather backup and seating.`, 'social', 'high', -30, -21,
        ['Venue booked / space planned', 'Weather backup decided'], { deps: ['plan'] }),
      t('invites', `Send invitations and track RSVPs`, `Via the class group or parents directly; collect RSVPs and each child's pickup arrangements.`, 'social', 'high', -21, -10,
        ['Invitations sent', 'RSVPs tracked', 'Pickup arrangements noted'], { deps: ['venue'] }),
      t('allergies', `Collect allergies and dietary needs from parents`, `Nut allergies and intolerances are common — ask every parent explicitly, and plan the menu around the answers.`, 'health', 'critical', -14, -7,
        ['Every parent asked', 'Allergy list written', 'Menu adjusted'], { deps: ['invites'] }),
      t('food_cake', `Order the cake and plan food and favors`, `Order the cake a week ahead; keep food simple and label anything allergen-relevant.`, 'social', 'high', -10, -3,
        ['Cake ordered', 'Food planned', 'Party favors bought'], { deps: ['allergies'] }),
      t('entertainer', `Book the entertainer`, `Confirm the act, timing, space needs and payment; have a backup activity in case of no-show.`, 'social', 'medium', -30, -14,
        ['Entertainer booked', 'Timing confirmed', 'Backup activity ready'], { deps: ['plan'] }),
      t('activities', `Plan activities and supervision`, `Age-appropriate games, enough adults for supervision, and a first-aid kit on hand.`, 'social', 'medium', -14, -2,
        ['Games planned', 'Adult helpers confirmed', 'First-aid kit ready']),
    ],
  };
}

/** Trips; abroad adds documents & insurance. */
export function trip(s: string, abroad: boolean): Pack {
  const tasks: PackTask[] = [
    t('plan', `Set dates, budget and destination details for ${s}`, `Fix the dates with everyone traveling, set the budget, and check seasonal factors (weather, peak pricing, closures).`, 'travel', 'critical', -60, -45,
      ['Dates fixed with all travelers', 'Budget set', 'Destination research done']),
    t('book', `Lock in flights, stays and transport`, `Book with names matching ID documents exactly, and keep confirmations in one place.`, 'travel', 'critical', -45, -21,
      ['Flight tickets booked', 'Hotel / stay confirmed', 'Airport transfers arranged', 'Confirmations saved in one place'], { deps: ['plan'] }),
    t('activities', `Reserve key activities and local transport`, `The things that sell out — tours, restaurants, rental cars, park passes — get booked now, the rest stays flexible.`, 'travel', 'medium', -21, -7,
      ['Must-do tours booked', 'Tour guide confirmed', 'Restaurant reservations made', 'Local transport planned'], { deps: ['book'] }),
    t('home_prep', `Prepare the home front`, `Mail hold, plants, pets, deliveries paused, and someone with a key who knows you're away.`, 'housing', 'medium', -14, -1,
      ['Mail held / deliveries paused', 'Plants & pets covered', 'Key left with a trusted person']),
  ];
  if (abroad) {
    tasks.splice(1, 0,
      t('docs', `Check passports, visas and entry rules`, `Six months passport validity, visas or e-authorizations for every traveler, and entry requirements for each country on the route.`, 'government', 'critical', -75, -30,
        ['Passport validity checked (6+ months)', 'Visas / e-authorizations obtained', 'Entry rules checked per country'], { deps: ['plan'] }),
      t('insurance', `Get travel and medical insurance`, `Domestic health coverage usually stops at the border — cover medical, cancellation and baggage.`, 'insurance', 'high', -30, -14,
        ['Policies compared', 'Insurance purchased', 'Policy saved offline'], { deps: ['plan'] }));
  }
  return {
    questions: [
      { id: 'traveler_count', prompt: 'How many people are traveling?', kind: 'choice', choices: ['1', '2', '3–4', '5+'] },
      { id: 'renting_car', prompt: 'Will you rent a car there?', kind: 'boolean', gatesTasks: ['car_rental'] },
      { id: 'work_handover', prompt: 'Do you need to hand over work before leaving?', kind: 'boolean', gatesTasks: ['work_prep'] },
    ],
    tasks: [
      ...tasks,
      t('car_rental', `Arrange the rental car`, `Book ahead for better rates; check licence requirements${abroad ? ' (an International Driving Permit may be required)' : ''} and what the insurance actually covers.`, 'travel', 'medium', -30, -7,
        ['Rental car booked', abroad ? 'International Driving Permit obtained' : 'Licence requirements checked', 'Rental insurance sorted'], { deps: ['plan'] }),
      t('work_prep', `Hand over work and set your out-of-office`, `Brief whoever covers for you, close what can be closed, and set expectations for what waits.`, 'employment', 'medium', -7, -1,
        ['Coverage briefed', 'Out-of-office set', 'Urgent items closed']),
    ],
  };
}

/** Significant purchases. */
export function purchase(s: string, opts?: { register?: boolean; insure?: boolean }): Pack {
  const tasks: PackTask[] = [
    t('research', `Research and compare options for ${s}`, `Set requirements, compare models/providers and total cost of ownership, and read the fine print before deciding.`, 'finance', 'high', -30, -14,
      ['Requirements listed', 'Options compared', 'Reviews read']),
    t('budget', `Confirm the budget and how you'll pay`, `Cash, financing or lease — settle it before negotiating, and leave room for the costs that follow the purchase.`, 'finance', 'high', -21, -7,
      ['Budget ceiling set', 'Payment method decided', 'Follow-on costs estimated'], { deps: ['research'] }),
    t('buy', `Complete the purchase and keep the paperwork`, `Invoice, warranty registration and receipts filed where you can find them — warranty claims die on missing paperwork.`, 'finance', 'critical', 0, 7,
      ['Purchase completed', 'Invoice / receipt filed', 'Warranty registered'], { deps: ['budget'] }),
    t('setup', `Set up, install and learn the essentials`, `Do the setup properly once: installation, safety basics, and any manufacturer registration for recalls.`, 'housing', 'medium', 0, 21,
      ['Installed / set up', 'Safety basics learned', 'Manufacturer registration done'], { deps: ['buy'] }),
  ];
  if (opts?.insure) tasks.push(t('insure', `Insure it or add it to an existing policy`, `Check whether home/contents coverage already applies or a rider is needed.`, 'insurance', 'high', 0, 14,
    ['Existing coverage checked', 'Policy / rider in place'], { deps: ['buy'] }));
  if (opts?.register) tasks.push(t('register', `Register it with the relevant authority`, `Registration deadlines are typically 10–30 days with late fees after.`, 'government', 'high', 0, 30,
    ['Registration submitted', 'Certificate received'], { deps: ['buy'] }));
  return {
    questions: [
      { id: 'condition', prompt: 'New or used?', kind: 'choice', choices: ['New', 'Used', 'Refurbished'] },
      { id: 'financing_needed', prompt: 'Will you finance it with a loan?', kind: 'boolean', gatesTasks: ['financing'] },
    ],
    tasks: [
      ...tasks,
      t('financing', `Arrange the financing`, `Compare loan offers (dealer / bank / credit union), check the total cost over the term, and set up autopay.`, 'finance', 'high', -14, 7,
        ['Loan offers compared', 'Financing approved', 'Autopay set up'], { deps: ['budget'] }),
    ],
  };
}

/** Government / institutional applications. */
export function application(s: string, authority: string): Pack {
  return {
    questions: [
      { id: 'first_time', prompt: 'Is this your first time applying?', kind: 'boolean' },
      { id: 'want_help', prompt: 'Do you want professional help (consultant / lawyer)?', kind: 'boolean', gatesTasks: ['helper'] },
    ],
    tasks: [
      t('eligibility', `Confirm eligibility and requirements for ${s}`, `Read the current official requirements — rules and fees change, and secondhand advice ages badly.`, 'government', 'critical', -30, -21,
        ['Official requirements read', 'Eligibility confirmed', 'Fees noted']),
      t('documents', `Gather the required documents`, `Work from the official checklist; order anything with lead time (certificates, translations, photos) first.`, 'government', 'critical', -21, -7,
        ['Official checklist copied', 'Long-lead documents ordered', 'Everything gathered and scanned'], { deps: ['eligibility'] }),
      t('helper', `Engage the consultant / lawyer`, `Verify credentials and fees in writing before sharing documents; agree who does what.`, 'legal', 'high', -21, -7,
        ['Credentials verified', 'Engagement agreed in writing'], { deps: ['eligibility'] }),
      t('submit', `Complete and submit the application`, `Answer exactly and consistently with your documents; keep a full copy of what you submitted.`, 'government', 'critical', 0, 7,
        ['Forms completed', 'Fees paid', 'Submitted and copy kept'], { deps: ['documents'], docs: ['Application forms', 'Supporting documents', 'Fee payment'] }),
      t('track', `Track status and respond to requests fast`, `Requests for more information have short response windows — check the portal or mail regularly.`, 'government', 'high', 7, 60,
        ['Status checks scheduled', 'All requests answered on time'], { deps: ['submit'] }),
      t('store', `Store the result with your key documents`, `The approval/licence/certificate joins your permanent records; note any renewal date.`, 'legal', 'low', 30, 90,
        ['Result filed safely', 'Renewal date calendared'], { deps: ['track'] }),
    ],
  };
}

/** Medical procedures and treatments. */
export function medical(s: string): Pack {
  return {
    questions: [
      { id: 'employed', prompt: 'Do you need time off work for this?', kind: 'boolean', gatesTasks: ['work'] },
      { id: 'hospital_stay', prompt: 'Will it involve a hospital stay or heavy recovery?', kind: 'boolean', gatesTasks: ['aftercare'] },
    ],
    tasks: [
      t('consult', `Get the consultation and referral for ${s}`, `Understand options, risks and recovery time; get the referral chain your insurer requires.`, 'health', 'critical', -30, -14,
        ['Consultation done', 'Options & risks understood', 'Referral obtained']),
      t('approval', `Confirm insurance coverage / pre-approval`, `Pre-authorization requirements are strict — confirm in writing what is covered and what you'll owe.`, 'insurance', 'critical', -21, -7,
        ['Coverage confirmed in writing', 'Pre-authorization obtained', 'Out-of-pocket estimated'], { deps: ['consult'] }),
      t('schedule', `Schedule it and follow the prep instructions`, `Book the date, arrange transport home if needed, and follow pre-procedure instructions exactly.`, 'health', 'critical', -14, -1,
        ['Date booked', 'Transport home arranged', 'Prep instructions followed'], { deps: ['approval'] }),
      t('work', `Arrange time off and support`, `Sick leave or accommodations with your employer, and help at home for the recovery window.`, 'employment', 'high', -14, -1,
        ['Leave approved', 'Home support arranged']),
      t('aftercare', `Arrange post-discharge care`, `Who picks you up, who stays with you, and what equipment or medications need to be home before you are.`, 'health', 'high', -7, 7,
        ['Discharge plan understood', 'Helper lined up', 'Equipment & meds at home'], { deps: ['schedule'] }),
      t('recovery', `Manage recovery, follow-ups and claims`, `Follow-up appointments, prescriptions, and submitting/tracking the insurance claims.`, 'health', 'high', 0, 30,
        ['Follow-ups booked', 'Prescriptions filled', 'Claims submitted'], { deps: ['schedule'] }),
    ],
  };
}

/** Courses, programs, school enrollment. */
export function enrollment(s: string): Pack {
  return {
    questions: [
      { id: 'need_funding', prompt: 'Do you need funding, aid or a payment plan?', kind: 'boolean', gatesTasks: ['funding'] },
      { id: 'relocating_for_it', prompt: 'Does it involve moving or new housing?', kind: 'boolean', gatesTasks: ['housing'] },
    ],
    tasks: [
      t('research', `Research programs and requirements for ${s}`, `Compare programs, deadlines, costs and prerequisites; talk to people who've done it.`, 'education', 'high', -90, -60,
        ['Programs compared', 'Deadlines listed', 'Prerequisites checked']),
      t('apply', `Apply with all required documents`, `Applications, transcripts, references and test scores — submitted before the deadline with copies kept.`, 'education', 'critical', -60, -30,
        ['Documents gathered', 'Application submitted', 'Copies kept'], { deps: ['research'] }),
      t('funding', `Sort funding, aid or payment plans`, `Scholarships, aid applications and payment schedules have their own deadlines, usually earlier than you think.`, 'finance', 'high', -45, -14,
        ['Aid options researched', 'Applications submitted', 'Payment plan set'], { deps: ['research'] }),
      t('housing', `Sort housing and transport`, `Housing near the program, or the commute plan — applications and waitlists early.`, 'housing', 'high', -60, -14,
        ['Housing applied for / secured', 'Transport planned'], { deps: ['research'] }),
      t('confirm', `Accept, register and confirm the start`, `Accept the offer, register for the schedule, and complete any orientation requirements.`, 'education', 'critical', -14, 0,
        ['Offer accepted', 'Registered for schedule', 'Orientation completed'], { deps: ['apply'] }),
      t('logistics', `Sort day-one logistics`, `Materials and equipment, and the calendar for the term.`, 'education', 'medium', -14, 7,
        ['Materials bought', 'Calendar blocked'], { deps: ['confirm'] }),
    ],
  };
}

/** Legal processes. */
export function legal(s: string): Pack {
  return {
    questions: [
      { id: 'court_involved', prompt: 'Is a court or formal hearing involved?', kind: 'boolean', gatesTasks: ['court_prep'] },
    ],
    tasks: [
      t('collect', `Collect every document related to ${s}`, `Contracts, correspondence, records and evidence — organized chronologically before anyone bills you by the hour.`, 'legal', 'critical', 0, 14,
        ['All documents located', 'Organized chronologically', 'Copies made']),
      t('advice', `Get qualified legal advice`, `A focused consultation with the documents prepared; understand your options, costs and deadlines.`, 'legal', 'high', 7, 30,
        ['Adviser found', 'Consultation done', 'Options & costs understood'], { deps: ['collect'] }),
      t('file', `File / execute the required paperwork`, `Court filings, notarizations or registrations done correctly the first time — rejected filings cost weeks.`, 'legal', 'critical', 14, 45,
        ['Paperwork prepared', 'Filed / executed', 'Confirmation received'], { deps: ['advice'] }),
      t('court_prep', `Prepare for the hearing`, `Know the date, what to bring, and what you'll be asked; arrange representation or prepare to speak yourself.`, 'legal', 'critical', 14, 60,
        ['Hearing date confirmed', 'Evidence prepared', 'Representation arranged'], { deps: ['advice'] }),
      t('deadlines', `Calendar every legal deadline`, `Response windows, hearing dates and limitation periods, with reminders well ahead of each.`, 'legal', 'high', 14, 60,
        ['All deadlines listed', 'Reminders set'], { deps: ['file'] }),
      t('records', `Keep the complete record`, `Everything filed and received, stored where you can produce it years later.`, 'legal', 'medium', 30, 90,
        ['Records filed', 'Storage location noted']),
    ],
  };
}

/** Job and career transitions. */
export function career(s: string): Pack {
  return {
    questions: [
      { id: 'relocating_for_it', prompt: 'Does it involve relocating?', kind: 'boolean', gatesTasks: ['relocation'] },
      { id: 'stage', prompt: 'Where are you in the process?', kind: 'choice', choices: ['Just exploring', 'Applying / interviewing', 'Offer in hand', 'Already decided'] },
    ],
    tasks: [
      t('documents', `Update your professional documents for ${s}`, `Résumé, portfolio and profiles current and consistent; references warned and willing.`, 'employment', 'high', -30, -14,
        ['Résumé updated', 'Profiles updated', 'References confirmed']),
      t('process', `Work the process: applications, interviews, negotiation`, `Track every application and conversation; negotiate before accepting — leverage disappears after.`, 'employment', 'critical', -30, 0,
        ['Applications tracked', 'Interviews prepared', 'Offer negotiated'], { deps: ['documents'] }),
      t('transition', `Handle the transition professionally`, `Proper notice, clean handover, and exit paperwork (final pay, unused leave, references) in writing.`, 'employment', 'critical', -14, 7,
        ['Notice given properly', 'Handover completed', 'Exit paperwork collected']),
      t('relocation', `Plan the relocation`, `Housing at the destination, moving logistics, and what the employer contributes — in writing.`, 'housing', 'high', -30, 14,
        ['Employer contribution confirmed', 'Housing plan made', 'Move scheduled'], { deps: ['process'] }),
      t('money', `Update pay, benefits and retirement contributions`, `New direct deposit, benefit elections within their windows, and retirement contributions restarted.`, 'finance', 'high', 0, 30,
        ['Direct deposit set', 'Benefits elected in window', 'Retirement contributions restarted'], { deps: ['transition'] }),
      t('tax', `Check the tax withholding consequences`, `Mid-year changes routinely under- or over-withhold — check and adjust.`, 'tax', 'medium', 0, 60,
        ['Withholding reviewed', 'Adjustment filed if needed'], { deps: ['money'] }),
    ],
  };
}

/** Home improvement projects. */
export function homeProject(s: string, permits: boolean): Pack {
  const tasks: PackTask[] = [
    t('scope', `Fix the scope and budget for ${s}`, `Written scope, itemized budget, and 15–20% contingency — every later decision points back here.`, 'finance', 'critical', -45, -30,
      ['Scope written down', 'Budget itemized', 'Contingency added']),
    t('quotes', `Get quotes / plan the work`, `Three comparable quotes from licensed, insured people — or a realistic DIY plan with materials list.`, 'legal', 'high', -30, -14,
      ['Three quotes collected', 'Licences & insurance verified', 'Contract / plan finalized'], { deps: ['scope'] }),
    t('insurer', `Check your home insurance implications`, `Significant work can need disclosure or a rider; the finished value may change the policy.`, 'insurance', 'medium', -21, -7,
      ['Insurer notified', 'Rider added if needed']),
    t('execute', `Schedule and oversee the work`, `Milestone-based payments, progress checks, and snag list before final payment.`, 'housing', 'high', 0, 60,
      ['Schedule agreed', 'Progress checked at milestones', 'Snag list cleared before final payment'], { deps: ['quotes'] }),
  ];
  if (permits) tasks.splice(2, 0, t('permits', `Get the required permits`, `Structural, electrical and plumbing work usually needs municipal permits; unpermitted work resurfaces at sale time.`, 'legal', 'critical', -30, -7,
    ['Permit requirements checked', 'Application submitted', 'Permit received'], { deps: ['scope'] }));
  return {
    questions: [
      { id: 'moving_out_during', prompt: 'Will you move out during the work?', kind: 'boolean', gatesTasks: ['temp_housing'] },
      { id: 'financing_needed', prompt: 'Do you need financing for it?', kind: 'boolean', gatesTasks: ['financing'] },
    ],
    tasks: [
      ...tasks,
      t('temp_housing', `Arrange temporary housing`, `Where you'll live during the work, for how long, and what it does to the budget.`, 'housing', 'high', -21, 0,
        ['Temporary housing booked', 'Dates aligned with schedule'], { deps: ['scope'] }),
      t('financing', `Arrange the financing`, `Line of credit, renovation loan or savings — confirmed before signing the payment schedule.`, 'finance', 'high', -30, -7,
        ['Options compared', 'Financing confirmed'], { deps: ['scope'] }),
    ],
  };
}

/** Financial setups and changes. */
export function finance(s: string): Pack {
  return {
    questions: [
      { id: 'joint_decision', prompt: 'Is a partner / family member part of this decision?', kind: 'boolean' },
      { id: 'want_advisor', prompt: 'Do you want professional financial advice?', kind: 'boolean', gatesTasks: ['advisor'] },
    ],
    tasks: [
      t('assess', `Assess your current position for ${s}`, `Numbers on paper: balances, rates, terms, obligations. Decisions improve when the facts are in one place.`, 'finance', 'high', 0, 14,
        ['Balances & rates listed', 'Obligations listed', 'Goal written down']),
      t('advisor', `Get professional advice`, `A fee-based adviser with the numbers prepared; understand recommendations and their costs.`, 'finance', 'high', 7, 30,
        ['Adviser chosen', 'Session done', 'Recommendations noted'], { deps: ['assess'] }),
      t('compare', `Compare options and decide`, `Providers, rates, fees and exit terms compared like-for-like before committing.`, 'finance', 'high', 7, 30,
        ['Options compared like-for-like', 'Decision made'], { deps: ['assess'] }),
      t('paperwork', `Complete the paperwork and switch`, `Applications, transfers and account changes executed and confirmed in writing.`, 'finance', 'critical', 21, 45,
        ['Applications completed', 'Transfers executed', 'Confirmations received'], { deps: ['compare'] }),
      t('update', `Update autopays, beneficiaries and records`, `Everything pointing at the old arrangement — payments, deposits, beneficiaries — repointed at the new one.`, 'finance', 'high', 30, 60,
        ['Autopays repointed', 'Beneficiaries updated', 'Records filed'], { deps: ['paperwork'] }),
      t('verify', `Verify the first full cycle`, `Check the first statement/payment cycle end-to-end; this is where setup errors surface.`, 'finance', 'medium', 45, 90,
        ['First statement checked', 'Errors resolved'], { deps: ['update'] }),
    ],
  };
}

/** Care arrangements (family members, health situations, habits). */
export function care(s: string): Pack {
  return {
    questions: [
      { id: 'family_shared', prompt: 'Will family members share the responsibility?', kind: 'boolean', gatesTasks: ['family_plan'] },
    ],
    tasks: [
      t('assess', `Assess the needs and situation for ${s}`, `An honest inventory of needs, capabilities, and what support already exists.`, 'health', 'critical', 0, 14,
        ['Needs written down', 'Existing support mapped', 'Gaps identified']),
      t('providers', `Find and vet providers or programs`, `Compare options, check references and credentials, and visit before committing.`, 'health', 'high', 7, 30,
        ['Options compared', 'References checked', 'Visit done'], { deps: ['assess'] }),
      t('family_plan', `Agree the family plan`, `Who does what, when, and how decisions get made — written down, so it survives stress.`, 'health', 'high', 7, 30,
        ['Responsibilities agreed', 'Schedule written', 'Decision process agreed'], { deps: ['assess'] }),
      t('legal_docs', `Put the legal documents in place`, `Consents, powers of attorney, or care agreements — the paperwork that lets you act when needed.`, 'legal', 'high', 14, 60,
        ['Documents identified', 'Signed & notarized', 'Copies distributed'], { deps: ['assess'] }),
      t('funding', `Sort funding, benefits and insurance`, `What insurance covers, what benefits exist, and what you'll pay — applications in early.`, 'government', 'high', 14, 60,
        ['Coverage checked', 'Benefit applications submitted', 'Budget set'], { deps: ['assess'] }),
      t('schedule', `Set the schedule and review rhythm`, `Who does what, when — and a regular check that the arrangement still fits the need.`, 'health', 'medium', 30, 90,
        ['Schedule running', 'Review dates set'], { deps: ['providers'] }),
    ],
  };
}

/** Hobbies, classes, memberships. */
export function hobby(s: string): Pack {
  return {
    questions: [
      { id: 'needs_equipment', prompt: 'Does it need equipment or gear?', kind: 'boolean', gatesTasks: ['gear'] },
      { id: 'commitment', prompt: 'How often do you plan to do it?', kind: 'choice', choices: ['Weekly', 'A few times a week', 'Monthly', 'Intensive burst'] },
    ],
    tasks: [
      t('research', `Choose where and how to start ${s}`, `Classes, clubs or self-taught — compare cost, schedule and level; ask to trial before committing.`, 'education', 'high', -14, 0,
        ['Options compared', 'Trial session done', 'Choice made']),
      t('gear', `Get the starter gear or supplies`, `Buy the beginner tier, borrow or rent where possible — upgrade only once you know you'll stick with it.`, 'finance', 'medium', -14, 7,
        ['Starter list made', 'Gear acquired']),
      t('signup', `Sign up and handle the paperwork`, `Membership, waivers and payment schedule; note the cancellation terms.`, 'education', 'high', -7, 7,
        ['Signed up', 'Waivers done', 'Cancellation terms noted'], { deps: ['research'] }),
      t('schedule', `Protect the time in your calendar`, `A recurring slot you defend — the habit is the actual project.`, 'education', 'medium', 0, 21,
        ['Recurring slot blocked', 'First month attended'], { deps: ['signup'] }),
    ],
  };
}

/** Licences and certifications (drone, scuba, pilot, hunting…). */
export function licence(s: string, authority: string): Pack {
  return {
    questions: [
      { id: 'training_needed', prompt: 'Is a training course required (vs. self-study)?', kind: 'boolean', gatesTasks: ['course'] },
    ],
    tasks: [
      t('requirements', `Learn the legal requirements for ${s}`, `Age, training hours, exams, and where it's valid — from the authority's current official source.`, 'government', 'high', -30, -14,
        ['Official requirements read', 'Costs & timeline noted']),
      t('course', `Book and complete the training course`, `Certified instructors and courses book out; complete the required hours before the exam.`, 'education', 'high', -30, -7,
        ['Course booked', 'Sessions completed', 'Completion certificate received'], { deps: ['requirements'] }),
      t('study', `Study for the exam / assessment`, `Official study materials and practice tests until passing comfortably.`, 'education', 'high', -30, 0,
        ['Materials obtained', 'Practice tests passed'], { deps: ['requirements'] }),
      t('exam', `Pass the exam and apply for the licence`, `Sit the test, submit the application with documents and fees.`, 'government', 'critical', 0, 14,
        ['Exam passed', 'Application submitted', 'Licence received'], { deps: ['study'], docs: ['ID', 'Training certificate', 'Fee payment'] }),
      t('maintain', `Note renewal dates and usage rules`, `Renewal cycles, logbooks and where/how you may legally use it — calendar the renewal now.`, 'government', 'low', 14, 60,
        ['Renewal date calendared', 'Usage rules noted'], { deps: ['exam'] }),
    ],
  };
}

/** Digital projects (content, accounts, tech setups). */
export function digital(s: string): Pack {
  return {
    questions: [
      { id: 'monetizing', prompt: 'Do you plan to earn money from it?', kind: 'boolean', gatesTasks: ['monetize'] },
    ],
    tasks: [
      t('plan', `Plan the setup for ${s}`, `What you're making, which platform/tools, and the naming that you'll live with.`, 'utilities', 'high', -14, 0,
        ['Concept written', 'Platform chosen', 'Name settled']),
      t('setup', `Set up accounts, tools and equipment`, `Accounts registered, tools configured, and the workspace or equipment ready.`, 'utilities', 'critical', 0, 14,
        ['Accounts registered', 'Tools configured', 'Equipment ready'], { deps: ['plan'] }),
      t('security', `Lock down security and ownership`, `Unique passwords, 2FA, recovery emails you control, and clarity on who owns what.`, 'utilities', 'high', 0, 14,
        ['2FA enabled everywhere', 'Recovery methods set', 'Ownership documented'], { deps: ['setup'] }),
      t('monetize', `Set up monetization and the tax basics`, `Payment accounts, platform monetization requirements, and a record-keeping habit for income tax.`, 'tax', 'medium', 14, 60,
        ['Payment account set up', 'Platform requirements met', 'Income records started'], { deps: ['setup'] }),
      t('launch', `Publish / go live and set the rhythm`, `Ship the first thing and set a sustainable schedule; backups and analytics from day one.`, 'utilities', 'medium', 14, 45,
        ['First release shipped', 'Schedule set', 'Backups running'], { deps: ['setup'] }),
    ],
  };
}

/** Lost/stolen documents, cards, devices, identity. */
export function lossRecovery(s: string): Pack {
  return {
    questions: [
      { id: 'happened_abroad', prompt: 'Did it happen while traveling abroad?', kind: 'boolean', gatesTasks: ['embassy'] },
    ],
    tasks: [
      t('report', `Report ${s} to the police / issuing authority`, `The report number unlocks replacements and disputes — file it first, even for small losses.`, 'government', 'critical', 0, 2,
        ['Report filed', 'Report number saved']),
      t('block', `Block, freeze and lock everything exposed`, `Cards cancelled, accounts frozen, devices remotely locked, passwords rotated — within hours, not days.`, 'finance', 'critical', 0, 2,
        ['Cards cancelled', 'Accounts frozen / passwords rotated', 'Devices locked']),
      t('embassy', `Contact the embassy / consulate`, `For documents lost abroad: emergency travel documents and local police report guidance.`, 'government', 'critical', 0, 3,
        ['Embassy contacted', 'Emergency documents arranged'], { deps: ['report'] }),
      t('replace', `Order replacements`, `Replacement documents/cards/devices, with the police report attached where it speeds things up.`, 'government', 'critical', 2, 21,
        ['Replacements ordered', 'Replacements received'], { deps: ['report'] }),
      t('monitor', `Monitor for fraud for the next 60 days`, `Statements, credit report and unfamiliar account activity — dispute anything unrecognized immediately.`, 'finance', 'high', 2, 60,
        ['Statements monitored', 'Credit report checked', 'Disputes filed if needed'], { deps: ['block'] }),
    ],
  };
}

/** Home emergencies: fire, flood, burglary, disaster. */
export function emergency(s: string): Pack {
  return {
    questions: [
      { id: 'need_temp_housing', prompt: 'Do you need temporary housing?', kind: 'boolean', gatesTasks: ['temp_housing'] },
    ],
    tasks: [
      t('secure', `Make the property safe and prevent further damage`, `Safety first, then mitigation (board up, shut off water/power, dry out) — insurers expect reasonable mitigation.`, 'housing', 'critical', 0, 2,
        ['Everyone safe', 'Hazards shut off', 'Mitigation done']),
      t('document', `Document everything before touching anything`, `Photos, video and an inventory of damage/losses — the claim is built on this evidence.`, 'legal', 'critical', 0, 3,
        ['Photos & video taken', 'Loss inventory written']),
      t('claim', `Open the insurance claim`, `Notify the insurer immediately, get the claim number, and log every conversation.`, 'insurance', 'critical', 0, 14,
        ['Insurer notified', 'Claim number received', 'Conversation log started'], { deps: ['document'] }),
      t('temp_housing', `Arrange temporary housing`, `Check what the policy covers for additional living expenses, and keep every receipt.`, 'housing', 'critical', 0, 7,
        ['Coverage for lodging confirmed', 'Housing arranged', 'Receipts kept'], { deps: ['claim'] }),
      t('restore', `Arrange repairs and restoration`, `Approved contractors, itemized quotes, and insurer sign-off before major work.`, 'housing', 'high', 7, 60,
        ['Quotes collected', 'Insurer sign-off received', 'Repairs completed'], { deps: ['claim'] }),
      t('prevent', `Reduce the odds of a repeat`, `Alarms, detectors, locks, drainage — whatever addresses this event's root cause.`, 'housing', 'medium', 30, 90,
        ['Root cause addressed', 'Prevention installed']),
    ],
  };
}

/** Athletic events and training goals. */
export function sport(s: string): Pack {
  return {
    questions: [
      { id: 'want_coach', prompt: 'Do you want a coach or training group?', kind: 'boolean', gatesTasks: ['coach'] },
      { id: 'travel_needed', prompt: 'Does the event require travel?', kind: 'boolean', gatesTasks: ['travel'] },
    ],
    tasks: [
      t('register', `Register for ${s}`, `Spots and early-bird pricing go first; registration usually requires a waiver and sometimes a medical certificate.`, 'social', 'critical', -120, -90,
        ['Registered', 'Waiver signed', 'Confirmation saved']),
      t('medical', `Get the medical green light`, `A check-up appropriate to the effort, especially if you're new to this volume of training.`, 'health', 'high', -120, -90,
        ['Check-up done', 'Cleared to train']),
      t('coach', `Arrange coaching or a training group`, `A coach or group keeps the plan honest; agree goals and cadence up front.`, 'health', 'medium', -110, -80,
        ['Coach / group chosen', 'Goals agreed'], { deps: ['register'] }),
      t('train', `Follow a structured training plan`, `A progressive plan with rest weeks; the plan is what gets you to the start line uninjured.`, 'health', 'critical', -90, -7,
        ['Plan chosen', 'Weekly sessions logged', 'Rest weeks respected'], { deps: ['medical'] }),
      t('travel', `Book event travel and accommodation`, `Rooms near big events sell out the day registration opens — book early, cancelable.`, 'travel', 'medium', -90, -30,
        ['Transport booked', 'Accommodation booked'], { deps: ['register'] }),
      t('gear', `Sort gear, nutrition and logistics`, `Nothing new on event day — gear and nutrition tested in training; bib pickup planned.`, 'travel', 'medium', -30, -7,
        ['Gear tested in training', 'Nutrition tested', 'Event-day logistics planned'], { deps: ['register'] }),
    ],
  };
}

/** Renting a home. */
export function renting(s: string): Pack {
  return {
    questions: [
      { id: 'has_pets', prompt: 'Do you have pets?', kind: 'boolean', gatesTasks: ['pet_clause'] },
      { id: 'with_roommates', prompt: 'Will you live with roommates?', kind: 'boolean', gatesTasks: ['roommate_agreement'] },
    ],
    tasks: [
      t('search', `Search and view places for ${s}`, `Set the budget ceiling (rent plus utilities plus insurance), shortlist, and view with a checklist.`, 'housing', 'critical', -60, -30,
        ['Budget ceiling set', 'Shortlist made', 'Viewings done']),
      t('apply', `Apply with your documents ready`, `Income proof, references and ID ready to go — good places go to the first complete application.`, 'housing', 'critical', -30, -14,
        ['Documents prepared', 'Applications submitted'], { deps: ['search'], docs: ['Income proof', 'References', 'ID'] }),
      t('lease', `Read and sign the lease carefully`, `Term, notice period, deposit terms and what you're liable for — photographed condition report before moving in.`, 'legal', 'critical', -14, 0,
        ['Lease read fully', 'Signed', 'Condition report photographed'], { deps: ['apply'] }),
      t('pet_clause', `Sort the pet clause and deposit`, `Written landlord permission, any pet deposit terms, and building rules — before signing.`, 'legal', 'high', -14, 0,
        ['Permission in writing', 'Deposit terms agreed'], { deps: ['apply'] }),
      t('roommate_agreement', `Write the roommate agreement`, `Rent split, bills, chores and exit terms in writing — friendships survive written agreements better than assumptions.`, 'legal', 'medium', -14, 7,
        ['Split agreed in writing', 'Exit terms agreed'], { deps: ['lease'] }),
      t('insurance', `Get renter's/contents insurance`, `Often required by the lease; cheap relative to what it covers.`, 'insurance', 'high', -14, 0,
        ['Quotes compared', 'Policy active from day one'], { deps: ['lease'] }),
      t('setup', `Set up utilities and services`, `Electricity, internet and anything not included in rent, active from day one.`, 'utilities', 'high', -14, 7,
        ['Utilities transferred / opened', 'Internet booked'], { deps: ['lease'] }),
    ],
  };
}

/** Decade birthdays and age milestones. */
export function birthday(age: number, financeNote: string, healthNote: string): Pack {
  return {
    questions: [
      { id: 'want_party', prompt: 'Are you planning a celebration?', kind: 'boolean', gatesTasks: ['celebrate'] },
    ],
    tasks: [
      t('celebrate', `Plan the ${age}th birthday celebration`, `However you mark it — party, trip or dinner — decide and book it early enough to do it well.`, 'social', 'medium', -45, -7,
        ['Format decided', 'Booked / organized', 'People invited']),
      t('documents', `Check documents and renewals around this birthday`, `IDs, passports, licences and any age-linked registrations that expire or change around this age.`, 'government', 'medium', -30, 30,
        ['Expiry dates checked', 'Renewals ordered']),
      t('money', `Do the ${age}-year financial checkpoint`, financeNote, 'finance', 'high', -14, 60,
        ['Accounts reviewed', 'Rates / contributions adjusted', 'Coverage reviewed']),
      t('health', `Do the age-appropriate health checks`, healthNote, 'health', 'high', 0, 90,
        ['Check-up booked', 'Screenings done', 'Results followed up']),
    ],
  };
}
