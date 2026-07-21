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
  /** Full display name (first + last). */
  name: string;
  firstName?: string;
  lastName?: string;
  /** ISO country code from COUNTRIES, or 'OTHER'. */
  country: string;
  /** State / province / region — picked from a list for US/CA, free text elsewhere. */
  region: string;
  city: string;
}

export interface Resource {
  label: string;
  url: string;
  kind: 'official' | 'portal' | 'search';
}

/** All countries (ISO 3166-1 alpha-2), alphabetical, plus an 'Other' catch-all. */
export const COUNTRIES: { code: string; name: string }[] = [
  { code: 'AF', name: 'Afghanistan' }, { code: 'AL', name: 'Albania' }, { code: 'DZ', name: 'Algeria' },
  { code: 'AD', name: 'Andorra' }, { code: 'AO', name: 'Angola' }, { code: 'AG', name: 'Antigua and Barbuda' },
  { code: 'AR', name: 'Argentina' }, { code: 'AM', name: 'Armenia' }, { code: 'AU', name: 'Australia' },
  { code: 'AT', name: 'Austria' }, { code: 'AZ', name: 'Azerbaijan' }, { code: 'BS', name: 'Bahamas' },
  { code: 'BH', name: 'Bahrain' }, { code: 'BD', name: 'Bangladesh' }, { code: 'BB', name: 'Barbados' },
  { code: 'BY', name: 'Belarus' }, { code: 'BE', name: 'Belgium' }, { code: 'BZ', name: 'Belize' },
  { code: 'BJ', name: 'Benin' }, { code: 'BT', name: 'Bhutan' }, { code: 'BO', name: 'Bolivia' },
  { code: 'BA', name: 'Bosnia and Herzegovina' }, { code: 'BW', name: 'Botswana' }, { code: 'BR', name: 'Brazil' },
  { code: 'BN', name: 'Brunei' }, { code: 'BG', name: 'Bulgaria' }, { code: 'BF', name: 'Burkina Faso' },
  { code: 'BI', name: 'Burundi' }, { code: 'CV', name: 'Cabo Verde' }, { code: 'KH', name: 'Cambodia' },
  { code: 'CM', name: 'Cameroon' }, { code: 'CA', name: 'Canada' }, { code: 'CF', name: 'Central African Republic' },
  { code: 'TD', name: 'Chad' }, { code: 'CL', name: 'Chile' }, { code: 'CN', name: 'China' },
  { code: 'CO', name: 'Colombia' }, { code: 'KM', name: 'Comoros' }, { code: 'CG', name: 'Congo' },
  { code: 'CD', name: 'Congo (DRC)' }, { code: 'CR', name: 'Costa Rica' }, { code: 'CI', name: "Côte d'Ivoire" },
  { code: 'HR', name: 'Croatia' }, { code: 'CU', name: 'Cuba' }, { code: 'CY', name: 'Cyprus' },
  { code: 'CZ', name: 'Czechia' }, { code: 'DK', name: 'Denmark' }, { code: 'DJ', name: 'Djibouti' },
  { code: 'DM', name: 'Dominica' }, { code: 'DO', name: 'Dominican Republic' }, { code: 'EC', name: 'Ecuador' },
  { code: 'EG', name: 'Egypt' }, { code: 'SV', name: 'El Salvador' }, { code: 'GQ', name: 'Equatorial Guinea' },
  { code: 'ER', name: 'Eritrea' }, { code: 'EE', name: 'Estonia' }, { code: 'SZ', name: 'Eswatini' },
  { code: 'ET', name: 'Ethiopia' }, { code: 'FJ', name: 'Fiji' }, { code: 'FI', name: 'Finland' },
  { code: 'FR', name: 'France' }, { code: 'GA', name: 'Gabon' }, { code: 'GM', name: 'Gambia' },
  { code: 'GE', name: 'Georgia' }, { code: 'DE', name: 'Germany' }, { code: 'GH', name: 'Ghana' },
  { code: 'GR', name: 'Greece' }, { code: 'GD', name: 'Grenada' }, { code: 'GT', name: 'Guatemala' },
  { code: 'GN', name: 'Guinea' }, { code: 'GW', name: 'Guinea-Bissau' }, { code: 'GY', name: 'Guyana' },
  { code: 'HT', name: 'Haiti' }, { code: 'HN', name: 'Honduras' }, { code: 'HU', name: 'Hungary' },
  { code: 'IS', name: 'Iceland' }, { code: 'IN', name: 'India' }, { code: 'ID', name: 'Indonesia' },
  { code: 'IR', name: 'Iran' }, { code: 'IQ', name: 'Iraq' }, { code: 'IE', name: 'Ireland' },
  { code: 'IL', name: 'Israel' }, { code: 'IT', name: 'Italy' }, { code: 'JM', name: 'Jamaica' },
  { code: 'JP', name: 'Japan' }, { code: 'JO', name: 'Jordan' }, { code: 'KZ', name: 'Kazakhstan' },
  { code: 'KE', name: 'Kenya' }, { code: 'KI', name: 'Kiribati' }, { code: 'KW', name: 'Kuwait' },
  { code: 'KG', name: 'Kyrgyzstan' }, { code: 'LA', name: 'Laos' }, { code: 'LV', name: 'Latvia' },
  { code: 'LB', name: 'Lebanon' }, { code: 'LS', name: 'Lesotho' }, { code: 'LR', name: 'Liberia' },
  { code: 'LY', name: 'Libya' }, { code: 'LI', name: 'Liechtenstein' }, { code: 'LT', name: 'Lithuania' },
  { code: 'LU', name: 'Luxembourg' }, { code: 'MG', name: 'Madagascar' }, { code: 'MW', name: 'Malawi' },
  { code: 'MY', name: 'Malaysia' }, { code: 'MV', name: 'Maldives' }, { code: 'ML', name: 'Mali' },
  { code: 'MT', name: 'Malta' }, { code: 'MH', name: 'Marshall Islands' }, { code: 'MR', name: 'Mauritania' },
  { code: 'MU', name: 'Mauritius' }, { code: 'MX', name: 'Mexico' }, { code: 'FM', name: 'Micronesia' },
  { code: 'MD', name: 'Moldova' }, { code: 'MC', name: 'Monaco' }, { code: 'MN', name: 'Mongolia' },
  { code: 'ME', name: 'Montenegro' }, { code: 'MA', name: 'Morocco' }, { code: 'MZ', name: 'Mozambique' },
  { code: 'MM', name: 'Myanmar' }, { code: 'NA', name: 'Namibia' }, { code: 'NR', name: 'Nauru' },
  { code: 'NP', name: 'Nepal' }, { code: 'NL', name: 'Netherlands' }, { code: 'NZ', name: 'New Zealand' },
  { code: 'NI', name: 'Nicaragua' }, { code: 'NE', name: 'Niger' }, { code: 'NG', name: 'Nigeria' },
  { code: 'KP', name: 'North Korea' }, { code: 'MK', name: 'North Macedonia' }, { code: 'NO', name: 'Norway' },
  { code: 'OM', name: 'Oman' }, { code: 'PK', name: 'Pakistan' }, { code: 'PW', name: 'Palau' },
  { code: 'PS', name: 'Palestine' }, { code: 'PA', name: 'Panama' }, { code: 'PG', name: 'Papua New Guinea' },
  { code: 'PY', name: 'Paraguay' }, { code: 'PE', name: 'Peru' }, { code: 'PH', name: 'Philippines' },
  { code: 'PL', name: 'Poland' }, { code: 'PT', name: 'Portugal' }, { code: 'QA', name: 'Qatar' },
  { code: 'RO', name: 'Romania' }, { code: 'RU', name: 'Russia' }, { code: 'RW', name: 'Rwanda' },
  { code: 'KN', name: 'Saint Kitts and Nevis' }, { code: 'LC', name: 'Saint Lucia' },
  { code: 'VC', name: 'Saint Vincent and the Grenadines' }, { code: 'WS', name: 'Samoa' },
  { code: 'SM', name: 'San Marino' }, { code: 'ST', name: 'São Tomé and Príncipe' },
  { code: 'SA', name: 'Saudi Arabia' }, { code: 'SN', name: 'Senegal' }, { code: 'RS', name: 'Serbia' },
  { code: 'SC', name: 'Seychelles' }, { code: 'SL', name: 'Sierra Leone' }, { code: 'SG', name: 'Singapore' },
  { code: 'SK', name: 'Slovakia' }, { code: 'SI', name: 'Slovenia' }, { code: 'SB', name: 'Solomon Islands' },
  { code: 'SO', name: 'Somalia' }, { code: 'ZA', name: 'South Africa' }, { code: 'KR', name: 'South Korea' },
  { code: 'SS', name: 'South Sudan' }, { code: 'ES', name: 'Spain' }, { code: 'LK', name: 'Sri Lanka' },
  { code: 'SD', name: 'Sudan' }, { code: 'SR', name: 'Suriname' }, { code: 'SE', name: 'Sweden' },
  { code: 'CH', name: 'Switzerland' }, { code: 'SY', name: 'Syria' }, { code: 'TW', name: 'Taiwan' },
  { code: 'TJ', name: 'Tajikistan' }, { code: 'TZ', name: 'Tanzania' }, { code: 'TH', name: 'Thailand' },
  { code: 'TL', name: 'Timor-Leste' }, { code: 'TG', name: 'Togo' }, { code: 'TO', name: 'Tonga' },
  { code: 'TT', name: 'Trinidad and Tobago' }, { code: 'TN', name: 'Tunisia' }, { code: 'TR', name: 'Türkiye' },
  { code: 'TM', name: 'Turkmenistan' }, { code: 'TV', name: 'Tuvalu' }, { code: 'UG', name: 'Uganda' },
  { code: 'UA', name: 'Ukraine' }, { code: 'AE', name: 'United Arab Emirates' },
  { code: 'GB', name: 'United Kingdom' }, { code: 'US', name: 'United States' },
  { code: 'UY', name: 'Uruguay' }, { code: 'UZ', name: 'Uzbekistan' }, { code: 'VU', name: 'Vanuatu' },
  { code: 'VA', name: 'Vatican City' }, { code: 'VE', name: 'Venezuela' }, { code: 'VN', name: 'Vietnam' },
  { code: 'YE', name: 'Yemen' }, { code: 'ZM', name: 'Zambia' }, { code: 'ZW', name: 'Zimbabwe' },
  { code: 'OTHER', name: 'Other' },
];

export function countryName(code: string): string {
  return COUNTRIES.find((c) => c.code === code)?.name ?? '';
}

export function regionLabelFor(code: string): string {
  if (code === 'US') return 'State';
  if (code === 'CA') return 'Province';
  return 'State / region';
}

export const US_STATES: string[] = [
  'Alabama', 'Alaska', 'Arizona', 'Arkansas', 'California', 'Colorado', 'Connecticut', 'Delaware',
  'District of Columbia', 'Florida', 'Georgia', 'Hawaii', 'Idaho', 'Illinois', 'Indiana', 'Iowa',
  'Kansas', 'Kentucky', 'Louisiana', 'Maine', 'Maryland', 'Massachusetts', 'Michigan', 'Minnesota',
  'Mississippi', 'Missouri', 'Montana', 'Nebraska', 'Nevada', 'New Hampshire', 'New Jersey',
  'New Mexico', 'New York', 'North Carolina', 'North Dakota', 'Ohio', 'Oklahoma', 'Oregon',
  'Pennsylvania', 'Rhode Island', 'South Carolina', 'South Dakota', 'Tennessee', 'Texas', 'Utah',
  'Vermont', 'Virginia', 'Washington', 'West Virginia', 'Wisconsin', 'Wyoming',
];

export const CA_PROVINCES: string[] = [
  'Alberta', 'British Columbia', 'Manitoba', 'New Brunswick', 'Newfoundland and Labrador',
  'Northwest Territories', 'Nova Scotia', 'Nunavut', 'Ontario', 'Prince Edward Island',
  'Quebec', 'Saskatchewan', 'Yukon',
];

/** Region options for the picker, or null when the region is free text. */
export function regionOptions(code: string): string[] | null {
  if (code === 'US') return US_STATES;
  if (code === 'CA') return CA_PROVINCES;
  return null;
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
