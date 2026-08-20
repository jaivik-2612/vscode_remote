/**
 * Implied volatility: the volatility that makes a model reproduce a price
 * you can actually trade at.
 *
 * Option value is strictly increasing in volatility, so the root is unique
 * whenever the quoted price sits inside its no-arbitrage bounds. The solver
 * is a safeguarded Newton iteration: Newton steps for speed, a bisection
 * bracket underneath so a bad derivative can never send it off to infinity.
 */

import * as bs from './blackScholes.js';
import * as binomial from './binomial.js';

const MAX_VOL = 10;      // 1000% — far beyond anything quoted in practice
const MIN_VOL = 1e-9;
const MAX_ITERATIONS = 100;

/**
 * No-arbitrage bounds on an option's price, independent of volatility.
 *
 * @returns {{lower: number, upper: number}}
 */
export function priceBounds({ spot, strike, time, rate, yield: q = 0, type, american = false }) {
  const dfSpot = spot * Math.exp(-q * time);
  const dfStrike = strike * Math.exp(-rate * time);

  if (type === 'put') {
    const lower = american
      ? Math.max(strike - spot, 0)
      : Math.max(dfStrike - dfSpot, 0);
    return { lower, upper: american ? strike : dfStrike };
  }
  const lower = american
    ? Math.max(spot - strike, 0)
    : Math.max(dfSpot - dfStrike, 0);
  return { lower, upper: american ? spot : dfSpot };
}

/**
 * Solve for implied volatility.
 *
 * @param {object} args Standard pricing inputs plus:
 *   @param {number} args.price     The observed market price.
 *   @param {boolean} [args.american] Use a binomial tree instead of Black-Scholes.
 *   @param {number} [args.steps]   Tree steps when `american` is set.
 * @returns {{vol: number, iterations: number, priceAtVol: number,
 *   identifiable?: boolean}} `identifiable: false` means the quote sits at a
 *   price the model returns for a whole range of volatilities (an American
 *   option trading at intrinsic, say), so the volatility is not recoverable.
 * @throws {RangeError} When the price violates its no-arbitrage bounds, in
 *   which case no volatility can reproduce it.
 */
export function impliedVol(args) {
  const { price: target, american = false, ...inputs } = args;

  if (!Number.isFinite(target)) throw new RangeError('price must be a finite number');
  bs.assertInputs({ ...inputs, vol: 0 });

  const { lower, upper } = priceBounds({ ...inputs, american });
  const slack = 1e-10 * Math.max(1, inputs.strike);
  if (target < lower - slack) {
    throw new RangeError(
      `price ${target} is below the no-arbitrage floor of ${lower.toFixed(6)}`);
  }
  if (target > upper + slack) {
    throw new RangeError(
      `price ${target} is above the no-arbitrage ceiling of ${upper.toFixed(6)}`);
  }
  if (inputs.time === 0) {
    throw new RangeError('cannot imply volatility from an expired option');
  }

  const valueAt = american
    ? (vol) => binomial.price({ ...inputs, vol, american: true })
    : (vol) => bs.price({ ...inputs, vol });

  // An American option quoted at intrinsic is worth the same for every
  // volatility below its exercise boundary, so no single number is implied.
  // Report the floor and say so rather than pretending to a root.
  const floorPrice = valueAt(MIN_VOL);
  if (target <= floorPrice + slack) {
    return { vol: 0, iterations: 0, priceAtVol: floorPrice, identifiable: false };
  }
  const ceilingPrice = valueAt(MAX_VOL);
  if (target >= ceilingPrice - slack) {
    return { vol: MAX_VOL, iterations: 0, priceAtVol: ceilingPrice, identifiable: false };
  }

  let lo = MIN_VOL;
  let hi = MAX_VOL;
  let vol = initialGuess(inputs, target);
  const tolerance = 1e-10 * Math.max(1, inputs.spot);

  for (let i = 1; i <= MAX_ITERATIONS; i++) {
    if (!(vol > lo && vol < hi)) vol = 0.5 * (lo + hi);

    const value = valueAt(vol);
    const diff = value - target;
    if (Math.abs(diff) < tolerance) {
      return { vol, iterations: i, priceAtVol: value, identifiable: true };
    }

    if (diff > 0) hi = vol; else lo = vol;
    if (hi - lo < 1e-12) {
      return { vol: 0.5 * (lo + hi), iterations: i, priceAtVol: value, identifiable: true };
    }

    // Analytic vega is a good derivative for the tree too: early exercise
    // barely changes the volatility sensitivity, and the bracket catches
    // any step the approximation gets wrong.
    const slope = bs.vega({ ...inputs, vol });
    vol = slope > 1e-12 ? vol - diff / slope : 0.5 * (lo + hi);
  }

  const vertex = 0.5 * (lo + hi);
  return {
    vol: vertex,
    iterations: MAX_ITERATIONS,
    priceAtVol: valueAt(vertex),
    identifiable: true,
  };
}

/**
 * Brenner-Subrahmanyam approximation, which is exact-ish at the money and a
 * serviceable starting point elsewhere. Only the first Newton step depends
 * on it; the bracket handles the rest.
 */
function initialGuess({ spot, strike, time, rate, yield: q = 0 }, target) {
  const forward = spot * Math.exp((rate - q) * time);
  const guess = (Math.sqrt(2 * Math.PI) / Math.sqrt(time)) *
    (target / (0.5 * (forward + strike) * Math.exp(-rate * time)));
  return Number.isFinite(guess) && guess > 0.01 && guess < 3 ? guess : 0.3;
}
