import test from 'node:test';
import assert from 'node:assert/strict';

import { impliedRegimeMix, projectedTurbulentWeight } from '../src/reverse.js';
import * as bs from '../src/blackScholes.js';

const CONTRACT = { spot: 100, strike: 100, time: 0.25, rate: 0.04, yield: 0, type: 'call' };
const VOLS = [0.18, 0.45];
const blend = (w) => Math.sqrt((1 - w) * VOLS[0] ** 2 + w * VOLS[1] ** 2);
const ask = (marketPrice) => impliedRegimeMix({
  marketPrice, contract: CONTRACT, regimeVols: VOLS,
  modelWeight: 0.20, historicalWeight: 0.15,
});

test('the inversion round-trips: a price built from a known mix recovers it', () => {
  for (const w of [0, 0.25, 0.5, 0.75, 1]) {
    const price = bs.price({ ...CONTRACT, vol: blend(w) });
    const got = ask(price);
    assert.equal(got.state, 'ok', `w=${w} should invert cleanly`);
    assert.ok(Math.abs(got.impliedWeight - w) < 1e-6,
      `w=${w} recovered as ${got.impliedWeight}`);
  }
});

test('a price above the most turbulent regime is reported, not clamped', () => {
  const got = ask(bs.price({ ...CONTRACT, vol: 0.9 }));
  assert.equal(got.state, 'above-most-turbulent');
  assert.ok(got.impliedWeight > 1, 'the raw weight is still exposed');
  assert.ok(got.impliedVolatility > VOLS[1]);
});

test('a price below the calmest regime is reported, not clamped', () => {
  const got = ask(bs.price({ ...CONTRACT, vol: 0.05 }));
  assert.equal(got.state, 'below-calmest');
  assert.ok(got.impliedWeight < 0);
});

test('a price outside the no-arbitrage bounds yields no solution, without throwing', () => {
  const got = ask(500);
  assert.equal(got.state, 'no-solution');
  assert.ok(got.reason.length > 0);
});

test('a quote pinned to the solver’s own floor reports insensitivity, not a fake mix', () => {
  // At the no-arbitrage floor every volatility gives the same price.
  const floor = Math.max(0, 100 - 100 * Math.exp(-0.04 * 0.25));
  const got = ask(Math.max(floor, 1e-6));
  assert.ok(['insensitive', 'no-solution'].includes(got.state), got.state);
  assert.equal(got.impliedWeight, undefined);
});

test('the comparisons against the model and the history are signed differences', () => {
  const got = ask(bs.price({ ...CONTRACT, vol: blend(0.5) }));
  assert.ok(Math.abs(got.versusModel - (0.5 - 0.20)) < 1e-6);
  assert.ok(Math.abs(got.versusHistory - (0.5 - 0.15)) < 1e-6);
});

test('degenerate inputs are refused rather than guessed at', () => {
  assert.equal(ask(0).state, 'not-applicable');
  assert.equal(impliedRegimeMix({
    marketPrice: 5, contract: CONTRACT, regimeVols: [0.2], modelWeight: 0, historicalWeight: 0,
  }).state, 'not-applicable');
  assert.equal(impliedRegimeMix({
    marketPrice: 5, contract: CONTRACT, regimeVols: [0.3, 0.3], modelWeight: 0, historicalWeight: 0,
  }).state, 'not-applicable', 'identical regimes cannot bracket anything');
});

test('the projected weight time-averages the turbulent regime, ignoring the trailing state', () => {
  // Three steps at 10%, 20%, 30% turbulent, plus the post-final distribution
  // which no step drew variance from and must not be counted.
  const path = [[0.9, 0.1], [0.8, 0.2], [0.7, 0.3], [0.0, 1.0]];
  const w = projectedTurbulentWeight(path, VOLS);
  assert.ok(Math.abs(w - 0.2) < 1e-12, `expected 0.2, got ${w}`);
});

test('the turbulent regime is identified by volatility, not by index order', () => {
  const path = [[0.2, 0.8], [0.2, 0.8]];
  // Highest volatility first this time; the weight must follow the vol.
  assert.ok(Math.abs(projectedTurbulentWeight(path, [0.45, 0.18]) - 0.2) < 1e-12);
  assert.ok(Math.abs(projectedTurbulentWeight(path, [0.18, 0.45]) - 0.8) < 1e-12);
});

test('an empty or single-regime path has no answer', () => {
  assert.equal(projectedTurbulentWeight([], VOLS), null);
  assert.equal(projectedTurbulentWeight([[1]], [0.2]), null);
});

test('a deep in-the-money quote is refused: its price barely moves with volatility', () => {
  // Intrinsic ~40 on a 100 spot / 60 strike call: vega is nearly nothing, so
  // the solver returns a volatility that the quote does not actually pin down.
  const deep = { spot: 100, strike: 60, time: 0.25, rate: 0.04, yield: 0, type: 'call' };
  const price = bs.price({ ...deep, vol: 0.30 });
  const got = impliedRegimeMix({
    marketPrice: price, contract: deep, regimeVols: VOLS,
    modelWeight: 0.2, historicalWeight: 0.15,
  });
  assert.equal(got.state, 'insensitive');
  assert.ok(/hardly\s+moves with volatility/.test(got.reason), got.reason);
  assert.equal(got.impliedWeight, undefined, 'no weight is offered when none is implied');
});

test('an at-the-money quote of the same stock is answered normally', () => {
  const atm = { spot: 100, strike: 100, time: 0.25, rate: 0.04, yield: 0, type: 'call' };
  const price = bs.price({ ...atm, vol: blend(0.4) });
  const got = impliedRegimeMix({
    marketPrice: price, contract: atm, regimeVols: VOLS,
    modelWeight: 0.2, historicalWeight: 0.15,
  });
  assert.equal(got.state, 'ok');
  assert.ok(Math.abs(got.impliedWeight - 0.4) < 1e-6);
});
