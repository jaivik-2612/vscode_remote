import test from 'node:test';
import assert from 'node:assert/strict';

import { breakEvenPrice, intrinsicValue, exerciseComparison } from '../src/decision.js';

test('break-even shifts the strike by the premium, in the payoff direction', () => {
  assert.equal(breakEvenPrice('call', 100, 4.5), 104.5);
  assert.equal(breakEvenPrice('put', 100, 4.5), 95.5);
});

test('intrinsic value is the immediate-exercise payoff, floored at zero', () => {
  assert.equal(intrinsicValue('call', 110, 100), 10);
  assert.equal(intrinsicValue('call', 90, 100), 0);
  assert.equal(intrinsicValue('put', 90, 100), 10);
  assert.equal(intrinsicValue('put', 110, 100), 0);
});

test('a writer holds no exercise right, whatever the moneyness', () => {
  const advice = exerciseComparison({
    type: 'call', style: 'american', direction: 'short',
    spot: 150, strike: 100, fair: 52,
  });
  assert.equal(advice.state, 'short');
  assert.equal(advice.intrinsic, 50);
});

test('out of the money: nothing to exercise, selling is the only exit', () => {
  const advice = exerciseComparison({
    type: 'call', style: 'american', direction: 'long',
    spot: 90, strike: 100, fair: 1.2,
  });
  assert.equal(advice.state, 'otm');
  assert.equal(advice.intrinsic, 0);
  assert.ok(Math.abs(advice.timeValue - 1.2) < 1e-12, 'OTM value is all time value');
});

test('in the money with time value left: sell, do not exercise', () => {
  const advice = exerciseComparison({
    type: 'call', style: 'american', direction: 'long',
    spot: 110, strike: 100, fair: 13.4,
  });
  assert.equal(advice.state, 'sell');
  assert.equal(advice.intrinsic, 10);
  assert.ok(Math.abs(advice.timeValue - 3.4) < 1e-12);
});

test('deep in-the-money put with no time value left: exercise is defensible', () => {
  // Deep ITM American puts can trade below intrinsic pricing-model-wise:
  // waiting costs interest on the strike, so time value goes negative.
  const advice = exerciseComparison({
    type: 'put', style: 'american', direction: 'long',
    spot: 40, strike: 100, fair: 59.95,
  });
  assert.equal(advice.state, 'exercise-ok');
  assert.equal(advice.intrinsic, 60);
  assert.ok(advice.timeValue < 0);
});

test('time value within the noise threshold counts as a toss-up, not a sell', () => {
  // fair 50.30 vs intrinsic 50: 0.30 time value < 1% of fair (0.503).
  const advice = exerciseComparison({
    type: 'call', style: 'american', direction: 'long',
    spot: 150, strike: 100, fair: 50.3,
  });
  assert.equal(advice.state, 'exercise-ok');
});

test('European style in the money: no early exercise exists, selling is the exit', () => {
  const advice = exerciseComparison({
    type: 'call', style: 'european', direction: 'long',
    spot: 110, strike: 100, fair: 13.4,
  });
  assert.equal(advice.state, 'european-locked');
  assert.equal(advice.intrinsic, 10);
});
