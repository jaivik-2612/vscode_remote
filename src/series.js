/**
 * Turning a raw price history into the inputs the models need.
 *
 * Everything downstream works on log returns, so this is where a pasted
 * column of numbers becomes a return series with an annualisation factor
 * attached.
 */

/** Trading days in a year — the convention for annualising daily returns. */
export const TRADING_DAYS = 252;

/**
 * Parse a pasted price history.
 *
 * The awkward case is the comma, which is both a separator and a thousands
 * mark: "1,200.50" is one number but "100,101" is two. Nothing in the token
 * itself resolves that, so the decision is made from the surrounding text.
 * When the input also uses whitespace or semicolons to separate values, those
 * are taken as the separators and commas are read as thousands marks; when
 * commas are all there is, they must be the separators.
 *
 * That covers what people actually paste — a column out of a spreadsheet, or
 * a single comma-separated row — and leaves only genuinely ambiguous input
 * such as "1,200.50,1,210" undecidable, which it is.
 *
 * Anything that is not a positive number is skipped, so a header row, a blank
 * line or a stray currency symbol does not break the parse.
 *
 * @returns {number[]} prices in the order given (oldest first)
 */
export function parsePrices(text) {
  if (typeof text !== 'string') return [];

  const trimmed = text.trim();
  const hasOtherSeparators = /[\s;]/.test(trimmed);

  const normalised = hasOtherSeparators
    // A thousands mark is a comma between a digit and exactly three digits.
    ? trimmed.replace(/(?<=\d),(?=\d{3}(?!\d))/g, '')
    : trimmed;

  return normalised
    .split(/[\s,;]+/)
    .map((token) => token.replace(/[$£€¥]/g, '').trim())
    .filter((token) => token !== '')
    .map(Number)
    .filter((value) => Number.isFinite(value) && value > 0);
}

/**
 * Log returns of a price series. Log rather than simple returns because the
 * models below assume returns are additive across time.
 */
export function logReturns(prices) {
  const out = [];
  for (let i = 1; i < prices.length; i++) out.push(Math.log(prices[i] / prices[i - 1]));
  return out;
}

/** Sample mean. */
export function mean(values) {
  if (values.length === 0) return NaN;
  let total = 0;
  for (const value of values) total += value;
  return total / values.length;
}

/**
 * Sample standard deviation, with the Bessel correction. Volatility
 * estimated from a short window is biased low without it.
 */
export function stdev(values) {
  if (values.length < 2) return NaN;
  const m = mean(values);
  let sum = 0;
  for (const value of values) sum += (value - m) ** 2;
  return Math.sqrt(sum / (values.length - 1));
}

/**
 * Annualised volatility from a daily return series.
 *
 * @param {number[]} returns
 * @param {number} [periodsPerYear] 252 for daily data, 52 weekly, 12 monthly.
 */
export function historicalVol(returns, periodsPerYear = TRADING_DAYS) {
  return stdev(returns) * Math.sqrt(periodsPerYear);
}

/**
 * Exponentially weighted volatility (RiskMetrics). Weights recent returns
 * more heavily, so it reacts to a volatility shift far faster than a plain
 * trailing window — useful as a sanity check on the regime model.
 *
 * @param {number} [lambda] Decay factor; 0.94 is the RiskMetrics default.
 */
export function ewmaVol(returns, periodsPerYear = TRADING_DAYS, lambda = 0.94) {
  if (returns.length === 0) return NaN;
  // Seed with the sample variance so the first observations are not ignored.
  let variance = returns.length > 1 ? stdev(returns) ** 2 : returns[0] ** 2;
  for (const r of returns) variance = lambda * variance + (1 - lambda) * r * r;
  return Math.sqrt(variance * periodsPerYear);
}

/**
 * Annualised drift implied by the realised return series.
 *
 * Returns both the log drift (mu, what the simulation needs) and the
 * arithmetic expected return (mu + sigma^2/2, what a person means by
 * "expected return"). Conflating the two is a classic source of
 * over-optimistic projections.
 */
export function historicalDrift(returns, periodsPerYear = TRADING_DAYS) {
  const logDrift = mean(returns) * periodsPerYear;
  const variance = stdev(returns) ** 2 * periodsPerYear;
  return { logDrift, expectedReturn: logDrift + variance / 2 };
}

/**
 * Summary statistics for the return distribution. Skew and excess kurtosis
 * are the quickest way to see how badly the normality assumption behind
 * Black-Scholes is being violated.
 */
export function describe(returns, periodsPerYear = TRADING_DAYS) {
  const n = returns.length;
  if (n < 2) {
    return { count: n, vol: NaN, skew: NaN, excessKurtosis: NaN, min: NaN, max: NaN };
  }
  const m = mean(returns);
  const sd = stdev(returns);
  let third = 0;
  let fourth = 0;
  for (const r of returns) {
    third += ((r - m) / sd) ** 3;
    fourth += ((r - m) / sd) ** 4;
  }
  return {
    count: n,
    vol: sd * Math.sqrt(periodsPerYear),
    skew: third / n,
    excessKurtosis: fourth / n - 3,
    min: Math.min(...returns),
    max: Math.max(...returns),
  };
}
