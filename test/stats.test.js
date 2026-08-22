import test from 'node:test';
import assert from 'node:assert/strict';
import { normCdf, normPdf, normInv } from '../src/stats.js';

test('normCdf matches known values', () => {
  const cases = [
    [0, 0.5],
    [1, 0.8413447460685429],
    [-1, 0.15865525393145707],
    [1.96, 0.9750021048517795],
    [-2.5, 0.006209665325776132],
    [5, 0.9999997133484281],
  ];
  for (const [x, expected] of cases) {
    assert.ok(Math.abs(normCdf(x) - expected) < 1e-14, `normCdf(${x}) = ${normCdf(x)}`);
  }
});

test('normCdf keeps significant digits deep in the tail', () => {
  // Absolute error is what pricing cares about, but a tail computed as
  // `1 - normCdf(x)` would have no significant digits left out here at all.
  const reference = [
    [-8, 6.220960574271819e-16],
    [-10, 7.619853024160593e-24],
    [-20, 2.7536241186063314e-89],
    [-30, 4.906713927148764e-198],
  ];
  for (const [x, expected] of reference) {
    assert.ok(Math.abs(normCdf(x) / expected - 1) < 1e-8, `normCdf(${x}) = ${normCdf(x)}`);
  }
  assert.equal(normCdf(-40), 0);
  assert.equal(normCdf(40), 1);
});

test('normCdf is symmetric and monotone', () => {
  let previous = -Infinity;
  for (let x = -8; x <= 8; x += 0.01) {
    const value = normCdf(x);
    assert.ok(value >= previous, `not monotone at ${x}`);
    assert.ok(Math.abs(value + normCdf(-x) - 1) < 1e-14, `not symmetric at ${x}`);
    previous = value;
  }
});

test('normPdf integrates to one', () => {
  // Simpson's rule over [-10, 10].
  const n = 20000;
  const h = 20 / n;
  let sum = normPdf(-10) + normPdf(10);
  for (let i = 1; i < n; i++) {
    sum += normPdf(-10 + i * h) * (i % 2 === 0 ? 2 : 4);
  }
  assert.ok(Math.abs((sum * h) / 3 - 1) < 1e-12);
});

test('normInv inverts normCdf', () => {
  for (let x = -6; x <= 6; x += 0.25) {
    assert.ok(Math.abs(normInv(normCdf(x)) - x) < 1e-8, `round trip failed at ${x}`);
  }
  assert.equal(normInv(0), -Infinity);
  assert.equal(normInv(1), Infinity);
});
