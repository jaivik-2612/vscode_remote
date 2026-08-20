/**
 * Fair-value engine for stock options.
 *
 * Three engines sit behind this entry point, and they do different jobs:
 * `valuation()` prices a contract from assumptions you supply, while
 * `ensembleValuation()` starts from a price history, fits the volatility
 * regimes with Baum-Welch, and runs Black-Scholes and Monte Carlo on top of
 * what it finds.
 */

export * as stats from './stats.js';
export * as blackScholes from './blackScholes.js';
export * as binomial from './binomial.js';
export * as series from './series.js';
export * as monteCarlo from './monteCarlo.js';

export { impliedVol, priceBounds } from './impliedVol.js';
export { fitHmm, projectRegimes, viterbiPath, stationaryDistribution } from './hmm.js';
export { ensembleValuation } from './ensemble.js';
export {
  DAYS_PER_YEAR, yearsFromDays, yearsBetween,
  valuation, valueCurve, employeeGrantValue,
} from './valuation.js';
