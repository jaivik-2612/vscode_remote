import test from 'node:test';
import assert from 'node:assert/strict';

import {
  parsePrices, logReturns, historicalVol, ewmaVol, historicalDrift, describe as summarise,
} from '../src/series.js';
import { fitHmm, projectRegimes, stationaryDistribution, viterbiPath } from '../src/hmm.js';
import {
  makeRng, simulatePaths, europeanFromPaths, americanFromPaths, terminalDistribution,
} from '../src/monteCarlo.js';
import * as bs from '../src/blackScholes.js';
import * as binomial from '../src/binomial.js';
import { ensembleValuation } from '../src/ensemble.js';

/* A seeded generator, so every assertion below is reproducible. */
function generator(seed) {
  let state = seed;
  const uniform = () => (state = (state * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const normal = () => {
    let u = 0;
    let v = 0;
    while (u === 0) u = uniform();
    while (v === 0) v = uniform();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };
  return { uniform, normal };
}

/** Sample a return series from a known two-regime HMM. */
function regimeSeries(count, seed = 12345) {
  const { uniform, normal } = generator(seed);
  const A = [[0.98, 0.02], [0.06, 0.94]];
  const sigmas = [0.008, 0.030];
  const means = [0.0006, -0.0010];
  let state = 0;
  const returns = [];
  for (let t = 0; t < count; t++) {
    returns.push(means[state] + sigmas[state] * normal());
    if (uniform() > A[state][state]) state = 1 - state;
  }
  return { returns, A, sigmas, means };
}

/* ------------------------------------------------------------- series -- */

test('parsePrices accepts the formats a spreadsheet actually produces', () => {
  assert.deepEqual(parsePrices('100\n101.5\n99'), [100, 101.5, 99]);
  assert.deepEqual(parsePrices('100, 101.5, 99'), [100, 101.5, 99]);
  assert.deepEqual(parsePrices('$1,200.50\t$1,210'), [1200.5, 1210]);
  // A header row and a blank line must not derail the parse.
  assert.deepEqual(parsePrices('close\n100\n\n102'), [100, 102]);
  // Non-positive prices cannot produce a log return, so they are dropped.
  assert.deepEqual(parsePrices('100\n0\n-5\n102'), [100, 102]);
  assert.deepEqual(parsePrices(''), []);
  assert.deepEqual(parsePrices(null), []);
});

test('a constant-growth series has zero volatility', () => {
  const prices = [100];
  for (let i = 0; i < 50; i++) prices.push(prices[prices.length - 1] * 1.01);
  assert.ok(historicalVol(logReturns(prices)) < 1e-12);
});

test('historicalVol annualises by the square root of time', () => {
  const { normal } = generator(7);
  const returns = Array.from({ length: 4000 }, () => 0.01 * normal());
  // Daily sigma of 0.01 annualises to 0.01 * sqrt(252) ~= 0.1587.
  assert.ok(Math.abs(historicalVol(returns) - 0.01 * Math.sqrt(252)) < 0.006);
});

test('ewmaVol tracks a volatility jump that a trailing window smears', () => {
  const { normal } = generator(3);
  const calm = Array.from({ length: 300 }, () => 0.005 * normal());
  const stormy = Array.from({ length: 40 }, () => 0.04 * normal());
  const returns = [...calm, ...stormy];
  // The recent burst dominates the exponentially weighted estimate but is
  // diluted by 300 quiet days in the equally weighted one.
  assert.ok(ewmaVol(returns) > historicalVol(returns));
});

test('historicalDrift separates log drift from expected return', () => {
  const { normal } = generator(5);
  const returns = Array.from({ length: 2000 }, () => 0.0004 + 0.01 * normal());
  const { logDrift, expectedReturn } = historicalDrift(returns);
  // expectedReturn = logDrift + variance/2, so it is always the larger.
  assert.ok(expectedReturn > logDrift);
  assert.ok(Math.abs((expectedReturn - logDrift) - (0.01 ** 2 * 252) / 2) < 0.005);
});

test('describe reports near-zero skew and kurtosis for normal returns', () => {
  const { normal } = generator(11);
  const stats = summarise(Array.from({ length: 6000 }, () => 0.01 * normal()));
  assert.ok(Math.abs(stats.skew) < 0.12);
  assert.ok(Math.abs(stats.excessKurtosis) < 0.2);
});

/* ---------------------------------------------------------------- hmm -- */

test('Baum-Welch recovers the parameters of a known two-regime model', () => {
  const truth = regimeSeries(3000);
  const model = fitHmm(truth.returns, { states: 2 });

  assert.ok(model.converged, 'EM should converge on 3000 clean observations');
  // States come back ordered calm-first regardless of EM's own labelling.
  assert.ok(model.sigmas[0] < model.sigmas[1]);
  assert.ok(Math.abs(model.sigmas[0] - truth.sigmas[0]) < 0.002);
  assert.ok(Math.abs(model.sigmas[1] - truth.sigmas[1]) < 0.004);
  assert.ok(Math.abs(model.A[0][0] - truth.A[0][0]) < 0.03);
  assert.ok(Math.abs(model.A[1][1] - truth.A[1][1]) < 0.04);
});

test('the log-likelihood never decreases, which is what EM guarantees', () => {
  const { returns } = regimeSeries(800, 99);
  const { history } = fitHmm(returns, { states: 2 });
  for (let i = 1; i < history.length; i++) {
    assert.ok(history[i] >= history[i - 1] - 1e-9,
      `likelihood fell at iteration ${i}: ${history[i - 1]} -> ${history[i]}`);
  }
});

test('posteriors are proper distributions at every observation', () => {
  const { returns } = regimeSeries(500, 21);
  const model = fitHmm(returns, { states: 3 });
  for (const row of model.posteriors) {
    const total = row.reduce((sum, p) => sum + p, 0);
    assert.ok(Math.abs(total - 1) < 1e-9);
    for (const p of row) assert.ok(p >= 0 && p <= 1);
  }
  for (const row of model.A) {
    assert.ok(Math.abs(row.reduce((sum, p) => sum + p, 0) - 1) < 1e-9);
  }
});

test('the fit is deterministic, so the same history always prices the same', () => {
  const { returns } = regimeSeries(600, 42);
  const a = fitHmm(returns, { states: 2 });
  const b = fitHmm(returns, { states: 2 });
  assert.deepEqual(a.sigmas, b.sigmas);
  assert.equal(a.logLikelihood, b.logLikelihood);
});

test('stationaryDistribution solves the chain it is given', () => {
  // For [[0.9,0.1],[0.2,0.8]] the stationary vector is (2/3, 1/3).
  const p = stationaryDistribution([[0.9, 0.1], [0.2, 0.8]]);
  assert.ok(Math.abs(p[0] - 2 / 3) < 1e-9);
  assert.ok(Math.abs(p[1] - 1 / 3) < 1e-9);
});

test('a richer model fits better but is penalised for its extra parameters', () => {
  const { returns } = regimeSeries(1500, 77);
  const two = fitHmm(returns, { states: 2 });
  const three = fitHmm(returns, { states: 3 });
  // More states can always fit at least as well in-sample.
  assert.ok(three.logLikelihood >= two.logLikelihood - 1e-6);
  // The data really was two-state, so BIC should prefer the simpler model.
  assert.ok(two.bic < three.bic);
});

test('Viterbi labels a series that switches regime part way through', () => {
  const { normal } = generator(13);
  const returns = [
    ...Array.from({ length: 200 }, () => 0.004 * normal()),
    ...Array.from({ length: 200 }, () => 0.035 * normal()),
  ];
  const model = fitHmm(returns, { states: 2 });
  const path = viterbiPath(returns, model);
  const calmFirstHalf = path.slice(0, 200).filter((s) => s === 0).length;
  const stormySecondHalf = path.slice(200).filter((s) => s === 1).length;
  assert.ok(calmFirstHalf > 180, `expected a calm first half, got ${calmFirstHalf}/200`);
  assert.ok(stormySecondHalf > 180, `expected a turbulent second half, got ${stormySecondHalf}/200`);
});

test('projected volatility sits between the regimes it mixes', () => {
  const { returns } = regimeSeries(1200, 8);
  const model = fitHmm(returns, { states: 2 });
  const projected = projectRegimes(model, 90 / 365);
  const [calm, stormy] = model.annualisedVols;
  assert.ok(projected.vol > calm && projected.vol < stormy,
    `${projected.vol} should lie between ${calm} and ${stormy}`);
});

test('a long horizon converges on the stationary mix, a short one does not', () => {
  const { returns } = regimeSeries(1500, 64);
  const model = fitHmm(returns, { states: 2 });
  const decade = projectRegimes(model, 10);
  for (let i = 0; i < model.states; i++) {
    assert.ok(Math.abs(decade.terminalDistribution[i] - model.stationary[i]) < 1e-6);
  }
  // Over a single day the chain has barely moved off today's regime.
  const tomorrow = projectRegimes(model, 1 / 252);
  assert.ok(Math.abs(tomorrow.terminalDistribution[0] - model.current[0]) < 0.1);
});

test('fitHmm refuses a series too short to identify its states', () => {
  assert.throws(() => fitHmm([0.01, -0.02, 0.005], { states: 2 }), RangeError);
});

/* -------------------------------------------------------- monte carlo -- */

test('the generator is uniform, reproducible, and in range', () => {
  const rng = makeRng(2024);
  const draws = Array.from({ length: 20000 }, rng);
  assert.ok(draws.every((x) => x >= 0 && x < 1));
  const mean = draws.reduce((sum, x) => sum + x, 0) / draws.length;
  assert.ok(Math.abs(mean - 0.5) < 0.01);
  assert.deepEqual(Array.from({ length: 5 }, makeRng(2024)), draws.slice(0, 5));
});

test('simulated European prices agree with Black-Scholes', () => {
  const base = { spot: 100, years: 1, rate: 0.05, yield: 0.02, vol: 0.25 };
  for (const type of ['call', 'put']) {
    for (const strike of [80, 100, 120]) {
      const simulation = simulatePaths({ ...base, steps: 50, paths: 40000, seed: 7 });
      const mc = europeanFromPaths(simulation, { ...base, strike, type });
      const analytic = bs.price({ ...base, strike, type, time: 1 });
      assert.ok(Math.abs(mc.price - analytic) < 1.96 * mc.standardError,
        `${type} K=${strike}: MC ${mc.price} vs BS ${analytic}, SE ${mc.standardError}`);
    }
  }
});

test('the control variate actually reduces variance', () => {
  const base = { spot: 100, strike: 100, years: 1, rate: 0.05, yield: 0, vol: 0.25 };
  const simulation = simulatePaths({ ...base, steps: 50, paths: 20000, seed: 5 });
  const { varianceReduction } = europeanFromPaths(simulation, { ...base, type: 'call' });
  assert.ok(varianceReduction > 0.3, `only reduced variance by ${varianceReduction}`);
});

test('risk-neutral paths keep the discounted stock a martingale', () => {
  const simulation = simulatePaths({
    spot: 100, years: 1, rate: 0.05, yield: 0.02, vol: 0.3, steps: 50, paths: 40000, seed: 3,
  });
  const { mean } = terminalDistribution(simulation, { strike: 100 });
  // Under the risk-neutral measure E[S_T] is the forward, not the spot.
  const forward = 100 * Math.exp((0.05 - 0.02) * 1);
  assert.ok(Math.abs(mean - forward) / forward < 0.005, `E[S_T]=${mean}, forward=${forward}`);
});

test('Longstaff-Schwartz matches a fine binomial tree on American puts', () => {
  for (const vol of [0.2, 0.4]) {
    const simulation = simulatePaths({
      spot: 100, years: 1, rate: 0.05, yield: 0, vol, steps: 50, paths: 40000, seed: 11,
    });
    const lsm = americanFromPaths(simulation, { strike: 110, type: 'put', rate: 0.05, years: 1 });
    const tree = binomial.price({
      spot: 100, strike: 110, time: 1, vol, rate: 0.05, type: 'put', american: true, steps: 2000,
    });
    assert.ok(Math.abs(lsm.price - tree) < 0.06, `vol ${vol}: LSM ${lsm.price} vs tree ${tree}`);
  }
});

test('an American option is never worth less than its European twin', () => {
  const simulation = simulatePaths({
    spot: 100, years: 1, rate: 0.06, yield: 0, vol: 0.3, steps: 50, paths: 20000, seed: 17,
  });
  const contract = { strike: 115, type: 'put', rate: 0.06, years: 1, spot: 100 };
  const american = americanFromPaths(simulation, contract);
  const european = europeanFromPaths(simulation, contract);
  assert.ok(american.price >= european.price - 1e-9);
  assert.ok(american.exercisedEarly > 0, 'a deep ITM American put should exercise early');
});

test('terminal quantiles are ordered and the histogram is a distribution', () => {
  const simulation = simulatePaths({
    spot: 50, years: 0.5, rate: 0.03, yield: 0, vol: 0.4, steps: 40, paths: 20000, seed: 23,
  });
  const d = terminalDistribution(simulation, { strike: 50 });
  assert.ok(d.min <= d.p5 && d.p5 <= d.p25 && d.p25 <= d.median);
  assert.ok(d.median <= d.p75 && d.p75 <= d.p95 && d.p95 <= d.max);
  const total = d.histogram.reduce((sum, bin) => sum + bin.frequency, 0);
  assert.ok(Math.abs(total - 1) < 1e-9);
  assert.ok(d.probAboveStrike > 0 && d.probAboveStrike < 1);
});

test('regime-switching paths are fatter tailed than plain GBM at equal volatility', () => {
  const { returns } = regimeSeries(2000, 31);
  const model = fitHmm(returns, { states: 2 });
  const shared = { spot: 100, years: 1, rate: 0.03, yield: 0, steps: 60, paths: 30000 };
  const projected = projectRegimes(model, 1).vol;

  const regime = terminalDistribution(
    simulatePaths({ ...shared, dynamics: 'regime', regimes: model, seed: 4 }), {});
  const gbm = terminalDistribution(
    simulatePaths({ ...shared, dynamics: 'gbm', vol: projected, seed: 4 }), {});

  // Same average variance, but switching regimes spreads the extremes wider
  // while pulling the middle in — that is what vol-of-vol does.
  assert.ok(regime.p95 - regime.p5 > 0, 'sanity');
  assert.ok(regime.max > gbm.max, `regime max ${regime.max} vs gbm ${gbm.max}`);
});

/* ----------------------------------------------------------- ensemble -- */

function samplePrices(count = 500, seed = 99) {
  const { uniform, normal } = generator(seed);
  const A = [[0.97, 0.03], [0.08, 0.92]];
  const sigmas = [0.009, 0.032];
  const means = [0.0007, -0.0012];
  let state = 0;
  const prices = [100];
  for (let t = 0; t < count; t++) {
    prices.push(prices[prices.length - 1] * Math.exp(means[state] + sigmas[state] * normal()));
    if (uniform() > A[state][state]) state = 1 - state;
  }
  return prices;
}

test('the ensemble runs all three engines and reconciles them', () => {
  const result = ensembleValuation({
    prices: samplePrices(), strike: 105, days: 90, rate: 0.045, type: 'call',
  });

  assert.equal(result.consensus.estimates.length, 3);
  assert.ok(result.hmm.converged);
  assert.ok(result.hmm.annualisedVols[0] < result.hmm.annualisedVols[1]);
  assert.ok(result.blackScholes.onTrailing.fairValue > 0);
  assert.ok(result.monteCarlo.european.price > 0);
  // The GBM control shares every assumption with the closed form, so any gap
  // is simulation noise; if this fails the simulation itself is wrong.
  assert.ok(result.monteCarlo.control.withinTolerance,
    `control off by ${result.monteCarlo.control.error}`);
  assert.ok(result.consensus.low <= result.consensus.value);
  assert.ok(result.consensus.value <= result.consensus.high);
});

test('the ensemble defaults spot to the last observed price', () => {
  const prices = samplePrices();
  const result = ensembleValuation({ prices, strike: 100, days: 60, rate: 0.04, type: 'put' });
  assert.equal(result.spot, prices[prices.length - 1]);
  // And honours an explicit override.
  const override = ensembleValuation({
    prices, spot: 123.45, strike: 100, days: 60, rate: 0.04, type: 'put',
  });
  assert.equal(override.spot, 123.45);
});

test('an American ensemble prices by Longstaff-Schwartz and beats European', () => {
  const result = ensembleValuation({
    prices: samplePrices(), strike: 120, days: 180, rate: 0.05, type: 'put', style: 'american',
  });
  assert.ok(result.monteCarlo.american !== null);
  assert.ok(result.monteCarlo.american.price >= result.monteCarlo.european.price - 1e-9);
});

test('the ensemble is reproducible for a given seed', () => {
  const prices = samplePrices();
  const input = { prices, strike: 105, days: 90, rate: 0.045, type: 'call', seed: 2024 };
  assert.equal(
    ensembleValuation(input).monteCarlo.european.price,
    ensembleValuation(input).monteCarlo.european.price,
  );
});

test('the ensemble refuses a history too short to model', () => {
  assert.throws(() => ensembleValuation({
    prices: [100, 101, 102], strike: 100, days: 30, rate: 0.04, type: 'call',
  }), RangeError);
  assert.throws(() => ensembleValuation({
    prices: samplePrices(), strike: 100, days: 0, rate: 0.04, type: 'call',
  }), RangeError);
});
