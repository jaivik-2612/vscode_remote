import { Domain } from './types';

/**
 * Country-aware help resources for tasks.
 *
 * A task like "File the unemployment claim" is only actionable if you know
 * where to do it — and that depends on where you live. The user's profile
 * (from the sign-up form) drives resolution:
 *
 *   1. task-specific official links for the user's country (best)
 *   2. the country's portal for the task's domain (good)
 *   3. a search link localized with the user's region + country (always there)
 *
 * The 'ALL' country key is for tasks whose authority doesn't depend on where
 * the user lives (e.g. immigration to Canada is IRCC for everyone).
 */

export interface UserProfile {
  name: string;
  /** Country code from COUNTRIES, or 'OTHER'. */
  country: string;
  /** State / province / region, free text. */
  region: string;
  city: string;
}

export interface Resource {
  label: string;
  url: string;
  kind: 'official' | 'portal' | 'search';
}

export const COUNTRIES: { code: string; name: string; regionLabel: string }[] = [
  { code: 'US', name: 'United States', regionLabel: 'State' },
  { code: 'CA', name: 'Canada', regionLabel: 'Province' },
  { code: 'GB', name: 'United Kingdom', regionLabel: 'Region' },
  { code: 'AU', name: 'Australia', regionLabel: 'State' },
  { code: 'IN', name: 'India', regionLabel: 'State' },
  { code: 'OTHER', name: 'Other', regionLabel: 'State / region' },
];

export function countryName(code: string): string {
  return COUNTRIES.find((c) => c.code === code)?.name ?? '';
}

type CountryLinks = Record<string, { label: string; url: string }[]>;

/** Task-template-id → country → official links. */
const TASK_RESOURCES: Record<string, CountryLinks> = {
  'loss.unemployment_claim': {
    US: [{ label: 'Find your state unemployment office (CareerOneStop)', url: 'https://www.careeronestop.org/LocalHelp/UnemploymentBenefits/find-unemployment-benefits.aspx' }],
    CA: [{ label: 'Employment Insurance (EI) — Service Canada', url: 'https://www.canada.ca/en/services/benefits/ei.html' }],
    GB: [{ label: 'Universal Credit — GOV.UK', url: 'https://www.gov.uk/universal-credit' }],
    AU: [{ label: 'JobSeeker Payment — Services Australia', url: 'https://www.servicesaustralia.gov.au/jobseeker-payment' }],
  },
  'moved.mail_forwarding': {
    US: [{ label: 'USPS mail forwarding', url: 'https://www.usps.com/manage/forward.htm' }],
    CA: [{ label: 'Canada Post mail forwarding', url: 'https://www.canadapost-postescanada.ca/cpc/en/personal/receiving/manage-mail/mail-forwarding.page' }],
    GB: [{ label: 'Royal Mail redirection', url: 'https://www.royalmail.com/personal/receiving-mail/redirection' }],
    AU: [{ label: 'Australia Post mail redirect', url: 'https://auspost.com.au/receiving/manage-your-mail/redirect-hold-mail' }],
    IN: [{ label: 'India Post', url: 'https://www.indiapost.gov.in/' }],
  },
  'moved.licence_address': {
    US: [{ label: 'Your state motor-vehicle agency (USA.gov)', url: 'https://www.usa.gov/state-motor-vehicle-services' }],
    GB: [{ label: 'Change address on your driving licence — DVLA', url: 'https://www.gov.uk/change-address-driving-licence' }],
    IN: [{ label: 'Parivahan Sewa (driving licence services)', url: 'https://parivahan.gov.in/' }],
  },
  'moved.new_licence': {
    US: [{ label: 'Your state motor-vehicle agency (USA.gov)', url: 'https://www.usa.gov/state-motor-vehicle-services' }],
  },
  'moved.voter_reregister': {
    US: [{ label: 'Register to vote — Vote.gov', url: 'https://vote.gov/' }],
    CA: [{ label: 'Elections Canada — update registration', url: 'https://www.elections.ca/' }],
    GB: [{ label: 'Register to vote — GOV.UK', url: 'https://www.gov.uk/register-to-vote' }],
    AU: [{ label: 'Australian Electoral Commission', url: 'https://www.aec.gov.au/' }],
    IN: [{ label: 'Voters’ Service Portal — ECI', url: 'https://voters.eci.gov.in/' }],
  },
  'a18.register_vote': {
    US: [{ label: 'Register to vote — Vote.gov', url: 'https://vote.gov/' }],
    CA: [{ label: 'Elections Canada', url: 'https://www.elections.ca/' }],
    GB: [{ label: 'Register to vote — GOV.UK', url: 'https://www.gov.uk/register-to-vote' }],
    AU: [{ label: 'Australian Electoral Commission', url: 'https://www.aec.gov.au/' }],
    IN: [{ label: 'Voters’ Service Portal — ECI', url: 'https://voters.eci.gov.in/' }],
  },
  'moved.tax_address': {
    US: [{ label: 'IRS — address changes', url: 'https://www.irs.gov/faqs/irs-procedures/address-changes' }],
    CA: [{ label: 'CRA — update your address', url: 'https://www.canada.ca/en/revenue-agency/services/tax/individuals/topics/about-your-tax-return/change-your-address.html' }],
    GB: [{ label: 'Tell HMRC when you move — GOV.UK', url: 'https://www.gov.uk/tell-hmrc-change-address' }],
    AU: [{ label: 'ATO — update your details', url: 'https://www.ato.gov.au/individuals-and-families/your-tax-return/update-your-details' }],
    IN: [{ label: 'Income Tax e-filing portal', url: 'https://www.incometax.gov.in/' }],
  },
  'trip.passports': {
    US: [{ label: 'U.S. passports — travel.state.gov', url: 'https://travel.state.gov/content/travel/en/passports.html' }],
    CA: [{ label: 'Canadian passports', url: 'https://www.canada.ca/en/services/canadians/passports.html' }],
    GB: [{ label: 'Apply for / renew a UK passport', url: 'https://www.gov.uk/renew-adult-passport' }],
    AU: [{ label: 'Australian Passport Office', url: 'https://www.passports.gov.au/' }],
    IN: [{ label: 'Passport Seva', url: 'https://www.passportindia.gov.in/' }],
  },
  'biz.register': {
    US: [{ label: 'Register your business — SBA', url: 'https://www.sba.gov/business-guide/launch-your-business/register-your-business' }],
    CA: [{ label: 'Start a business — Canada.ca', url: 'https://www.canada.ca/en/services/business/start.html' }],
    GB: [{ label: 'Set up a business — GOV.UK', url: 'https://www.gov.uk/set-up-business' }],
    AU: [{ label: 'Register your business — business.gov.au', url: 'https://business.gov.au/registrations' }],
    IN: [{ label: 'Ministry of Corporate Affairs', url: 'https://www.mca.gov.in/' }],
  },
  'biz.tax_id': {
    US: [{ label: 'Apply for an EIN — IRS', url: 'https://www.irs.gov/businesses/small-businesses-self-employed/apply-for-an-employer-identification-number-ein-online' }],
    CA: [{ label: 'Business number registration — CRA', url: 'https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/registering-your-business.html' }],
  },
  'baby.birth_registration': {
    US: [{ label: 'Where to get vital records (CDC)', url: 'https://www.cdc.gov/nchs/w2w/index.htm' }],
    GB: [{ label: 'Register a birth — GOV.UK', url: 'https://www.gov.uk/register-birth' }],
    IN: [{ label: 'Civil Registration System', url: 'https://crsorgi.gov.in/' }],
  },
  'est.death_certificates': {
    US: [{ label: 'Where to get vital records (CDC)', url: 'https://www.cdc.gov/nchs/w2w/index.htm' }],
    GB: [{ label: 'Register a death — GOV.UK', url: 'https://www.gov.uk/register-a-death' }],
  },
  'ret.gov_pension': {
    US: [{ label: 'Apply for retirement benefits — SSA', url: 'https://www.ssa.gov/retirement' }],
    CA: [{ label: 'CPP retirement pension', url: 'https://www.canada.ca/en/services/benefits/publicpensions/cpp.html' }],
    GB: [{ label: 'State Pension — GOV.UK', url: 'https://www.gov.uk/state-pension' }],
    AU: [{ label: 'Age Pension — Services Australia', url: 'https://www.servicesaustralia.gov.au/age-pension' }],
    IN: [{ label: 'EPFO member portal', url: 'https://www.epfindia.gov.in/' }],
  },
  'ret.gov_health': {
    US: [{ label: 'Get started with Medicare', url: 'https://www.medicare.gov/basics/get-started-with-medicare' }],
  },
  'loss.health_continuation': {
    US: [{ label: 'Health coverage options after job loss — HealthCare.gov', url: 'https://www.healthcare.gov/unemployed/coverage/' }],
  },
  'grad.health_transition': {
    US: [{ label: 'Health coverage marketplace — HealthCare.gov', url: 'https://www.healthcare.gov/' }],
  },
  'baby.child_benefits': {
    CA: [{ label: 'Canada Child Benefit', url: 'https://www.canada.ca/en/revenue-agency/services/child-family-benefits/canada-child-benefit-overview.html' }],
    GB: [{ label: 'Child Benefit — GOV.UK', url: 'https://www.gov.uk/child-benefit' }],
  },
  'a18.student_aid': {
    US: [{ label: 'Federal student aid — FAFSA', url: 'https://studentaid.gov/' }],
    CA: [{ label: 'Student aid — Canada.ca', url: 'https://www.canada.ca/en/services/benefits/education/student-aid.html' }],
    GB: [{ label: 'Student finance — GOV.UK', url: 'https://www.gov.uk/student-finance' }],
  },
  // Immigration-to-Canada tasks point at IRCC no matter where the user lives.
  'imm.eligibility': { ALL: [{ label: 'Immigrate to Canada — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada.html' }] },
  'imm.language_test': { ALL: [{ label: 'Language testing for Express Entry — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry/documents/language-requirements.html' }] },
  'imm.eca': { ALL: [{ label: 'Educational credential assessment — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry/documents/education-assessed.html' }] },
  'imm.profile': { ALL: [{ label: 'Express Entry — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry.html' }] },
  'imm.application': { ALL: [{ label: 'Express Entry — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/immigrate-canada/express-entry.html' }] },
  'imm.monitor': { ALL: [{ label: 'Check application status — IRCC', url: 'https://www.canada.ca/en/immigration-refugees-citizenship/services/application/check-status.html' }] },
};

/** Domain → country → the main portal for that sphere. */
const DOMAIN_PORTALS: Partial<Record<Domain, CountryLinks>> = {
  government: {
    US: [{ label: 'USA.gov — government services', url: 'https://www.usa.gov/' }],
    CA: [{ label: 'Canada.ca — government services', url: 'https://www.canada.ca/en/services.html' }],
    GB: [{ label: 'GOV.UK', url: 'https://www.gov.uk/' }],
    AU: [{ label: 'australia.gov.au', url: 'https://www.australia.gov.au/' }],
    IN: [{ label: 'india.gov.in — national portal', url: 'https://www.india.gov.in/' }],
  },
  tax: {
    US: [{ label: 'IRS', url: 'https://www.irs.gov/' }],
    CA: [{ label: 'Canada Revenue Agency', url: 'https://www.canada.ca/en/revenue-agency.html' }],
    GB: [{ label: 'HMRC', url: 'https://www.gov.uk/government/organisations/hm-revenue-customs' }],
    AU: [{ label: 'Australian Taxation Office', url: 'https://www.ato.gov.au/' }],
    IN: [{ label: 'Income Tax Department', url: 'https://www.incometax.gov.in/' }],
  },
  finance: {
    US: [{ label: 'Consumer Financial Protection Bureau', url: 'https://www.consumerfinance.gov/' }],
    CA: [{ label: 'Financial Consumer Agency of Canada', url: 'https://www.canada.ca/en/financial-consumer-agency.html' }],
    GB: [{ label: 'MoneyHelper', url: 'https://www.moneyhelper.org.uk/' }],
    AU: [{ label: 'Moneysmart', url: 'https://moneysmart.gov.au/' }],
    IN: [{ label: 'RBI — consumer education', url: 'https://www.rbi.org.in/' }],
  },
  health: {
    US: [{ label: 'HealthCare.gov', url: 'https://www.healthcare.gov/' }],
    CA: [{ label: 'Health — Canada.ca', url: 'https://www.canada.ca/en/services/health.html' }],
    GB: [{ label: 'NHS', url: 'https://www.nhs.uk/' }],
    AU: [{ label: 'Department of Health', url: 'https://www.health.gov.au/' }],
    IN: [{ label: 'National Health Portal', url: 'https://www.nhp.gov.in/' }],
  },
  employment: {
    US: [{ label: 'U.S. Department of Labor', url: 'https://www.dol.gov/' }],
    CA: [{ label: 'Jobs & workplace — Canada.ca', url: 'https://www.canada.ca/en/services/jobs.html' }],
    GB: [{ label: 'Working, jobs and pensions — GOV.UK', url: 'https://www.gov.uk/browse/working' }],
    AU: [{ label: 'Fair Work Ombudsman', url: 'https://www.fairwork.gov.au/' }],
    IN: [{ label: 'Ministry of Labour & Employment', url: 'https://labour.gov.in/' }],
  },
  immigration: {
    US: [{ label: 'USCIS', url: 'https://www.uscis.gov/' }],
    CA: [{ label: 'Immigration and citizenship — IRCC', url: 'https://www.canada.ca/en/services/immigration-citizenship.html' }],
    GB: [{ label: 'Visas and immigration — GOV.UK', url: 'https://www.gov.uk/browse/visas-immigration' }],
    AU: [{ label: 'Department of Home Affairs', url: 'https://immi.homeaffairs.gov.au/' }],
  },
};

/** The minimal shape of a task the resolver needs. */
export interface ResolvableTask {
  templateId: string;
  title: string;
  domain: Domain;
}

function searchResource(task: ResolvableTask, profile: UserProfile | null): Resource {
  const where = profile
    ? [profile.region, countryName(profile.country) || profile.country].filter((s) => s && s !== 'OTHER').join(', ')
    : '';
  const query = `how to ${task.title.toLowerCase()}${where ? ' in ' + where : ''}`;
  return {
    label: where ? `Search: how to do this in ${where}` : 'Search: how to do this where you live',
    url: 'https://www.google.com/search?q=' + encodeURIComponent(query),
    kind: 'search',
  };
}

/**
 * Resolve help resources for a task given the user's profile.
 * Always returns at least one resource (the localized search link).
 */
export function resolveResources(task: ResolvableTask, profile: UserProfile | null): Resource[] {
  const out: Resource[] = [];
  const country = profile?.country ?? '';

  const specific = TASK_RESOURCES[task.templateId];
  if (specific) {
    for (const link of specific['ALL'] ?? []) out.push({ ...link, kind: 'official' });
    if (country && specific[country]) {
      for (const link of specific[country]) out.push({ ...link, kind: 'official' });
    }
  }

  if (country) {
    const portal = DOMAIN_PORTALS[task.domain]?.[country];
    if (portal) for (const link of portal) out.push({ ...link, kind: 'portal' });
  }

  out.push(searchResource(task, profile));

  // De-duplicate by URL, keep order (official > portal > search).
  const seen = new Set<string>();
  return out.filter((r) => (seen.has(r.url) ? false : (seen.add(r.url), true))).slice(0, 4);
}
