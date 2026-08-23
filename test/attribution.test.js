import test from 'node:test';
import assert from 'node:assert/strict';

import { attributePremium } from '../src/attribution.js';
import { ensembleValuation } from '../src/ensemble.js';

/** A history with a calm stretch and a turbulent one, so regimes are real. */
function series(n = 500, base = 100) {
  const out = [];
  let price = base;
  let seed = 7;
  const rand = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff - 0.5;
  };
  for (let i = 0; i < n; i++) {
    const vol = i > 250 && i < 340 ? 0.030 : 0.008;
    price *= 1 + 0.0004 + rand() * 2 * vol;
    out.push(price);
  }
  return out;
}

const priced = (overrides = {}) => ensembleValuation({
  prices: series(),
  strike: 100, days: 90, rate: 0.04, yield: 0,
  type: 'call', style: 'american', states: 2, paths: 4000, seed: 11,
  periodsPerYear: 252, ...overrides,
});

test('the ladder sums exactly to the headline consensus price', () => {
  for (const style of ['european', 'american']) {
    for (const type of ['call', 'put']) {
      const result = priced({ style, type });
      const { steps, total } = attributePremium(result);
      const sum = steps.reduce((acc, s) => acc + s.amount, 0);
      assert.ok(Math.abs(sum - total) < 1e-9,
        `${style} ${type}: steps sum to ${sum}, headline is ${total}`);
      assert.ok(Math.abs(total - result.consensus.value) < 1e-12);
    }
  }
});

test('intrinsic value is the immediate-exercise payoff and never negative', () => {
  const itm = priced({ strike: 60 });
  const otm = priced({ strike: 200 });
  const first = (r) => attributePremium(r).steps[0];
  assert.ok(first(itm).amount > 0, 'deep in the money has intrinsic value');
  assert.equal(first(otm).amount, 0, 'out of the money has none');
  assert.equal(first(itm).key, 'intrinsic');
});

test('the regime step isolates volatility and nothing else', () => {
  const result = priced();
  const regime = attributePremium(result).steps.find((s) => s.key === 'regime');
  const expected = result.blackScholes.onRegime.europeanValue
    - result.blackScholes.onTrailing.europeanValue;
  assert.ok(Math.abs(regime.amount - expected) < 1e-12);
  // Direction must follow the volatility difference for a vega-positive option.
  const higherVol = result.volatility.regime > result.volatility.trailing;
  assert.equal(regime.amount > 0, higherVol,
    'more volatility must raise the price, less must lower it');
});

test('European contracts carry no early-exercise rung at all', () => {
  const keys = attributePremium(priced({ style: 'european' })).steps.map((s) => s.key);
  assert.ok(!keys.includes('early'));
  assert.deepEqual(keys, ['intrinsic', 'time', 'regime', 'path', 'reconciliation']);
});

test('American contracts carry one, and it is never negative', () => {
  const step = attributePremium(priced({ style: 'american' }))
    .steps.find((s) => s.key === 'early');
  assert.ok(step, 'the rung exists');
  // The right to exercise early cannot be worth less than nothing; allow only
  // simulation noise below zero.
  assert.ok(step.amount > -0.02, `early exercise was ${step.amount}`);
});

test('every step carries a label and a plain-language explanation', () => {
  for (const step of attributePremium(priced()).steps) {
    assert.ok(step.label && step.label.length > 2, `${step.key} needs a label`);
    assert.ok(step.detail && step.detail.length > 20, `${step.key} needs a detail`);
    assert.ok(Number.isFinite(step.amount), `${step.key} amount must be finite`);
  }
});

test('the reconciliation rung names the model gap rather than hiding it', () => {
  const result = priced();
  const { steps } = attributePremium(result);
  const recon = steps[steps.length - 1];
  assert.equal(recon.key, 'reconciliation');
  // It is bounded by the spread between the models — it is a disagreement,
  // not an unexplained residual.
  assert.ok(Math.abs(recon.amount) <= result.consensus.spread + 1e-9,
    `reconciliation ${recon.amount} exceeds the model spread ${result.consensus.spread}`);
});

test('the regime step never claims a direction its own number cannot support', () => {
  // Deep in the money: volatility barely matters, so the copy must not say
  // the regime "adds to" or "takes off" the price on a sub-cent difference.
  const deep = attributePremium(priced({ strike: 40 }));
  const step = deep.steps.find((s) => s.key === 'regime');
  if (Math.abs(step.amount) < 0.005) {
    assert.ok(/barely moves the price/.test(step.detail), step.detail);
    assert.ok(!/adds to the price|takes off the price/.test(step.detail));
  }
  // At the money it must commit to a direction, and the right one.
  const atm = attributePremium(priced({ strike: 100 }));
  const atmStep = atm.steps.find((s) => s.key === 'regime');
  if (Math.abs(atmStep.amount) >= 0.005) {
    assert.ok(/adds to the price|takes off the price/.test(atmStep.detail), atmStep.detail);
    assert.equal(/adds to the price/.test(atmStep.detail), atmStep.amount > 0);
  }
});
