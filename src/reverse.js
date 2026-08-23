/**
 * Reverse mode: what would have to be true for the market's price to be fair?
 *
 * Implied volatility already answers one version of this — it restates a
 * price as the volatility that produces it. This restates the same price in
 * a unit the app's own regime model supplies: the share of the option's life
 * the market must expect to spend in the turbulent regime.
 *
 * The inversion is exact rather than fitted. `projectRegimes` builds its
 * horizon volatility as a variance blend of the fitted regime volatilities,
 * weighted by the time the Markov chain expects to spend in each:
 *
 *     sigma_projected^2  =  sum_i  w_i * sigma_i^2
 *
 * With the two extreme regimes bracketing the range, any horizon volatility
 * between them corresponds to exactly one turbulent weight:
 *
 *     w  =  (sigma^2 - sigma_calm^2) / (sigma_turbulent^2 - sigma_calm^2)
 *
 * So an implied volatility becomes an implied regime mix. The honest part is
 * what happens outside the bracket: a market price can imply a volatility
 * this stock has never shown in either regime, and then no mix explains it.
 * That case is reported, not clamped away.
 */

import { impliedVol } from './impliedVol.js';
import * as bs from './blackScholes.js';

/**
 * Turns a quoted market price into the regime mix that would justify it.
 *
 * @param {object} args
 * @param {number} args.marketPrice   what the option is quoted at
 * @param {object} args.contract      {spot, strike, time, rate, yield, type}
 * @param {boolean} [args.american]   invert against a binomial tree instead of
 *                                    the closed form, matching the contract
 * @param {number[]} args.regimeVols  annualised volatility of each fitted regime
 * @param {number} args.modelWeight   turbulent share the chain itself projects
 * @param {number} args.historicalWeight  long-run share, from the stationary distribution
 */
export function impliedRegimeMix({
  marketPrice, contract, regimeVols, modelWeight, historicalWeight,
  american = false,
}) {
  if (!Array.isArray(regimeVols) || regimeVols.length < 2) {
    return { state: 'not-applicable', reason: 'needs at least two fitted regimes' };
  }
  if (!(marketPrice > 0)) {
    return { state: 'not-applicable', reason: 'no market price entered' };
  }

  // impliedVol throws when the quote breaches the no-arbitrage bounds, and
  // reports identifiable:false when it sits on a flat spot where every
  // volatility gives the same price. Both mean "no regime mix explains this",
  // for different reasons, and both are worth saying out loud.
  let solved;
  try {
    solved = impliedVol({ ...contract, price: marketPrice, american });
  } catch (error) {
    return {
      state: 'no-solution',
      reason: `That price cannot come from any volatility: ${error.message}.`,
    };
  }
  if (!solved || !Number.isFinite(solved.vol)) {
    return { state: 'no-solution', reason: 'No volatility reproduces this price.' };
  }
  if (solved.identifiable === false) {
    // Same condition the vega guard below catches, reported by the solver
    // when the quote sits exactly on the floor or ceiling. One state, so the
    // UI says one thing.
    return {
      state: 'insensitive',
      impliedVolatility: solved.vol,
      perVolPoint: 0,
      reason: 'At this price the option barely moves with volatility, so no ' +
        'single regime mix is implied — every mix fits about equally well.',
    };
  }

  const impliedVolatility = solved.vol;

  // Deep in or far out of the money, an option's price barely responds to
  // volatility, so the arithmetic still returns a number but that number is
  // not meaningfully implied by the quote — a one-cent difference in the
  // price would move it by tens of percentage points. `impliedVol` only
  // reports this at the exact floor and ceiling; the useless region is much
  // wider than that, and vega is what measures it.
  const { vega } = bs.greeks({ ...contract, vol: impliedVolatility });
  const perVolPoint = Math.abs(vega);
  if (perVolPoint < Math.max(0.01, 0.002 * marketPrice)) {
    return {
      state: 'insensitive',
      impliedVolatility,
      perVolPoint,
      reason: 'This contract is so far from the strike that its price hardly ' +
        'moves with volatility — a one-point change in volatility shifts it by ' +
        `about ${perVolPoint < 0.005 ? 'less than half a cent' : perVolPoint.toFixed(2)}. ` +
        'Almost any mix of regimes fits the quote, so none is really implied by it.',
    };
  }

  const calm = Math.min(...regimeVols);
  const turbulent = Math.max(...regimeVols);

  const span = turbulent ** 2 - calm ** 2;
  if (!(span > 0)) {
    return { state: 'not-applicable', reason: 'the fitted regimes have the same volatility' };
  }
  const weight = (impliedVolatility ** 2 - calm ** 2) / span;

  // Outside the bracket the question has no answer, and saying so is more
  // useful than reporting a weight of 1.4 or -0.2 as though it meant
  // something. The tolerance keeps a quote that sits exactly on a regime's
  // own volatility from being called out of range by one float ulp.
  const EDGE = 1e-9;
  const state = weight < -EDGE ? 'below-calmest'
    : weight > 1 + EDGE ? 'above-most-turbulent'
    : 'ok';

  return {
    state,
    impliedVolatility,
    calmVol: calm,
    turbulentVol: turbulent,
    /** Share of the option's life the market implies in the turbulent regime. */
    impliedWeight: weight,
    modelWeight,
    historicalWeight,
    /** Positive: the market implies more turbulence than the chain projects. */
    versusModel: Number.isFinite(modelWeight) ? weight - modelWeight : null,
    versusHistory: Number.isFinite(historicalWeight) ? weight - historicalWeight : null,
  };
}

/**
 * The turbulent-regime share implied by a projected regime path.
 *
 * `projectRegimes` returns the distribution over regimes at each step; the
 * variance blend weights each regime by the time spent in it, so the
 * comparable weight is the time-average of the most turbulent regime's
 * probability — not its probability at the end of the horizon.
 */
export function projectedTurbulentWeight(regimePath, regimeVols) {
  if (!Array.isArray(regimePath) || !regimePath.length) return null;
  if (!Array.isArray(regimeVols) || regimeVols.length < 2) return null;
  const turbulent = regimeVols.indexOf(Math.max(...regimeVols));
  // The path carries one extra entry: the distribution after the final step,
  // which no step's variance was drawn from.
  const steps = regimePath.slice(0, Math.max(1, regimePath.length - 1));
  const total = steps.reduce((sum, dist) => sum + (dist[turbulent] ?? 0), 0);
  return total / steps.length;
}
