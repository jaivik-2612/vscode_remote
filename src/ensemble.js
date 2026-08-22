/**
 * Runs the three engines over one set of inputs and lays their answers side
 * by side.
 *
 * The pipeline is deliberately ordered, because the models are not peers:
 *
 *   1. Baum-Welch fits a hidden Markov model to the return history and
 *      recovers a volatility per regime, the odds of switching, and which
 *      regime today sits in. It produces no price of its own — it produces
 *      the volatility the other two are missing.
 *   2. Black-Scholes prices the contract in closed form, once on plain
 *      trailing volatility and once on the regime-projected number, so the
 *      difference between them is exactly what the regime model contributed.
 *   3. Monte Carlo simulates paths whose volatility switches regime as they
 *      go, and prices from the discounted payoffs. Unlike step 2 it keeps
 *      the volatility-of-volatility, so where it disagrees with Black-Scholes
 *      it is quantifying what the closed form's single-number assumption costs.
 *
 * The same simulation, re-run under real-world drift instead of risk-neutral,
 * gives the projected distribution of the stock itself.
 */

import * as bs from './blackScholes.js';
import * as binomial from './binomial.js';
import { fitHmm, projectRegimes } from './hmm.js';
import {
  simulatePaths, europeanFromPaths, americanFromPaths, terminalDistribution,
} from './monteCarlo.js';
import {
  logReturns, historicalVol, ewmaVol, historicalDrift, describe, TRADING_DAYS,
} from './series.js';
import { valuation } from './valuation.js';

/**
 * @param {object} input
 *   @param {number[]} input.prices       Price history, oldest first.
 *   @param {number} [input.spot]         Defaults to the last price.
 *   @param {number} input.strike
 *   @param {number} input.days           Calendar days to expiry.
 *   @param {number} input.rate           Risk-free rate as a decimal.
 *   @param {number} [input.yield]
 *   @param {'call'|'put'} input.type
 *   @param {'european'|'american'} [input.style]
 *   @param {number} [input.states]       Hidden regimes to fit (2 or 3).
 *   @param {number} [input.paths]        Monte Carlo paths.
 *   @param {number} [input.seed]
 *   @param {number} [input.periodsPerYear] 252 daily, 52 weekly, 12 monthly.
 */
export function ensembleValuation(input) {
  const {
    prices, strike, days, rate, yield: q = 0, type, style = 'european',
    states = 2, paths = 20000, seed = 12345, periodsPerYear = TRADING_DAYS,
  } = input;

  if (!Array.isArray(prices) || prices.length < 30) {
    throw new RangeError(`need at least 30 prices to estimate anything, got ${prices?.length ?? 0}`);
  }
  if (!(days > 0)) throw new RangeError('days to expiry must be > 0');
  if (!(strike > 0)) throw new RangeError('strike must be > 0');

  const spot = input.spot ?? prices[prices.length - 1];
  const years = days / 365;
  const returns = logReturns(prices);

  /* ---------------- 1. the history, before any model ---------------- */

  const stats = describe(returns, periodsPerYear);
  const trailingVol = historicalVol(returns, periodsPerYear);
  const smoothedVol = ewmaVol(returns, periodsPerYear);
  const drift = historicalDrift(returns, periodsPerYear);

  /* ---------------- 2. Baum-Welch: what regime are we in? ---------------- */

  const hmm = fitHmm(returns, { states, periodsPerYear });
  const projection = projectRegimes(hmm, years);
  const regimeVol = projection.vol;

  // Fitting more states always improves the in-sample likelihood, so the
  // likelihood cannot tell you how many regimes the data supports. BIC can:
  // it charges for each extra parameter. Scoring the alternatives here is
  // what stops a spurious third regime — one that holds a fraction of a
  // percent of the time — from being read as a real market state.
  const candidates = [2, 3, 4]
    .filter((n) => n !== states && returns.length >= n * 10)
    .map((n) => {
      try {
        return { states: n, bic: fitHmm(returns, { states: n, periodsPerYear }).bic };
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  const scores = [...candidates, { states, bic: hmm.bic }].sort((a, b) => a.states - b.states);
  const preferred = scores.reduce((best, entry) => (entry.bic < best.bic ? entry : best), scores[0]);

  // A regime the chain spends almost no time in is a fitting artefact, not a
  // market state, however plausible its volatility looks.
  const negligible = hmm.stationary
    .map((share, index) => ({ share, index }))
    .filter((entry) => entry.share < 0.02)
    .map((entry) => entry.index);

  /* ---------------- 3. Black-Scholes on each volatility ---------------- */

  const contract = { spot, strike, time: years, rate, yield: q, type, style, steps: 400 };
  const onTrailing = valuation({ ...contract, vol: trailingVol });
  const onRegime = valuation({ ...contract, vol: regimeVol });

  /* ---------------- 4. Monte Carlo ---------------- */

  // One step per trading day, bounded so a long-dated option stays responsive
  // and a very short one still gets enough steps to decide early exercise.
  const steps = Math.min(252, Math.max(20, Math.round(years * periodsPerYear)));
  const shared = {
    spot, years, steps, paths, rate, yield: q,
    regimes: hmm, dynamics: 'regime', measure: 'risk-neutral', seed,
  };
  const payoff = { strike, type, rate, yield: q, spot, years };

  const regimePaths = simulatePaths(shared);
  const mcRegime = europeanFromPaths(regimePaths, payoff);

  // Plain GBM at the same volatility, as a control: this one has a closed
  // form, so any disagreement is simulation error rather than model
  // difference, and it calibrates how much to trust the regime number.
  const gbmPaths = simulatePaths({
    ...shared, dynamics: 'gbm', vol: regimeVol, regimes: null, seed: seed + 1,
  });
  const mcGbm = europeanFromPaths(gbmPaths, payoff);
  const gbmReference = bs.price({ ...contract, vol: regimeVol });

  const mcAmerican = style === 'american'
    ? americanFromPaths(regimePaths, { strike, type, rate, years })
    : null;

  /* ---------------- 5. where does the stock itself land? ---------------- */

  const realWorldPaths = simulatePaths({
    ...shared, measure: 'real-world', drift: drift.logDrift, seed: seed + 2,
  });
  const outlook = terminalDistribution(realWorldPaths, { strike, spot });

  /* ---------------- 6. reconcile ---------------- */

  const monteCarloValue = mcAmerican ? mcAmerican.price : mcRegime.price;
  const estimates = [
    { label: 'Black-Scholes, trailing volatility', value: onTrailing.fairValue },
    { label: 'Black-Scholes, regime volatility', value: onRegime.fairValue },
    { label: 'Monte Carlo, regime-switching', value: monteCarloValue },
  ];
  const values = estimates.map((e) => e.value);
  const low = Math.min(...values);
  const high = Math.max(...values);
  const consensus = values.reduce((sum, v) => sum + v, 0) / values.length;

  return {
    spot,
    strike,
    years,
    days,
    type,
    style,

    series: {
      observations: prices.length,
      returns: returns.length,
      periodsPerYear,
      trailingVol,
      smoothedVol,
      logDrift: drift.logDrift,
      expectedReturn: drift.expectedReturn,
      skew: stats.skew,
      excessKurtosis: stats.excessKurtosis,
      first: prices[0],
      last: prices[prices.length - 1],
    },

    hmm: {
      states: hmm.states,
      converged: hmm.converged,
      iterations: hmm.iterations,
      logLikelihood: hmm.logLikelihood,
      aic: hmm.aic,
      bic: hmm.bic,
      transition: hmm.A,
      annualisedVols: hmm.annualisedVols,
      annualisedDrifts: hmm.annualisedDrifts,
      stationary: hmm.stationary,
      current: hmm.current,
      expectedDurations: hmm.expectedDurations,
      posteriors: hmm.posteriors,
      viterbi: hmm.viterbi,
      history: hmm.history,
      /** Volatility the chain implies over this option's life. */
      projectedVol: regimeVol,
      regimePath: projection.path,
      /** BIC across candidate state counts, and which it prefers. */
      selection: { preferred: preferred.states, scores },
      /** States the chain almost never visits — artefacts, not regimes. */
      negligible,
    },

    volatility: {
      trailing: trailingVol,
      smoothed: smoothedVol,
      regime: regimeVol,
      /** What the regime model adds or removes versus the trailing number. */
      regimeAdjustment: regimeVol - trailingVol,
    },

    blackScholes: { onTrailing, onRegime },

    monteCarlo: {
      paths: regimePaths.count,
      steps,
      european: mcRegime,
      american: mcAmerican,
      value: monteCarloValue,
      /** GBM control: simulated vs closed form on identical assumptions. */
      control: {
        simulated: mcGbm.price,
        analytic: gbmReference,
        error: mcGbm.price - gbmReference,
        standardError: mcGbm.standardError,
        withinTolerance: Math.abs(mcGbm.price - gbmReference) < 1.96 * mcGbm.standardError,
      },
    },

    outlook,

    consensus: {
      estimates,
      value: consensus,
      low,
      high,
      spread: high - low,
      /** Disagreement as a share of the average price. */
      dispersion: consensus > 0 ? (high - low) / consensus : 0,
    },
  };
}
