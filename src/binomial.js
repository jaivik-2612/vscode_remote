/**
 * Cox-Ross-Rubinstein binomial tree, used for American-style options where
 * early exercise has value and no closed form exists.
 *
 * The tree is also exposed for European exercise so that the early-exercise
 * premium can be measured against a like-for-like model rather than against
 * Black-Scholes (whose discretisation error would contaminate the number).
 */

import { assertInputs, intrinsic } from './blackScholes.js';

const DEFAULT_STEPS = 400;
const MAX_STEPS = 50000;

/**
 * Roll a single tree back to today.
 *
 * Also returns the option values two steps into the tree. Because CRR has
 * u * d = 1, those nodes straddle today's spot and give clean, noise-free
 * delta, gamma and theta without bumping the inputs.
 *
 * @returns {{value: number, inner: null|{sUu: number, sUd: number, sDd: number,
 *   vUu: number, vUd: number, vDd: number, vU: number, vD: number,
 *   sU: number, sD: number, dt: number}}}
 */
function singleTree(inputs, steps) {
  const { spot, strike, time, vol, rate, yield: q = 0, type, american = true } = inputs;

  if (time === 0 || steps < 1) {
    return { value: intrinsic({ spot, strike, type }), inner: null };
  }
  // A CRR step is only a valid probability when a volatility move outruns the
  // drift over that step: |r - q| * sqrt(dt) < vol. Below that the tree needs
  // more steps than it is worth, and the price is within rounding of its
  // zero-volatility limit anyway.
  const needed = vol > 0 && rate !== q
    ? Math.ceil(2 * time * Math.pow((rate - q) / vol, 2))
    : 0;
  if (vol === 0 || needed > MAX_STEPS) {
    // Deterministic forward; an American holder takes the better of
    // exercising now and holding to expiry.
    const forward = spot * Math.exp((rate - q) * time);
    const held = Math.exp(-rate * time) *
      (type === 'put' ? Math.max(strike - forward, 0) : Math.max(forward - strike, 0));
    const value = american ? Math.max(held, intrinsic({ spot, strike, type })) : held;
    return { value, inner: null };
  }
  if (needed > steps) steps = needed;

  const dt = time / steps;
  const u = Math.exp(vol * Math.sqrt(dt));
  const d = 1 / u;
  const disc = Math.exp(-rate * dt);
  const p = (Math.exp((rate - q) * dt) - d) / (u - d);

  if (!(p > 0 && p < 1)) {
    // The step count above should rule this out; refine if floating point
    // leaves us on the boundary anyway.
    if (steps >= MAX_STEPS) throw new RangeError('binomial tree is unstable for these inputs');
    return singleTree(inputs, Math.min(steps * 2, MAX_STEPS));
  }

  const isPut = type === 'put';
  const values = new Float64Array(steps + 1);

  // Terminal payoffs. Node j has j up-moves and (steps - j) down-moves.
  for (let j = 0; j <= steps; j++) {
    const s = spot * Math.pow(u, 2 * j - steps);
    values[j] = isPut ? Math.max(strike - s, 0) : Math.max(s - strike, 0);
  }

  let inner = null;
  for (let i = steps - 1; i >= 0; i--) {
    for (let j = 0; j <= i; j++) {
      const continuation = disc * (p * values[j + 1] + (1 - p) * values[j]);
      if (american) {
        const s = spot * Math.pow(u, 2 * j - i);
        const exercise = isPut ? strike - s : s - strike;
        values[j] = exercise > continuation ? exercise : continuation;
      } else {
        values[j] = continuation;
      }
    }
    if (i === 2) {
      inner = {
        dt,
        sUu: spot * u * u, sUd: spot, sDd: spot * d * d,
        vUu: values[2], vUd: values[1], vDd: values[0],
        sU: spot * u, sD: spot * d, vU: 0, vD: 0,
      };
    }
    if (i === 1 && inner) {
      inner.vU = values[1];
      inner.vD = values[0];
    }
  }

  return { value: values[0], inner };
}

/**
 * Binomial price, averaged over `steps` and `steps + 1`.
 *
 * A CRR tree oscillates as the strike drifts between nodes, so the price
 * jitters up and down as steps are added. Averaging an odd and an even tree
 * cancels almost all of that jitter, which is what would otherwise make
 * Greeks and implied volatility noisy.
 *
 * The remaining error is smooth and O(1/steps) — averaging removes the
 * oscillation, it does not raise the convergence order. At the 400-step
 * default that is around 3e-4 on a $10 option.
 *
 * @param {import('./blackScholes.js').Inputs & {steps?: number, american?: boolean}} inputs
 */
export function price(inputs) {
  assertInputs(inputs);
  const steps = resolveSteps(inputs);
  return 0.5 * (singleTree(inputs, steps).value + singleTree(inputs, steps + 1).value);
}

function resolveSteps(inputs) {
  return Math.max(1, Math.floor(inputs.steps ?? DEFAULT_STEPS));
}

/** Delta, gamma and theta read straight off one tree's inner nodes. */
function treeGreeks({ value, inner }) {
  if (!inner) return null;
  const { sUu, sUd, sDd, vUu, vUd, vDd, sU, sD, vU, vD, dt } = inner;
  const delta = (vU - vD) / (sU - sD);
  const gamma = ((vUu - vUd) / (sUu - sUd) - (vUd - vDd) / (sUd - sDd)) /
    (0.5 * (sUu - sDd));
  // sUd equals today's spot, so this is a pure move through time.
  const thetaPerYear = (vUd - value) / (2 * dt);
  return { delta, gamma, thetaPerYear };
}

/**
 * Greeks for an American option.
 *
 * Delta, gamma and theta come from the tree's own geometry (see
 * `treeGreeks`); vega and rho have no such shortcut and are computed by
 * central differences on the averaged price. Conventions match the analytic
 * Greeks in `blackScholes.js`:
 *
 *   delta  change in value per 1.00 move in the underlying
 *   gamma  change in delta per 1.00 move in the underlying
 *   vega   change in value per 1 volatility point (per 0.01 of sigma)
 *   theta  change in value per calendar day (365-day year)
 *   rho    change in value per 1 percentage point of rate (per 0.01 of r)
 */
export function greeks(inputs) {
  assertInputs(inputs);
  const { vol, rate } = inputs;
  const steps = resolveSteps(inputs);

  const a = treeGreeks(singleTree(inputs, Math.max(steps, 3)));
  const b = treeGreeks(singleTree(inputs, Math.max(steps, 3) + 1));
  const blend = (key) => (a && b ? 0.5 * (a[key] + b[key]) : a ? a[key] : 0);

  const at = (overrides) => price({ ...inputs, ...overrides });

  // Bumps are large enough to clear the tree's own discretisation noise but
  // small enough that second-order curvature stays negligible.
  const hV = 2.5e-3;
  const vegaPerUnitVol = vol > hV
    ? (at({ vol: vol + hV }) - at({ vol: vol - hV })) / (2 * hV)
    : (at({ vol: vol + hV }) - at({})) / hV;

  const hR = 2.5e-3;
  const rhoPerUnitRate = (at({ rate: rate + hR }) - at({ rate: rate - hR })) / (2 * hR);

  const thetaPerYear = blend('thetaPerYear');
  return {
    delta: blend('delta'),
    gamma: blend('gamma'),
    vega: vegaPerUnitVol / 100,
    theta: thetaPerYear / 365,
    rho: rhoPerUnitRate / 100,
    vegaPerUnitVol,
    thetaPerYear,
    rhoPerUnitRate,
  };
}

/**
 * The spot at which an American holder becomes indifferent between exercising
 * today and holding on: below it for a put, above it for a call. Returns null
 * when early exercise is never optimal — a call on a non-dividend payer, for
 * instance.
 *
 * Found by bisection on `value of holding - value of exercising`.
 */
export function earlyExerciseBoundary(inputs) {
  const { strike, type } = inputs;
  const isPut = type === 'put';
  const tol = 1e-9 * strike;

  const excess = (s) => {
    const held = price({ ...inputs, spot: s, american: true });
    return held - intrinsic({ spot: s, strike, type });
  };

  // Deep in the money an exercisable option is worth exactly its intrinsic
  // value; if it is worth more even there, exercise is never optimal.
  const deepItm = isPut ? strike * 1e-4 : strike * 1e4;
  if (excess(deepItm) > tol) return null;

  let hold = strike;      // at the money, holding always wins
  let exercise = deepItm; // deep in the money, exercising wins
  for (let i = 0; i < 60; i++) {
    const midpoint = 0.5 * (hold + exercise);
    if (excess(midpoint) > tol) hold = midpoint;
    else exercise = midpoint;
  }
  return 0.5 * (hold + exercise);
}
