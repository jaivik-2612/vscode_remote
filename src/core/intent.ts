import { EVENT_CATALOG } from './templates';
import { IntentMatch, LifeEventTemplate } from './types';

/**
 * Matches free-form user input ("I moved", "we're having a baby") against the
 * event catalog. Deliberately simple and fully offline: exact/substring phrase
 * matching scores highest, then keyword overlap. Returns ranked matches with
 * the evidence that produced them, so the UI can explain itself.
 */

function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[’']/g, "'")
    .replace(/[^a-z0-9'\s-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function tokenize(text: string): string[] {
  return normalize(text).split(' ').filter(Boolean);
}

/** Per-word so longer, more specific phrases outrank short generic ones. */
const PHRASE_WORD_SCORE = 10;
const KEYWORD_SCORE = 2;

function scoreEvent(input: string, event: LifeEventTemplate): IntentMatch {
  const norm = normalize(input);
  const tokens = new Set(tokenize(input));
  let score = 0;
  const matchedOn: string[] = [];

  for (const phrase of event.triggerPhrases) {
    const normPhrase = normalize(phrase);
    if (norm.includes(normPhrase)) {
      score += PHRASE_WORD_SCORE * normPhrase.split(' ').length;
      matchedOn.push(phrase);
    }
  }
  for (const keyword of event.keywords) {
    if (tokens.has(normalize(keyword))) {
      score += KEYWORD_SCORE;
      matchedOn.push(keyword);
    }
  }
  return { event, score, matchedOn };
}

/**
 * Rank catalog events against the input. Returns only events with a non-zero
 * score, best first. Empty input returns no matches.
 */
export function matchIntent(
  input: string,
  catalog: LifeEventTemplate[] = EVENT_CATALOG
): IntentMatch[] {
  if (!normalize(input)) return [];
  return catalog
    .map((event) => scoreEvent(input, event))
    .filter((m) => m.score > 0)
    .sort((a, b) => b.score - a.score);
}

/** The single best match, or undefined when nothing in the catalog fits. */
export function bestMatch(
  input: string,
  catalog: LifeEventTemplate[] = EVENT_CATALOG
): IntentMatch | undefined {
  return matchIntent(input, catalog)[0];
}
