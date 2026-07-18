import { COUNTRIES, countryName, resolveResources, UserProfile } from '../src/core/resources';
import { generatePlan } from '../src/core/planner';
import { getEventTemplate } from '../src/core/templates';

const usProfile: UserProfile = { name: 'Sam', country: 'US', region: 'California', city: 'San Jose' };
const caProfile: UserProfile = { name: 'Ana', country: 'CA', region: 'Ontario', city: 'Toronto' };

function taskFrom(eventId: string, taskId: string) {
  const plan = generatePlan({
    template: getEventTemplate(eventId)!,
    eventDate: '2026-09-01',
    answers: { has_severance: true },
  });
  return plan.tasks.find((t) => t.id === taskId)!;
}

describe('resolveResources', () => {
  test('US profile gets the state unemployment office link', () => {
    const task = taskFrom('lost-job', 'loss.unemployment_claim');
    const resources = resolveResources(task, usProfile);
    expect(resources.some((r) => r.url.includes('careeronestop.org'))).toBe(true);
    expect(resources[0].kind).toBe('official');
  });

  test('Canadian profile gets the EI link instead', () => {
    const task = taskFrom('lost-job', 'loss.unemployment_claim');
    const resources = resolveResources(task, caProfile);
    expect(resources.some((r) => r.url.includes('canada.ca'))).toBe(true);
    expect(resources.some((r) => r.url.includes('careeronestop.org'))).toBe(false);
  });

  test('search link is always present and localized with region + country', () => {
    const task = taskFrom('lost-job', 'loss.unemployment_claim');
    const search = resolveResources(task, usProfile).find((r) => r.kind === 'search')!;
    expect(search.url).toContain(encodeURIComponent('California'));
    expect(search.url).toContain(encodeURIComponent('United States'));
  });

  test('no profile still returns a usable search resource', () => {
    const task = taskFrom('lost-job', 'loss.unemployment_claim');
    const resources = resolveResources(task, null);
    expect(resources.length).toBeGreaterThan(0);
    expect(resources.some((r) => r.kind === 'search')).toBe(true);
  });

  test('domain portal fills in when no task-specific link exists', () => {
    const task = taskFrom('lost-job', 'loss.budget_triage');
    const resources = resolveResources(task, usProfile);
    expect(resources.some((r) => r.kind === 'portal' && r.url.includes('consumerfinance.gov'))).toBe(true);
  });

  test('immigration-to-Canada tasks point at IRCC regardless of user country', () => {
    const plan = generatePlan({ template: getEventTemplate('immigrate-canada')!, eventDate: '2027-03-01' });
    const task = plan.tasks.find((t) => t.id === 'imm.application')!;
    for (const profile of [usProfile, caProfile, null]) {
      const resources = resolveResources(task, profile);
      expect(resources.some((r) => r.url.includes('canada.ca'))).toBe(true);
    }
  });

  test('all resource URLs are https and deduplicated', () => {
    const plan = generatePlan({ template: getEventTemplate('moved')!, eventDate: '2026-09-01' });
    for (const task of plan.tasks) {
      for (const profile of [usProfile, caProfile, null]) {
        const resources = resolveResources(task, profile);
        const urls = resources.map((r) => r.url);
        expect(new Set(urls).size).toBe(urls.length);
        expect(urls.every((u) => u.startsWith('https://'))).toBe(true);
        expect(resources.length).toBeLessThanOrEqual(4);
      }
    }
  });

  test('country helpers', () => {
    expect(countryName('US')).toBe('United States');
    expect(COUNTRIES.some((c) => c.code === 'OTHER')).toBe(true);
  });
});
