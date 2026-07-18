import { UserProfile } from './resources';

/**
 * Product suggestions — the monetization layer.
 *
 * Life events come with shopping lists as well as paperwork. This module is
 * the app's own product database: per-event suggestion packs, optionally
 * anchored to a specific task, rendered as Amazon links.
 *
 * Monetization model: no charges, no ads — affiliate links only.
 * For now links are plain Amazon search URLs (fully functional for testing).
 * When the Amazon Associates account is ready, set AFFILIATE_TAG below and
 * every link in the app becomes an affiliate link — nothing else to change.
 * Storefront follows the user's profile country.
 */

/** Set to your Amazon Associates tag (e.g. 'lifeos-20') once approved. */
export const AFFILIATE_TAG = '';

const AMAZON_DOMAINS: Record<string, string> = {
  US: 'amazon.com',
  CA: 'amazon.ca',
  GB: 'amazon.co.uk',
  AU: 'amazon.com.au',
  IN: 'amazon.in',
};

export interface ProductSuggestion {
  /** What the user sees, e.g. "Newborn clothes". */
  label: string;
  /** Amazon search query — the fallback link when no ASIN is curated. */
  query: string;
  /** Optional task-template id this product belongs inside. */
  taskId?: string;
  /**
   * Optional curated product ASINs per marketplace ('US', 'CA', …), for
   * direct product-page links (much higher conversion than search results).
   * ASINs are marketplace-specific — only countries listed here get the
   * direct link; everyone else falls back to the search link, so a missing
   * or stale ASIN can never produce a dead end.
   */
  asin?: Record<string, string>;
}

function tagged(url: string, sep: '?' | '&'): string {
  return AFFILIATE_TAG ? `${url}${sep}tag=${encodeURIComponent(AFFILIATE_TAG)}` : url;
}

export function amazonUrl(query: string, profile: UserProfile | null): string {
  const domain = (profile && AMAZON_DOMAINS[profile.country]) || 'amazon.com';
  return tagged(`https://www.${domain}/s?k=${encodeURIComponent(query)}`, '&');
}

/**
 * The link a product suggestion opens: direct product page when a curated
 * ASIN exists for the user's marketplace, search results otherwise.
 */
export function productUrl(product: ProductSuggestion, profile: UserProfile | null): string {
  const country = profile?.country && AMAZON_DOMAINS[profile.country] ? profile.country : 'US';
  const asin = product.asin?.[country];
  if (asin) {
    return tagged(`https://www.${AMAZON_DOMAINS[country]}/dp/${encodeURIComponent(asin)}`, '?');
  }
  return amazonUrl(product.query, profile);
}

/** Required Amazon Associates disclosure, shown wherever products appear. */
export const AFFILIATE_DISCLOSURE =
  'As an Amazon Associate, LifeOS may earn from qualifying purchases.';

/** Event id → suggestion pack. The product database. */
export const EVENT_PRODUCTS: Record<string, ProductSuggestion[]> = {
  'new-child': [
    { label: 'Newborn clothes', query: 'newborn baby clothes 0-3 months' },
    { label: 'Diapers & wipes', query: 'newborn diapers and wipes' },
    { label: 'Baby monitor', query: 'baby monitor' },
    { label: 'Infant car seat', query: 'infant car seat' },
    { label: 'Crib & bedding', query: 'baby crib with mattress' },
    { label: 'Bottles & feeding', query: 'baby bottles feeding set' },
    { label: 'Baby toys', query: 'newborn baby toys' },
    { label: 'Baby first-aid kit', query: 'baby first aid kit', taskId: 'baby.health_enrollment' },
    { label: 'Document organizer', query: 'document organizer folder', taskId: 'baby.birth_registration' },
  ],
  pregnancy: [
    { label: 'Pregnancy pillow', query: 'pregnancy pillow' },
    { label: 'Prenatal vitamins', query: 'prenatal vitamins' },
    { label: 'Maternity clothes', query: 'maternity clothes' },
    { label: 'Pregnancy journal', query: 'pregnancy journal' },
  ],
  'new-job': [
    { label: 'Formal work clothes', query: 'business casual work clothes' },
    { label: 'Laptop', query: 'laptop for work' },
    { label: 'Laptop bag', query: 'laptop bag professional' },
    { label: 'Dress shoes', query: 'dress shoes' },
    { label: 'Notebook & pens', query: 'professional notebook pen set', taskId: 'job.contract' },
    { label: 'Document folder', query: 'document folder organizer', taskId: 'job.contract' },
    { label: 'Commuter backpack', query: 'commuter backpack' },
  ],
  'remote-work': [
    { label: 'Webcam', query: 'webcam 1080p' },
    { label: 'Headset with mic', query: 'usb headset with microphone' },
    { label: 'Ergonomic chair', query: 'ergonomic office chair' },
    { label: 'Standing desk', query: 'standing desk' },
    { label: 'Monitor', query: 'external monitor 27 inch' },
    { label: 'Ring light', query: 'ring light for video calls' },
  ],
  moved: [
    { label: 'Moving boxes & tape', query: 'moving boxes with tape' },
    { label: 'Bubble wrap', query: 'bubble wrap for moving' },
    { label: 'Furniture sliders', query: 'furniture sliders' },
    { label: 'Box cutter & markers', query: 'box cutter and permanent markers' },
    { label: 'Cleaning supplies', query: 'moving out cleaning supplies kit' },
    { label: 'First-night essentials', query: 'shower curtain toilet paper essentials kit' },
  ],
  'bought-house': [
    { label: 'Basic tool kit', query: 'home tool kit set' },
    { label: 'Smoke & CO detectors', query: 'smoke and carbon monoxide detector', taskId: 'house.insurance' },
    { label: 'Door locks', query: 'smart door lock deadbolt' },
    { label: 'Ladder', query: 'household step ladder' },
    { label: 'Lawn mower', query: 'lawn mower' },
    { label: 'Fire extinguisher', query: 'home fire extinguisher' },
    { label: 'Document safe', query: 'fireproof document safe', taskId: 'house.title_deed' },
  ],
  'bought-car': [
    { label: 'Phone mount', query: 'car phone mount' },
    { label: 'Dash cam', query: 'dash cam' },
    { label: 'Emergency kit', query: 'car emergency kit jumper cables' },
    { label: 'Floor mats', query: 'all weather car floor mats' },
    { label: 'Cleaning kit', query: 'car wash cleaning kit' },
    { label: 'Tire inflator', query: 'portable tire inflator' },
  ],
  'trip-abroad': [
    { label: 'Luggage set', query: 'luggage set with spinner wheels', taskId: 'trip.bookings' },
    { label: 'Packing cubes', query: 'packing cubes for travel', taskId: 'trip.bookings' },
    { label: 'Universal travel adapter', query: 'universal travel adapter', taskId: 'trip.money' },
    { label: 'Passport holder', query: 'passport holder travel wallet', taskId: 'trip.passports' },
    { label: 'Portable charger', query: 'portable phone charger power bank' },
    { label: 'Travel pillow', query: 'travel neck pillow' },
    { label: 'Luggage tags & scale', query: 'luggage tags and scale' },
  ],
  'got-married': [
    { label: 'Thank-you cards', query: 'wedding thank you cards' },
    { label: 'Photo album', query: 'wedding photo album' },
    { label: 'Document organizer', query: 'important documents organizer', taskId: 'mar.certificate' },
  ],
  'planning-wedding': [
    { label: 'Wedding planner book', query: 'wedding planner book and organizer', taskId: 'wed.budget' },
    { label: 'Budget spreadsheet ledger', query: 'wedding budget planner', taskId: 'wed.budget' },
    { label: 'Invitations', query: 'wedding invitations with envelopes', taskId: 'wed.invitations' },
    { label: 'RSVP cards', query: 'wedding rsvp cards', taskId: 'wed.invitations' },
    { label: 'Wedding rings', query: 'wedding ring set', taskId: 'wed.attire' },
    { label: 'Decorations', query: 'wedding decorations' },
    { label: 'Guest book', query: 'wedding guest book', taskId: 'wed.runsheet' },
    { label: 'Document folder', query: 'expanding document folder', taskId: 'wed.licence' },
  ],
  'graduated-college': [
    { label: 'Interview attire', query: 'interview suit', taskId: 'grad.career_setup' },
    { label: 'Padfolio', query: 'padfolio portfolio folder', taskId: 'grad.career_setup' },
    { label: 'Budget planner', query: 'monthly budget planner', taskId: 'grad.loan_inventory' },
    { label: 'Laptop', query: 'laptop for professionals' },
    { label: 'Diploma frame', query: 'diploma frame', taskId: 'grad.documents' },
  ],
  'started-college': [
    { label: 'Dorm essentials', query: 'college dorm essentials kit' },
    { label: 'Laptop', query: 'laptop for college students' },
    { label: 'Backpack', query: 'college backpack' },
    { label: 'Desk lamp', query: 'desk lamp for studying' },
    { label: 'Bedding set', query: 'twin xl bedding set dorm' },
  ],
  'new-pet': [
    { label: 'Pet food', query: 'puppy food', taskId: 'pet.vet_registration' },
    { label: 'Crate & bed', query: 'dog crate with bed' },
    { label: 'Leash & collar', query: 'dog leash and collar set' },
    { label: 'Food & water bowls', query: 'pet food water bowls' },
    { label: 'Grooming kit', query: 'pet grooming kit' },
    { label: 'ID tag', query: 'pet id tag engraved', taskId: 'pet.microchip' },
    { label: 'Training pads & treats', query: 'puppy training pads treats', taskId: 'pet.training' },
  ],
  'home-renovation': [
    { label: 'Renovation project planner', query: 'home renovation planner notebook', taskId: 'reno.scope_budget' },
    { label: 'Power drill', query: 'cordless power drill set' },
    { label: 'Safety gear', query: 'safety goggles work gloves dust masks' },
    { label: 'Drop cloths', query: 'painters drop cloth plastic sheeting' },
    { label: 'Paint supplies', query: 'paint rollers brushes tray set' },
    { label: 'Stud finder & level', query: 'stud finder and laser level' },
  ],
  'kids-birthday-party': [
    { label: 'Party decorations', query: 'kids birthday party decorations', taskId: 'kids-birthday-party.venue' },
    { label: 'Balloons', query: 'birthday balloons pack', taskId: 'kids-birthday-party.venue' },
    { label: 'Party favors', query: 'kids party favors bulk', taskId: 'kids-birthday-party.food_cake' },
    { label: 'Disposable tableware', query: 'party plates cups napkins set', taskId: 'kids-birthday-party.food_cake' },
    { label: 'Cake candles & topper', query: 'birthday cake candles topper', taskId: 'kids-birthday-party.food_cake' },
    { label: 'Games & piñata', query: 'kids party games pinata', taskId: 'kids-birthday-party.activities' },
    { label: 'First-aid kit', query: 'compact first aid kit', taskId: 'kids-birthday-party.activities' },
  ],
  'baby-shower': [
    { label: 'Shower decorations', query: 'baby shower decorations' },
    { label: 'Games & prizes', query: 'baby shower games and prizes' },
    { label: 'Guest book', query: 'baby shower guest book' },
  ],
  'camping-trip': [
    { label: 'Tent', query: 'camping tent 4 person' },
    { label: 'Sleeping bags', query: 'sleeping bags for camping' },
    { label: 'Camp stove', query: 'portable camping stove' },
    { label: 'Headlamps & lantern', query: 'camping headlamp lantern' },
    { label: 'Cooler', query: 'camping cooler' },
  ],
  honeymoon: [
    { label: 'Luggage set', query: 'luggage set couple' },
    { label: 'Beachwear', query: 'beachwear vacation outfits' },
    { label: 'Travel camera', query: 'compact travel camera' },
  ],
  'immigrate-canada': [
    { label: 'IELTS prep book', query: 'ielts preparation book', taskId: 'imm.language_test' },
    { label: 'Document organizer', query: 'expanding file folder documents', taskId: 'imm.application' },
    { label: 'Winter jacket', query: 'winter jacket -30' },
    { label: 'Winter boots', query: 'insulated winter boots' },
  ],
  retired: [
    { label: 'Retirement budget planner', query: 'retirement budget planner', taskId: 'ret.income_plan' },
    { label: 'E-reader', query: 'e-reader kindle' },
    { label: 'Gardening kit', query: 'gardening tool set' },
    { label: 'Travel gear', query: 'travel accessories seniors' },
  ],
  'joining-gym': [
    { label: 'Gym clothes', query: 'workout clothes', taskId: 'joining-gym.gear' },
    { label: 'Gym shoes', query: 'training shoes gym', taskId: 'joining-gym.gear' },
    { label: 'Gym bag & bottle', query: 'gym bag with water bottle', taskId: 'joining-gym.gear' },
  ],
  'marathon-training': [
    { label: 'Running shoes', query: 'running shoes marathon', taskId: 'marathon-training.gear' },
    { label: 'Running watch', query: 'gps running watch', taskId: 'marathon-training.gear' },
    { label: 'Energy gels', query: 'energy gels running', taskId: 'marathon-training.train' },
    { label: 'Foam roller', query: 'foam roller recovery', taskId: 'marathon-training.train' },
  ],
  'gaming-pc': [
    { label: 'PC components', query: 'gaming pc parts bundle' },
    { label: 'Monitor', query: 'gaming monitor 144hz' },
    { label: 'Mechanical keyboard', query: 'mechanical gaming keyboard' },
    { label: 'Gaming mouse', query: 'gaming mouse' },
  ],
  'backyard-chickens': [
    { label: 'Chicken coop', query: 'backyard chicken coop' },
    { label: 'Feeder & waterer', query: 'chicken feeder waterer set' },
    { label: 'Chicken feed', query: 'chicken layer feed' },
  ],
  aquarium: [
    { label: 'Aquarium kit', query: 'aquarium starter kit' },
    { label: 'Filter & heater', query: 'aquarium filter heater' },
    { label: 'Water test kit', query: 'aquarium water test kit' },
  ],
  'lost-job': [
    { label: 'Monthly budget planner', query: 'monthly budget planner', taskId: 'loss.budget_triage' },
    { label: 'Expense tracker notebook', query: 'expense tracker notebook', taskId: 'loss.budget_triage' },
    { label: 'Interview attire', query: 'interview attire professional', taskId: 'loss.employer_records' },
  ],
  'elder-care': [
    { label: 'Medical alert device', query: 'medical alert device for seniors', taskId: 'elder-care.providers' },
    { label: 'Pill organizer', query: 'weekly pill organizer', taskId: 'elder-care.schedule' },
    { label: 'Grab bars', query: 'bathroom grab bars seniors', taskId: 'elder-care.assess' },
  ],
  'disaster-prep': [
    { label: 'Emergency kit', query: '72 hour emergency kit', taskId: 'disaster-prep.execute' },
    { label: 'Water storage', query: 'emergency water storage' },
    { label: 'Weather radio', query: 'emergency weather radio hand crank' },
    { label: 'First-aid kit', query: 'large first aid kit' },
  ],
  'tax-season': [
    { label: 'Tax prep software', query: 'tax preparation software', taskId: 'tax-season.paperwork' },
    { label: 'Receipt organizer', query: 'receipt organizer for taxes', taskId: 'tax-season.assess' },
    { label: 'Document scanner', query: 'portable document scanner' },
  ],
  'first-tax-return': [
    { label: 'Tax prep software', query: 'tax software for beginners', taskId: 'first-tax-return.paperwork' },
    { label: 'Document organizer', query: 'tax document organizer', taskId: 'first-tax-return.assess' },
  ],
  'side-gig-taxes': [
    { label: 'Bookkeeping ledger', query: 'small business bookkeeping ledger', taskId: 'side-gig-taxes.assess' },
    { label: 'Receipt scanner', query: 'receipt scanner', taskId: 'side-gig-taxes.paperwork' },
  ],
};

/** Event-level suggestions for the plan screen ("Things you might need"). */
export function productsForPlan(eventId: string): ProductSuggestion[] {
  return EVENT_PRODUCTS[eventId] ?? [];
}

/** Suggestions anchored to one task, shown inside that task's detail view. */
export function productsForTask(eventId: string, taskTemplateId: string): ProductSuggestion[] {
  return (EVENT_PRODUCTS[eventId] ?? []).filter((p) => p.taskId === taskTemplateId);
}
