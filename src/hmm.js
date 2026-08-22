/**
 * Gaussian hidden Markov model fitted by Baum-Welch.
 *
 * Baum-Welch does not price anything — it is expectation-maximisation for an
 * HMM. What it gives us here is the piece the pricing models cannot supply
 * for themselves: the market moves between calm and turbulent regimes, and a
 * single volatility number averages them into something that describes
 * neither. Fitting a two- or three-state model to the return series recovers
 * a volatility per regime, the odds of switching between them, and which one
 * we are in now. Propagating that chain over the option's life gives the
 * expected variance to expiry, which is what Black-Scholes and the Monte
 * Carlo simulation then consume.
 *
 * Everything runs on scaled forward-backward recursions, so likelihoods stay
 * in range on long series instead of underflowing to zero.
 */

import { TRADING_DAYS } from './series.js';

/** Volatility is floored during EM: a state that collapses onto a single
 *  observation drives its variance to zero and the likelihood to infinity. */
const MIN_SIGMA = 1e-6;

/** Gaussian emission density for observation `x` in a state. */
function emission(x, mean, sigma) {
  const z = (x - mean) / sigma;
  return Math.exp(-0.5 * z * z) / (sigma * Math.sqrt(2 * Math.PI));
}

/**
 * Starting parameters, chosen deterministically so the same series always
 * produces the same fit.
 *
 * Sorting by absolute return and splitting into equal groups seeds the states
 * as quiet-through-violent from the outset. Random starts routinely converge
 * to a local optimum that mixes the regimes together.
 */
function seedParameters(returns, states) {
  const byMagnitude = [...returns].sort((a, b) => Math.abs(a) - Math.abs(b));
  const size = Math.floor(byMagnitude.length / states);
  const means = [];
  const sigmas = [];

  for (let s = 0; s < states; s++) {
    const from = s * size;
    const to = s === states - 1 ? byMagnitude.length : from + size;
    const group = byMagnitude.slice(from, to);
    const m = group.reduce((sum, r) => sum + r, 0) / group.length;
    const variance = group.reduce((sum, r) => sum + (r - m) ** 2, 0) / Math.max(1, group.length - 1);
    means.push(m);
    sigmas.push(Math.max(Math.sqrt(variance), MIN_SIGMA));
  }

  // Persistent chain: regimes last, so most of the mass sits on the diagonal.
  const stay = 0.95;
  const A = Array.from({ length: states }, (unusedRow, i) =>
    Array.from({ length: states }, (unusedCol, j) =>
      (i === j ? stay : (1 - stay) / (states - 1))));

  return { pi: Array(states).fill(1 / states), A, means, sigmas };
}

/**
 * Scaled forward pass.
 * @returns {{alpha: number[][], scale: number[], logLikelihood: number}}
 */
function forward(returns, { pi, A, means, sigmas }) {
  const T = returns.length;
  const n = pi.length;
  const alpha = Array.from({ length: T }, () => new Array(n).fill(0));
  const scale = new Array(T).fill(0);
  let logLikelihood = 0;

  for (let i = 0; i < n; i++) alpha[0][i] = pi[i] * emission(returns[0], means[i], sigmas[i]);
  let total = alpha[0].reduce((sum, v) => sum + v, 0);
  // A zero total means every state calls this observation impossible; fall
  // back to a flat posterior rather than propagating NaN through the fit.
  scale[0] = total > 0 ? 1 / total : 1;
  for (let i = 0; i < n; i++) alpha[0][i] = total > 0 ? alpha[0][i] * scale[0] : 1 / n;
  logLikelihood += Math.log(total > 0 ? total : Number.MIN_VALUE);

  for (let t = 1; t < T; t++) {
    for (let j = 0; j < n; j++) {
      let carried = 0;
      for (let i = 0; i < n; i++) carried += alpha[t - 1][i] * A[i][j];
      alpha[t][j] = carried * emission(returns[t], means[j], sigmas[j]);
    }
    total = alpha[t].reduce((sum, v) => sum + v, 0);
    scale[t] = total > 0 ? 1 / total : 1;
    for (let j = 0; j < n; j++) alpha[t][j] = total > 0 ? alpha[t][j] * scale[t] : 1 / n;
    logLikelihood += Math.log(total > 0 ? total : Number.MIN_VALUE);
  }

  return { alpha, scale, logLikelihood };
}

/** Backward pass, reusing the forward pass's scaling factors. */
function backward(returns, { A, means, sigmas }, scale) {
  const T = returns.length;
  const n = A.length;
  const beta = Array.from({ length: T }, () => new Array(n).fill(0));

  for (let i = 0; i < n; i++) beta[T - 1][i] = scale[T - 1];

  for (let t = T - 2; t >= 0; t--) {
    for (let i = 0; i < n; i++) {
      let carried = 0;
      for (let j = 0; j < n; j++) {
        carried += A[i][j] * emission(returns[t + 1], means[j], sigmas[j]) * beta[t + 1][j];
      }
      beta[t][i] = carried * scale[t];
    }
  }
  return beta;
}

/**
 * Fit a Gaussian HMM to a return series by Baum-Welch.
 *
 * @param {number[]} returns Log returns, oldest first.
 * @param {object} [options]
 *   @param {number} [options.states] Hidden regimes to fit. 2 is the usual
 *     calm/turbulent split; 3 separates a crisis state.
 *   @param {number} [options.maxIterations]
 *   @param {number} [options.tolerance] Stop when the log-likelihood gain
 *     per observation falls below this.
 *   @param {number} [options.periodsPerYear]
 * @returns {object} fitted model, posteriors and convergence history
 */
export function fitHmm(returns, options = {}) {
  const {
    states = 2,
    maxIterations = 200,
    tolerance = 1e-7,
    periodsPerYear = TRADING_DAYS,
  } = options;

  if (!Array.isArray(returns) || returns.length < states * 10) {
    throw new RangeError(
      `need at least ${states * 10} returns to fit ${states} states, got ${returns?.length ?? 0}`);
  }

  const T = returns.length;
  let model = seedParameters(returns, states);
  let previous = -Infinity;
  const history = [];
  let iterations = 0;
  let converged = false;
  let gamma = [];

  for (; iterations < maxIterations; iterations++) {
    /* ---- E step: posteriors over states and transitions ---- */
    const { alpha, scale, logLikelihood } = forward(returns, model);
    const beta = backward(returns, model, scale);
    history.push(logLikelihood);

    gamma = Array.from({ length: T }, () => new Array(states).fill(0));
    for (let t = 0; t < T; t++) {
      let total = 0;
      for (let i = 0; i < states; i++) {
        gamma[t][i] = alpha[t][i] * beta[t][i];
        total += gamma[t][i];
      }
      for (let i = 0; i < states; i++) gamma[t][i] = total > 0 ? gamma[t][i] / total : 1 / states;
    }

    // Expected transition counts, accumulated rather than stored per step.
    const xi = Array.from({ length: states }, () => new Array(states).fill(0));
    for (let t = 0; t < T - 1; t++) {
      let total = 0;
      const step = Array.from({ length: states }, () => new Array(states).fill(0));
      for (let i = 0; i < states; i++) {
        for (let j = 0; j < states; j++) {
          step[i][j] = alpha[t][i] * model.A[i][j] *
            emission(returns[t + 1], model.means[j], model.sigmas[j]) * beta[t + 1][j];
          total += step[i][j];
        }
      }
      for (let i = 0; i < states; i++) {
        for (let j = 0; j < states; j++) {
          xi[i][j] += total > 0 ? step[i][j] / total : 1 / (states * states);
        }
      }
    }

    /* ---- M step: re-estimate the parameters ---- */
    const pi = gamma[0].slice();

    const A = Array.from({ length: states }, () => new Array(states).fill(0));
    for (let i = 0; i < states; i++) {
      let rowTotal = 0;
      for (let j = 0; j < states; j++) rowTotal += xi[i][j];
      for (let j = 0; j < states; j++) {
        A[i][j] = rowTotal > 0 ? xi[i][j] / rowTotal : 1 / states;
      }
    }

    const means = new Array(states).fill(0);
    const sigmas = new Array(states).fill(0);
    for (let i = 0; i < states; i++) {
      let weight = 0;
      let weighted = 0;
      for (let t = 0; t < T; t++) {
        weight += gamma[t][i];
        weighted += gamma[t][i] * returns[t];
      }
      means[i] = weight > 0 ? weighted / weight : 0;

      let variance = 0;
      for (let t = 0; t < T; t++) variance += gamma[t][i] * (returns[t] - means[i]) ** 2;
      sigmas[i] = Math.max(Math.sqrt(weight > 0 ? variance / weight : 0), MIN_SIGMA);
    }

    model = { pi, A, means, sigmas };

    // Converged once the likelihood stops improving materially per point.
    if (logLikelihood - previous < tolerance * T && iterations > 0) {
      converged = true;
      iterations += 1;
      break;
    }
    previous = logLikelihood;
  }

  // Report the fit of the parameters actually returned, not the ones that
  // produced the last E step.
  const final = forward(returns, model);
  const finalBeta = backward(returns, model, final.scale);
  gamma = Array.from({ length: T }, (unused, t) => {
    const row = new Array(states).fill(0);
    let total = 0;
    for (let i = 0; i < states; i++) {
      row[i] = final.alpha[t][i] * finalBeta[t][i];
      total += row[i];
    }
    for (let i = 0; i < states; i++) row[i] = total > 0 ? row[i] / total : 1 / states;
    return row;
  });

  // Order states quiet-to-turbulent so state 0 always means "calm",
  // whichever way EM happened to label them.
  const order = model.sigmas
    .map((sigma, index) => ({ sigma, index }))
    .sort((a, b) => a.sigma - b.sigma)
    .map((entry) => entry.index);

  const reordered = {
    pi: order.map((i) => model.pi[i]),
    A: order.map((i) => order.map((j) => model.A[i][j])),
    means: order.map((i) => model.means[i]),
    sigmas: order.map((i) => model.sigmas[i]),
  };
  const posteriors = gamma.map((row) => order.map((i) => row[i]));

  const parameterCount = states * states - 1 + 2 * states;
  return {
    ...reordered,
    states,
    periodsPerYear,
    posteriors,
    current: posteriors[T - 1],
    stationary: stationaryDistribution(reordered.A),
    viterbi: viterbiPath(returns, reordered),
    logLikelihood: final.logLikelihood,
    // Lower is better on both; they penalise the extra states a richer
    // model buys, which is how you tell 2 states from 3.
    aic: 2 * parameterCount - 2 * final.logLikelihood,
    bic: parameterCount * Math.log(T) - 2 * final.logLikelihood,
    iterations,
    converged,
    history,
    /** Annualised volatility of each regime. */
    annualisedVols: reordered.sigmas.map((s) => s * Math.sqrt(periodsPerYear)),
    /** Annualised log drift of each regime. */
    annualisedDrifts: reordered.means.map((m) => m * periodsPerYear),
    /** Expected duration of a regime, in periods, before it switches. */
    expectedDurations: reordered.A.map((row, i) => 1 / Math.max(1 - row[i], 1e-12)),
  };
}

/**
 * Long-run distribution over regimes, by power iteration on the transition
 * matrix. This is where the chain settles regardless of today's state.
 */
export function stationaryDistribution(A, iterations = 500) {
  const n = A.length;
  let p = new Array(n).fill(1 / n);
  for (let step = 0; step < iterations; step++) {
    const next = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) next[j] += p[i] * A[i][j];
    }
    let delta = 0;
    for (let i = 0; i < n; i++) delta += Math.abs(next[i] - p[i]);
    p = next;
    if (delta < 1e-14) break;
  }
  return p;
}

/**
 * Viterbi decoding: the single most likely regime sequence, as opposed to
 * the most likely regime at each point taken separately. Runs in log space,
 * which is what keeps it stable over thousands of observations.
 */
export function viterbiPath(returns, { pi, A, means, sigmas }) {
  const T = returns.length;
  const n = pi.length;
  const logA = A.map((row) => row.map((p) => Math.log(Math.max(p, Number.MIN_VALUE))));
  const delta = Array.from({ length: T }, () => new Array(n).fill(-Infinity));
  const psi = Array.from({ length: T }, () => new Array(n).fill(0));

  for (let i = 0; i < n; i++) {
    delta[0][i] = Math.log(Math.max(pi[i], Number.MIN_VALUE)) +
      Math.log(Math.max(emission(returns[0], means[i], sigmas[i]), Number.MIN_VALUE));
  }

  for (let t = 1; t < T; t++) {
    for (let j = 0; j < n; j++) {
      let best = -Infinity;
      let argBest = 0;
      for (let i = 0; i < n; i++) {
        const score = delta[t - 1][i] + logA[i][j];
        if (score > best) { best = score; argBest = i; }
      }
      delta[t][j] = best +
        Math.log(Math.max(emission(returns[t], means[j], sigmas[j]), Number.MIN_VALUE));
      psi[t][j] = argBest;
    }
  }

  const path = new Array(T).fill(0);
  let best = -Infinity;
  for (let i = 0; i < n; i++) {
    if (delta[T - 1][i] > best) { best = delta[T - 1][i]; path[T - 1] = i; }
  }
  for (let t = T - 2; t >= 0; t--) path[t] = psi[t + 1][path[t + 1]];
  return path;
}

/**
 * Project the fitted chain forward over an option's life.
 *
 * This is the bridge from Baum-Welch to the pricing models. Starting from
 * today's regime posterior, step the chain forward and accumulate the
 * variance each step contributes. The result is the expected variance to
 * expiry, which as an annualised number is the volatility to hand to
 * Black-Scholes.
 *
 * Note this averages variance across regime paths — it is the right input
 * for a European price, but it discards the volatility-of-volatility that
 * makes the terminal distribution fat-tailed. The Monte Carlo engine keeps
 * that, which is why the two prices differ.
 *
 * @param {object} model Result of `fitHmm`.
 * @param {number} years Horizon in years.
 */
export function projectRegimes(model, years) {
  const { A, sigmas, means, current, periodsPerYear } = model;
  const steps = Math.max(1, Math.round(years * periodsPerYear));
  const n = sigmas.length;

  let distribution = current.slice();
  const path = [distribution.slice()];
  let variance = 0;
  let drift = 0;

  for (let step = 0; step < steps; step++) {
    for (let i = 0; i < n; i++) {
      variance += distribution[i] * sigmas[i] ** 2;
      drift += distribution[i] * means[i];
    }
    const next = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) next[j] += distribution[i] * A[i][j];
    }
    distribution = next;
    path.push(distribution.slice());
  }

  // Rescale to the exact horizon: `steps` is rounded to whole periods.
  const scale = (years * periodsPerYear) / steps;
  return {
    steps,
    totalVariance: variance * scale,
    vol: Math.sqrt((variance * scale) / years),
    drift: (drift * scale) / years,
    terminalDistribution: distribution,
    path,
  };
}
