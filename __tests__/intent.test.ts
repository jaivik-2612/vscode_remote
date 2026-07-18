import { bestMatch, matchIntent } from '../src/core/intent';

describe('intent matching', () => {
  test('"I moved." matches the moving event', () => {
    const match = bestMatch('I moved.');
    expect(match?.event.id).toBe('moved');
    expect(match?.matchedOn.length).toBeGreaterThan(0);
  });

  test('"I started a business" matches the business event', () => {
    expect(bestMatch('I started a business')?.event.id).toBe('started-business');
  });

  test('"I want to immigrate to Canada" matches the immigration event', () => {
    expect(bestMatch('I want to immigrate to Canada')?.event.id).toBe('immigrate-canada');
  });

  test('paraphrases still match via keywords', () => {
    // Ambiguous between moving and a first apartment — both should surface.
    const leaseIds = matchIntent('just signed a lease on a new apartment across town')
      .slice(0, 3)
      .map((m) => m.event.id);
    expect(leaseIds).toContain('moved');
    expect(bestMatch('thinking about getting canadian permanent residence')?.event.id).toBe(
      'immigrate-canada'
    );
    expect(bestMatch('incorporating an LLC for my new company')?.event.id).toBe('started-business');
    expect(bestMatch('going freelance full time')?.event.id).toBe('started-freelancing');
  });

  test('phrase matches outrank keyword-only matches', () => {
    const matches = matchIntent('i moved to canada');
    expect(matches.length).toBeGreaterThanOrEqual(2);
    const ids = matches.map((m) => m.event.id);
    expect(ids).toContain('moved');
    expect(ids).toContain('immigrate-canada');
    // "i moved" is an exact phrase; it should beat canada's keyword hits.
    expect(matches[0].event.id).toBe('moved');
  });

  test('milestone events match', () => {
    expect(bestMatch('i graduated college')?.event.id).toBe('graduated-college');
    expect(bestMatch('I just turned 18')?.event.id).toBe('turned-18');
    expect(bestMatch('we bought a house')?.event.id).toBe('bought-house');
    expect(bestMatch('I am retiring next spring')?.event.id).toBe('retired');
    expect(bestMatch('we got divorced')?.event.id).toBe('got-divorced');
  });

  test('important events match', () => {
    expect(bestMatch('I got a new job')?.event.id).toBe('new-job');
    expect(bestMatch('I was laid off yesterday')?.event.id).toBe('lost-job');
    expect(bestMatch('bought a used car')?.event.id).toBe('bought-car');
    expect(bestMatch('my father passed away')?.event.id).toBe('loved-one-passed');
  });

  test('leisure events match', () => {
    expect(bestMatch('I planned a family trip to Europe')?.event.id).toBe('trip-abroad');
    expect(bestMatch('we adopted a puppy')?.event.id).toBe('new-pet');
    expect(bestMatch('renovating the kitchen this fall')?.event.id).toBe('home-renovation');
  });

  test("the long tail matches: birthday party, anniversary, and friends", () => {
    expect(bestMatch("i planned my son's 5th birthday party")?.event.id).toBe('kids-birthday-party');
    expect(bestMatch('planned my marriage anniversary')?.event.id).toBe('wedding-anniversary');
    expect(bestMatch('I lost my wallet yesterday')?.event.id).toBe('lost-wallet');
    expect(bestMatch('we are hosting thanksgiving this year')?.event.id).toBe('holiday-hosting');
    expect(bestMatch('getting scuba certified')?.event.id).toBe('scuba');
    expect(bestMatch('my passport needs renewing')?.event.id).toBe('passport-renewal');
    expect(bestMatch('planning our honeymoon')?.event.id).toBe('honeymoon');
    expect(bestMatch('i turned 30 last week')?.event.id).toBe('turned-30');
  });

  test('unrelated input matches nothing', () => {
    expect(matchIntent('what is the weather like today')).toHaveLength(0);
    expect(matchIntent('')).toHaveLength(0);
    expect(matchIntent('   ')).toHaveLength(0);
  });

  test('matching is case- and punctuation-insensitive', () => {
    expect(bestMatch("I'M MOVING!!!")?.event.id).toBe('moved');
  });
});
