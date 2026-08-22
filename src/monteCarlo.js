/**
 * Monte Carlo valuation and price projection.
 *
 * Two dynamics are available. Plain geometric Brownian motion is the process
 * Black-Scholes assumes, so running it is mostly a check that the simulation
 * agrees with the closed form. The regime-switching dynamics draw each step's
 * volatility from the HMM fitted by Baum-Welch and let the chain move between
 * regimes as the path evolves — that keeps the volatility-of-volatility that
 * a single averaged number throws away, which is what fattens the tails and
 * makes the simulated price differ from the analytic one.
 *
 * The same path set answers both questions the tool asks: discounted payoffs
 * give the option's fair value, and the terminal prices give the projected
 * distribution of the stock itself.
 */

import * as bs from './blackScholes.js';

/**
 * mulberry32 — small, fast, and good enough for pricing. Seeded explicitly so
 * a given set of inputs always produces the same number; a valuation that
 * changes every time you look at it is not much use.
 */
export function makeRng(seed = 1) {
  let state = seed >>> 0;
  return function next() {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Box-Muller, returning both normals so neither draw is wasted. */
export function makeNormalPairs(rng) {
  return function pair() {
    let u = rng();
    const v = rng();
    if (u < 1e-12) u = 1e-12;
    const radius = Math.sqrt(-2 * Math.log(u));
    const angle = 2 * Math.PI * v;
    return [radius * Math.cos(angle), radius * Math.sin(angle)];
  };
}

/** Draw a state index from a discrete distribution. */
function sampleState(distribution, u) {
  let cumulative = 0;
  for (let i = 0; i < distribution.length; i++) {
    cumulative += distribution[i];
    if (u < cumulative) return i;
  }
  return distribution.length - 1;
}

/**
 * Simulate price paths.
 *
 * Paths are generated in antithetic pairs: every path drawn with shocks Z is
 * matched by one drawn with -Z. The pair straddles the mean, so the average
 * of the two is far more stable than two independent draws would be.
 *
 * @param {object} options
 *   @param {number} options.spot
 *   @param {number} options.years        Horizon.
 *   @param {number} options.steps        Time steps along each path.
 *   @param {number} options.paths        Total paths; rounded up to an even number.
 *   @param {number} options.rate         Risk-free rate.
 *   @param {number} [options.yield]
 *   @param {number} [options.vol]        Required for 'gbm' dynamics.
 *   @param {object} [options.regimes]    Fitted HMM, for 'regime' dynamics.
 *   @param {'gbm'|'regime'} [options.dynamics]
 *   @param {'risk-neutral'|'real-world'} [options.measure]
 *     Risk-neutral drifts every path at the risk-free rate, which is the only
 *     measure under which a discounted payoff is a fair price. Real-world uses
 *     the drift actually estimated from the history, which is what a
 *     projection of where the stock lands needs.
 *   @param {number} [options.drift]      Real-world log drift, annualised.
 *   @param {number} [options.seed]
 * @returns {{paths: Float64Array, count: number, steps: number, dt: number}}
 *   Paths are stored flat, row-major: path `p` at step `s` is at
 *   `paths[p * (steps + 1) + s]`.
 */
export function simulatePaths(options) {
  const {
    spot, years, steps, paths: requested, rate, yield: q = 0,
    vol, regimes, dynamics = 'gbm', measure = 'risk-neutral', drift = 0, seed = 1,
  } = options;

  const count = Math.max(2, Math.ceil(requested / 2) * 2);
  const dt = years / steps;
  const sqrtDt = Math.sqrt(dt);
  const width = steps + 1;
  const out = new Float64Array(count * width);

  const rng = makeRng(seed);
  const normals = makeNormalPairs(rng);

  const usingRegimes = dynamics === 'regime' && regimes;
  const sigmas = usingRegimes ? regimes.sigmas.map((s) => s * Math.sqrt(regimes.periodsPerYear)) : null;
  const regimeDrifts = usingRegimes
    ? regimes.means.map((m) => m * regimes.periodsPerYear)
    : null;

  // Antithetic pairs advance together, sharing shocks up to a sign.
  for (let pair = 0; pair < count / 2; pair++) {
    const a = pair * 2;
    const b = a + 1;
    let logA = Math.log(spot);
    let logB = Math.log(spot);
    out[a * width] = spot;
    out[b * width] = spot;

    // Both members of a pair start in the same regime, so the only thing
    // that differs between them is the sign of the shocks.
    let stateA = usingRegimes ? sampleState(regimes.current, rng()) : 0;
    let stateB = stateA;

    for (let step = 1; step <= steps; step++) {
      const [z] = normals();

      const sigA = usingRegimes ? sigmas[stateA] : vol;
      const sigB = usingRegimes ? sigmas[stateB] : vol;
      const muA = measure === 'real-world'
        ? (usingRegimes ? regimeDrifts[stateA] : drift)
        : rate - q - 0.5 * sigA * sigA;
      const muB = measure === 'real-world'
        ? (usingRegimes ? regimeDrifts[stateB] : drift)
        : rate - q - 0.5 * sigB * sigB;

      logA += muA * dt + sigA * sqrtDt * z;
      logB += muB * dt - sigB * sqrtDt * z;
      out[a * width + step] = Math.exp(logA);
      out[b * width + step] = Math.exp(logB);

      if (usingRegimes) {
        stateA = sampleState(regimes.A[stateA], rng());
        stateB = sampleState(regimes.A[stateB], rng());
      }
    }
  }

  return { paths: out, count, steps, dt, width };
}

const payoffOf = (type, spot, strike) =>
  (type === 'put' ? Math.max(strike - spot, 0) : Math.max(spot - strike, 0));

/**
 * European price from a simulated path set.
 *
 * Uses the discounted terminal stock price as a control variate. Its
 * expectation is known exactly (spot x e^-qT), so the error the simulation
 * makes on the control tells us which way it erred on the payoff, and the
 * estimate can be corrected by that much. The regression coefficient is
 * estimated from the sample, which is what makes this reduce variance
 * whether the option is deep in or out of the money.
 */
export function europeanFromPaths(simulation, { strike, type, rate, yield: q = 0, spot, years }) {
  const { paths, count, width } = simulation;
  const discount = Math.exp(-rate * years);

  const payoffs = new Float64Array(count);
  const controls = new Float64Array(count);
  let payoffMean = 0;
  let controlMean = 0;

  for (let p = 0; p < count; p++) {
    const terminal = paths[p * width + width - 1];
    payoffs[p] = discount * payoffOf(type, terminal, strike);
    controls[p] = discount * terminal;
    payoffMean += payoffs[p];
    controlMean += controls[p];
  }
  payoffMean /= count;
  controlMean /= count;

  let covariance = 0;
  let controlVariance = 0;
  for (let p = 0; p < count; p++) {
    covariance += (payoffs[p] - payoffMean) * (controls[p] - controlMean);
    controlVariance += (controls[p] - controlMean) ** 2;
  }
  const beta = controlVariance > 0 ? covariance / controlVariance : 0;
  const controlTruth = spot * Math.exp(-q * years);

  let adjustedMean = 0;
  const adjusted = new Float64Array(count);
  for (let p = 0; p < count; p++) {
    adjusted[p] = payoffs[p] - beta * (controls[p] - controlTruth);
    adjustedMean += adjusted[p];
  }
  adjustedMean /= count;

  let variance = 0;
  for (let p = 0; p < count; p++) variance += (adjusted[p] - adjustedMean) ** 2;
  variance /= count - 1;

  // Antithetic paths come in correlated pairs, so the effective sample size
  // is the number of pairs. Treating each path as independent would report a
  // standard error roughly a factor of root-two too small.
  const standardError = Math.sqrt(variance / (count / 2));

  let rawVariance = 0;
  for (let p = 0; p < count; p++) rawVariance += (payoffs[p] - payoffMean) ** 2;
  rawVariance /= count - 1;

  return {
    price: adjustedMean,
    standardError,
    confidence95: [adjustedMean - 1.96 * standardError, adjustedMean + 1.96 * standardError],
    uncontrolledPrice: payoffMean,
    varianceReduction: rawVariance > 0 ? 1 - variance / rawVariance : 0,
  };
}

/**
 * American price by Longstaff-Schwartz least squares.
 *
 * Working backwards from expiry, the value of waiting is unknown along any
 * single path, so it is estimated by regressing the discounted continuation
 * value on the current price across all paths that are in the money. Compare
 * that fitted continuation against exercising now, and the better of the two
 * becomes the cash flow carried back another step.
 *
 * Only in-the-money paths enter the regression — out-of-the-money paths carry
 * no exercise decision and would drag the fit toward a region that never
 * matters.
 */
export function americanFromPaths(simulation, { strike, type, rate, years }) {
  const { paths, count, steps, width } = simulation;
  const dt = years / steps;
  const stepDiscount = Math.exp(-rate * dt);

  // Cash flow currently scheduled on each path, and when it lands.
  const cashflow = new Float64Array(count);
  const timing = new Int32Array(count);
  for (let p = 0; p < count; p++) {
    cashflow[p] = payoffOf(type, paths[p * width + steps], strike);
    timing[p] = steps;
  }

  const inMoney = new Int32Array(count);

  for (let step = steps - 1; step >= 1; step--) {
    let liveCount = 0;
    for (let p = 0; p < count; p++) {
      if (payoffOf(type, paths[p * width + step], strike) > 0) inMoney[liveCount++] = p;
    }
    if (liveCount < 4) continue; // too few points to fit anything meaningful

    // Normal equations for a quadratic basis {1, x, x^2}, x scaled by the
    // strike so the matrix stays well conditioned.
    let s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    let b0 = 0, b1 = 0, b2 = 0;
    for (let k = 0; k < liveCount; k++) {
      const p = inMoney[k];
      const x = paths[p * width + step] / strike;
      const y = cashflow[p] * Math.exp(-rate * dt * (timing[p] - step));
      const x2 = x * x;
      s0 += 1; s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2;
      b0 += y; b1 += y * x; b2 += y * x2;
    }

    const coefficients = solve3x3(
      [[s0, s1, s2], [s1, s2, s3], [s2, s3, s4]],
      [b0, b1, b2],
    );
    if (coefficients === null) continue; // singular: keep holding this step

    const [c0, c1, c2] = coefficients;
    for (let k = 0; k < liveCount; k++) {
      const p = inMoney[k];
      const price = paths[p * width + step];
      const exercise = payoffOf(type, price, strike);
      const x = price / strike;
      const continuation = c0 + c1 * x + c2 * x * x;
      if (exercise > continuation) {
        cashflow[p] = exercise;
        timing[p] = step;
      }
    }
  }

  let total = 0;
  const discounted = new Float64Array(count);
  for (let p = 0; p < count; p++) {
    discounted[p] = cashflow[p] * Math.exp(-rate * dt * timing[p]);
    total += discounted[p];
  }
  const mean = total / count;

  let variance = 0;
  for (let p = 0; p < count; p++) variance += (discounted[p] - mean) ** 2;
  variance /= count - 1;
  const standardError = Math.sqrt(variance / (count / 2));

  // Exercising immediately is always available, so it is a hard floor on the
  // price; the regression is an approximation and can land just below it.
  const immediate = payoffOf(type, paths[0], strike);
  return {
    price: Math.max(mean, immediate),
    standardError,
    confidence95: [mean - 1.96 * standardError, mean + 1.96 * standardError],
    exercisedEarly: countEarly(timing, steps) / count,
  };
}

function countEarly(timing, steps) {
  let early = 0;
  for (let i = 0; i < timing.length; i++) if (timing[i] < steps) early++;
  return early;
}

/** Gaussian elimination with partial pivoting on a 3x3 system. */
function solve3x3(matrix, rhs) {
  const m = matrix.map((row, i) => [...row, rhs[i]]);
  for (let col = 0; col < 3; col++) {
    let pivot = col;
    for (let row = col + 1; row < 3; row++) {
      if (Math.abs(m[row][col]) > Math.abs(m[pivot][col])) pivot = row;
    }
    if (Math.abs(m[pivot][col]) < 1e-12) return null;
    [m[col], m[pivot]] = [m[pivot], m[col]];
    for (let row = col + 1; row < 3; row++) {
      const factor = m[row][col] / m[col][col];
      for (let k = col; k < 4; k++) m[row][k] -= factor * m[col][k];
    }
  }
  const x = [0, 0, 0];
  for (let row = 2; row >= 0; row--) {
    let sum = m[row][3];
    for (let col = row + 1; col < 3; col++) sum -= m[row][col] * x[col];
    x[row] = sum / m[row][row];
  }
  return x;
}

/**
 * Distribution of the terminal price across a path set: the projection of
 * where the stock itself lands, as opposed to what an option on it is worth.
 */
export function terminalDistribution(simulation, { strike, spot, bins = 40 } = {}) {
  const { paths, count, width } = simulation;
  const terminal = new Float64Array(count);
  for (let p = 0; p < count; p++) terminal[p] = paths[p * width + width - 1];

  const sorted = Float64Array.from(terminal).sort();
  const quantile = (q) => {
    const position = (sorted.length - 1) * q;
    const low = Math.floor(position);
    const high = Math.ceil(position);
    return sorted[low] + (sorted[high] - sorted[low]) * (position - low);
  };

  let sum = 0;
  for (let p = 0; p < count; p++) sum += terminal[p];
  const mean = sum / count;

  let above = 0;
  if (Number.isFinite(strike)) {
    for (let p = 0; p < count; p++) if (terminal[p] > strike) above++;
  }

  // Probability of finishing above today's price — what a plain long (or
  // short) position cares about, where no strike exists.
  let aboveSpot = 0;
  if (Number.isFinite(spot)) {
    for (let p = 0; p < count; p++) if (terminal[p] > spot) aboveSpot++;
  }

  const low = sorted[0];
  const high = sorted[sorted.length - 1];
  const span = high - low || 1;
  const histogram = new Array(bins).fill(0);
  for (let p = 0; p < count; p++) {
    const index = Math.min(bins - 1, Math.floor(((terminal[p] - low) / span) * bins));
    histogram[index] += 1;
  }

  // A compact quantile grid (0.5% steps) lets callers evaluate the chance
  // of finishing beyond any level — break-evens included — without hauling
  // the whole path set around.
  const quantiles = Array.from({ length: 201 }, (unused, i) => quantile(i / 200));

  return {
    mean,
    quantiles,
    median: quantile(0.5),
    p5: quantile(0.05),
    p25: quantile(0.25),
    p75: quantile(0.75),
    p95: quantile(0.95),
    min: low,
    max: high,
    probAboveStrike: Number.isFinite(strike) ? above / count : null,
    probAboveSpot: Number.isFinite(spot) ? aboveSpot / count : null,
    histogram: histogram.map((frequency, index) => ({
      from: low + (span * index) / bins,
      to: low + (span * (index + 1)) / bins,
      frequency: frequency / count,
    })),
  };
}

/**
 * Convergence trace: the running price estimate as paths accumulate. Shows
 * whether the simulation has settled or is still wandering, which a single
 * final number cannot.
 */
export function convergenceTrace(simulation, contract, samples = 40) {
  const { count } = simulation;
  const trace = [];
  for (let i = 1; i <= samples; i++) {
    const subset = Math.max(2, Math.round((count * i) / samples / 2) * 2);
    const partial = {
      ...simulation,
      count: subset,
    };
    const { price, standardError } = europeanFromPaths(partial, contract);
    trace.push({ paths: subset, price, standardError });
  }
  return trace;
}

/**
 * Black-Scholes price of the same contract, for reference. Kept here so the
 * simulation's output can always be shown next to the closed form it is
 * meant to agree with under plain GBM.
 */
export function analyticReference(contract) {
  return bs.price(contract);
}
