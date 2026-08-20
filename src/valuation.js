/**
 * Contract valuation: price, Greeks and the diagnostics that say how much to
 * trust the number.
 *
 * Split out from index.js so the ensemble can call it without importing the
 * package entry point back into itself.
 */

import * as bs from './blackScholes.js';
import * as binomial from './binomial.js';

export const DAYS_PER_YEAR = 365;

/** Convert a number of calendar days to the year fraction the models expect. */
export function yearsFromDays(days) {
  return days / DAYS_PER_YEAR;
}

/** Calendar days between two dates, as a year fraction. */
export function yearsBetween(from, to) {
  const ms = new Date(to).getTime() - new Date(from).getTime();
  return Math.max(0, ms / (1000 * 60 * 60 * 24 * DAYS_PER_YEAR));
}

/**
 * Value a contract and return everything worth showing about it.
 *
 * @param {object} contract
 *   @param {number} contract.spot
 *   @param {number} contract.strike
 *   @param {number} contract.time     Years to expiry.
 *   @param {number} contract.vol      Annualised volatility as a decimal.
 *   @param {number} contract.rate     Risk-free rate, continuously compounded.
 *   @param {number} [contract.yield]   Continuous dividend yield.
 *   @param {'call'|'put'} contract.type
 *   @param {'european'|'american'} [contract.style] Defaults to european.
 *   @param {number} [contract.steps]  Tree steps for American valuation.
 */
export function valuation(contract) {
  const { style = 'european', steps, ...inputs } = contract;
  bs.assertInputs(inputs);

  const european = bs.price(inputs);
  const isAmerican = style === 'american';

  let fair = european;
  let greeks = bs.greeks(inputs);
  let earlyExercise = null;
  let boundary = null;

  if (isAmerican) {
    const treeArgs = { ...inputs, steps, american: true };
    fair = binomial.price(treeArgs);
    greeks = binomial.greeks(treeArgs);
    // Compare tree against tree so the premium reflects early exercise only,
    // not the difference between two models.
    const euroTree = binomial.price({ ...inputs, steps, american: false });
    earlyExercise = Math.max(0, fair - euroTree);
    boundary = binomial.earlyExerciseBoundary({ ...treeArgs, steps: Math.min(steps ?? 200, 200) });
  }

  const intrinsic = bs.intrinsic(inputs);
  return {
    style,
    fairValue: fair,
    intrinsic,
    timeValue: fair - intrinsic,
    europeanValue: european,
    earlyExercisePremium: earlyExercise,
    earlyExerciseBoundary: boundary,
    greeks,
    probabilities: bs.probabilities(inputs),
    breakEven: inputs.type === 'put' ? inputs.strike - fair : inputs.strike + fair,
    forward: inputs.spot * Math.exp((inputs.rate - (inputs.yield ?? 0)) * inputs.time),
    moneyness: inputs.spot / inputs.strike,
    parityResidual: bs.parityResidual(inputs),
  };
}

/**
 * Fair value across a range of spot prices, for plotting the value curve
 * against the payoff at expiry.
 *
 * @returns {Array<{spot: number, value: number, payoff: number}>}
 */
export function valueCurve(contract, { from, to, points = 60 } = {}) {
  const { style = 'european', steps, ...inputs } = contract;
  const lo = from ?? inputs.spot * 0.5;
  const hi = to ?? inputs.spot * 1.5;
  const priceAt = style === 'american'
    // A coarser tree is plenty for a chart and keeps the curve interactive.
    ? (spot) => binomial.price({ ...inputs, spot, steps: steps ?? 120, american: true })
    : (spot) => bs.price({ ...inputs, spot });

  const out = [];
  for (let i = 0; i < points; i++) {
    const spot = lo + ((hi - lo) * i) / (points - 1);
    out.push({
      spot,
      value: priceAt(spot),
      payoff: bs.intrinsic({ ...inputs, spot }),
    });
  }
  return out;
}

/**
 * Grant-date fair value of an employee stock option under ASC 718.
 *
 * ESOs are not tradable and holders exercise early for reasons a tree cannot
 * see, so the standard practice is Black-Scholes run over the *expected term*
 * rather than the contractual term. The expense per grant is then reduced by
 * the share of options expected to be forfeited before vesting.
 *
 * @param {object} grant
 *   @param {number} grant.spot          Fair value of a share at grant.
 *   @param {number} grant.strike        Exercise price.
 *   @param {number} grant.expectedTerm  Expected term in years.
 *   @param {number} grant.vol           Expected volatility.
 *   @param {number} grant.rate          Risk-free rate over the expected term.
 *   @param {number} [grant.yield]       Expected dividend yield.
 *   @param {number} [grant.quantity]    Options granted. Defaults to 1.
 *   @param {number} [grant.forfeitureRate] Annual pre-vest forfeiture rate.
 *   @param {number} [grant.vestingYears]   Years to full vest.
 */
export function employeeGrantValue(grant) {
  const {
    spot, strike, expectedTerm, vol, rate, yield: q = 0,
    quantity = 1, forfeitureRate = 0, vestingYears = 0,
  } = grant;

  const inputs = { spot, strike, time: expectedTerm, vol, rate, yield: q, type: 'call' };
  const perOption = bs.price(inputs);
  const grossValue = perOption * quantity;

  // Survival to vest, compounding the annual forfeiture rate over the
  // vesting period.
  const retention = Math.pow(1 - forfeitureRate, vestingYears);
  const expectedToVest = quantity * retention;

  return {
    perOption,
    quantity,
    grossValue,
    retention,
    expectedToVest,
    expectedExpense: perOption * expectedToVest,
    annualExpense: vestingYears > 0 ? (perOption * expectedToVest) / vestingYears : null,
    greeks: bs.greeks(inputs),
  };
}
