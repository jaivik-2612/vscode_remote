/**
 * Black-Scholes-Merton pricing for European options on an asset paying a
 * continuous dividend yield `q`.
 *
 * All rates are continuously compounded and expressed per year as decimals
 * (0.05 = 5%). Time `t` is in years.
 */

import { normCdf, normPdf } from './stats.js';

/** @typedef {'call'|'put'} OptionType */

/**
 * @typedef {object} Inputs
 * @property {number} spot   Current price of the underlying (S).
 * @property {number} strike Strike price (K).
 * @property {number} time   Time to expiry in years (T).
 * @property {number} vol    Annualised volatility (sigma), e.g. 0.25.
 * @property {number} rate   Risk-free rate (r), continuously compounded.
 * @property {number} [yield] Continuous dividend yield (q). Defaults to 0.
 * @property {OptionType} type
 */

const CALL = 'call';
const PUT = 'put';

function sign(type) {
  return type === PUT ? -1 : 1;
}

export function assertInputs({ spot, strike, time, vol, rate, type }) {
  if (!(spot > 0)) throw new RangeError('spot must be > 0');
  if (!(strike > 0)) throw new RangeError('strike must be > 0');
  if (!(time >= 0)) throw new RangeError('time must be >= 0');
  if (!(vol >= 0)) throw new RangeError('vol must be >= 0');
  if (!Number.isFinite(rate)) throw new RangeError('rate must be finite');
  if (type !== CALL && type !== PUT) throw new RangeError(`unknown option type: ${type}`);
}

/**
 * Intrinsic value of the option if it were exercised right now.
 */
export function intrinsic({ spot, strike, type }) {
  return type === PUT ? Math.max(strike - spot, 0) : Math.max(spot - strike, 0);
}

/**
 * d1 and d2 terms. Returns null when the distribution is degenerate
 * (zero time or zero volatility), where the closed form has no d1/d2.
 */
export function dTerms({ spot, strike, time, vol, rate, yield: q = 0 }) {
  const sqrtT = Math.sqrt(time);
  const denom = vol * sqrtT;
  if (denom <= 0) return null;
  const d1 = (Math.log(spot / strike) + (rate - q + 0.5 * vol * vol) * time) / denom;
  return { d1, d2: d1 - denom, sqrtT };
}

/**
 * European option value under Black-Scholes-Merton.
 *
 * Degenerate cases collapse to the discounted payoff of the forward, which
 * keeps the function continuous as time or volatility approach zero.
 *
 * @param {Inputs} inputs
 * @returns {number}
 */
export function price(inputs) {
  assertInputs(inputs);
  const { spot, strike, time, rate, yield: q = 0, type } = inputs;

  const terms = dTerms(inputs);
  if (terms === null) {
    // Zero vol or zero time: the payoff is deterministic given the forward.
    const forward = spot * Math.exp((rate - q) * time);
    const payoff = type === PUT ? Math.max(strike - forward, 0) : Math.max(forward - strike, 0);
    return payoff * Math.exp(-rate * time);
  }

  const { d1, d2 } = terms;
  const w = sign(type);
  const dfSpot = spot * Math.exp(-q * time);
  const dfStrike = strike * Math.exp(-rate * time);
  return w * (dfSpot * normCdf(w * d1) - dfStrike * normCdf(w * d2));
}

/**
 * Analytic Greeks for a European option.
 *
 * Conventions (chosen to match how desks and broker screens quote them):
 *   delta  change in value per 1.00 move in the underlying
 *   gamma  change in delta per 1.00 move in the underlying
 *   vega   change in value per 1 volatility *point* (i.e. per 0.01 of sigma)
 *   theta  change in value per calendar day (365-day year)
 *   rho    change in value per 1 percentage point of rate (per 0.01 of r)
 *
 * `thetaPerYear`, `vegaPerUnitVol` and `rhoPerUnitRate` expose the raw
 * per-unit derivatives for callers doing further maths.
 *
 * @param {Inputs} inputs
 */
export function greeks(inputs) {
  assertInputs(inputs);
  const { spot, strike, time, vol, rate, yield: q = 0, type } = inputs;
  const w = sign(type);
  const carry = Math.exp(-q * time);
  const disc = Math.exp(-rate * time);

  const terms = dTerms(inputs);
  if (terms === null) {
    // Degenerate: delta is 0 or the carry factor, everything else vanishes.
    const forward = spot * Math.exp((rate - q) * time);
    const itm = type === PUT ? forward < strike : forward > strike;
    const delta = itm ? w * carry : 0;
    return finalise({
      delta,
      gamma: 0,
      vegaPerUnitVol: 0,
      thetaPerYear: itm ? w * (q * spot * carry - rate * strike * disc) : 0,
      rhoPerUnitRate: itm ? w * strike * time * disc : 0,
    });
  }

  const { d1, d2, sqrtT } = terms;
  const pdf = normPdf(d1);

  const delta = w * carry * normCdf(w * d1);
  const gamma = (carry * pdf) / (spot * vol * sqrtT);
  const vegaPerUnitVol = spot * carry * pdf * sqrtT;
  const thetaPerYear =
    -(spot * carry * pdf * vol) / (2 * sqrtT) +
    w * q * spot * carry * normCdf(w * d1) -
    w * rate * strike * disc * normCdf(w * d2);
  const rhoPerUnitRate = w * strike * time * disc * normCdf(w * d2);

  return finalise({ delta, gamma, vegaPerUnitVol, thetaPerYear, rhoPerUnitRate });
}

function finalise({ delta, gamma, vegaPerUnitVol, thetaPerYear, rhoPerUnitRate }) {
  return {
    delta,
    gamma,
    vega: vegaPerUnitVol / 100,
    theta: thetaPerYear / 365,
    rho: rhoPerUnitRate / 100,
    vegaPerUnitVol,
    thetaPerYear,
    rhoPerUnitRate,
  };
}

/**
 * Vega expressed per unit of volatility. Broken out because the implied
 * volatility solver needs the raw derivative, not the per-point version.
 */
export function vega(inputs) {
  assertInputs(inputs);
  const terms = dTerms(inputs);
  if (terms === null) return 0;
  const { spot, time, yield: q = 0 } = inputs;
  return spot * Math.exp(-q * time) * normPdf(terms.d1) * terms.sqrtT;
}

/**
 * Risk-neutral probability that the option finishes in the money, and the
 * probability of the spot ever touching the strike before expiry.
 *
 * These are risk-neutral, not real-world, probabilities: they use the
 * risk-free drift, so read them as "what the option's price implies",
 * not as a forecast.
 */
export function probabilities(inputs) {
  assertInputs(inputs);
  const { spot, strike, time, vol, rate, yield: q = 0, type } = inputs;
  const terms = dTerms(inputs);
  if (terms === null) {
    const forward = spot * Math.exp((rate - q) * time);
    const itm = type === PUT ? forward < strike : forward > strike;
    return { itm: itm ? 1 : 0, touch: itm ? 1 : 0 };
  }

  const { d2 } = terms;
  const itm = type === PUT ? normCdf(-d2) : normCdf(d2);

  // Probability that the spot touches the strike at any point before expiry.
  // In log space the spot is an arithmetic Brownian motion with drift
  // mu = r - q - sigma^2/2, and this is its first-passage probability to the
  // barrier m = log(K / S).
  const mu = rate - q - 0.5 * vol * vol;
  const sqrtT = terms.sqrtT;
  const m = Math.log(strike / spot);

  // Already there: the strike is touched at time zero.
  if (m === 0) return { itm, touch: 1 };

  // Reflecting a downward barrier turns it into an upward one with the drift
  // reversed, which lets both directions share the formula below. Getting
  // this sign wrong quietly returns a plausible number, not an error.
  const distance = Math.abs(m);
  const drift = m > 0 ? mu : -mu;
  const scale = vol * sqrtT;
  const reflection = Math.exp((2 * mu * m) / (vol * vol));
  const direct = normCdf((-distance + drift * time) / scale);
  const reflected = normCdf((-distance - drift * time) / scale);

  // The reflection factor can overflow while the CDF it multiplies underflows.
  // Their product is a probability either way, so drop a non-finite term
  // rather than letting Infinity * 0 poison the result.
  const second = reflection * reflected;
  const touch = Math.min(1, Math.max(0, direct + (Number.isFinite(second) ? second : 0)));

  return { itm, touch };
}

/**
 * Put-call parity residual: C - P - (S e^-qT - K e^-rT).
 * A correct European pricer returns ~0 here for any inputs.
 */
export function parityResidual(inputs) {
  const call = price({ ...inputs, type: CALL });
  const put = price({ ...inputs, type: PUT });
  const { spot, strike, time, rate, yield: q = 0 } = inputs;
  return call - put - (spot * Math.exp(-q * time) - strike * Math.exp(-rate * time));
}
