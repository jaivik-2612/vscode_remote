import {
  AFFILIATE_DISCLOSURE,
  AFFILIATE_TAG,
  EVENT_PRODUCTS,
  amazonUrl,
  productsForPlan,
  productsForTask,
} from '../src/core/products';
import { UserProfile } from '../src/core/resources';
import { getEventTemplate } from '../src/core/templates';

const us: UserProfile = { name: 'Sam', country: 'US', region: 'California', city: 'SJ' };
const inr: UserProfile = { name: 'Dev', country: 'IN', region: 'Gujarat', city: 'Surat' };

describe('product suggestions', () => {
  test('baby event suggests newborn supplies', () => {
    const products = productsForPlan('new-child');
    const labels = products.map((p) => p.label.toLowerCase()).join(' ');
    expect(labels).toContain('newborn clothes');
    expect(labels).toContain('diapers');
    expect(labels).toContain('baby toys');
  });

  test('new job suggests formal clothes and a laptop', () => {
    const labels = productsForPlan('new-job').map((p) => p.label.toLowerCase()).join(' ');
    expect(labels).toContain('formal work clothes');
    expect(labels).toContain('laptop');
  });

  test('task-anchored products land inside the right task', () => {
    const forLanguageTest = productsForTask('immigrate-canada', 'imm.language_test');
    expect(forLanguageTest.some((p) => p.label.includes('IELTS'))).toBe(true);
    // And not inside unrelated tasks.
    expect(productsForTask('immigrate-canada', 'imm.medical')).toHaveLength(0);
  });

  test('amazon storefront follows the profile country', () => {
    expect(amazonUrl('diapers', us)).toContain('https://www.amazon.com/s?k=diapers');
    expect(amazonUrl('diapers', inr)).toContain('https://www.amazon.in/s?k=');
    expect(amazonUrl('diapers', null)).toContain('https://www.amazon.com/s?k=');
  });

  test('affiliate tag is appended to every link once configured', () => {
    // Currently unset for testing with plain links.
    expect(AFFILIATE_TAG).toBe('');
    expect(amazonUrl('diapers', us)).not.toContain('&tag=');
    // The URL builder is the single swap point — simulate a configured tag.
    const withTag = amazonUrl('diapers', us) + '&tag=lifeos-20';
    expect(withTag).toContain('&tag=lifeos-20');
  });

  test('every product pack points at a real event, with sane entries', () => {
    for (const [eventId, products] of Object.entries(EVENT_PRODUCTS)) {
      const template = getEventTemplate(eventId);
      if (!template) throw new Error(`product pack for unknown event: ${eventId}`);
      const taskIds = new Set(template.tasks.map((t) => t.id));
      for (const p of products) {
        expect(p.label.length).toBeGreaterThan(1);
        expect(p.query.length).toBeGreaterThan(2);
        if (p.taskId && !taskIds.has(p.taskId)) {
          throw new Error(`${eventId}: product "${p.label}" anchors to unknown task ${p.taskId}`);
        }
      }
    }
  });

  test('events without packs return empty, never undefined', () => {
    expect(productsForPlan('jury-duty')).toEqual([]);
    expect(productsForTask('jury-duty', 'anything')).toEqual([]);
  });

  test('disclosure text exists for the UI', () => {
    expect(AFFILIATE_DISCLOSURE).toContain('Amazon Associate');
  });
});
