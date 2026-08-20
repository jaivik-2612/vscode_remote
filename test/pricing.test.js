import test from 'node:test';
import assert from 'node:assert/strict';
import * as bs from '../src/blackScholes.js';
import * as binomial from '../src/binomial.js';
import { impliedVol } from '../src/impliedVol.js';
import { valuation, employeeGrantValue, valueCurve } from '../src/index.js';

const base = { spot: 100, strike: 100, time: 1, vol: 0.2, rate: 0.05, yield: 0 };

/** A spread of contracts to check invariants that must hold everywhere. */
function* sampleContracts() {
  for (const spot of [40, 95, 100, 105, 250]) {
    for (const time of [0.02, 0.25, 1, 3]) {
      for (const vol of [0.08, 0.2, 0.65]) {
        for (const rate of [-0.005, 0, 0.05]) {
          for (const q of [0, 0.03]) {
            yield { spot, strike: 100, time, vol, rate, yield: q };
          }
        }
      }
    }
  }
}

test('Black-Scholes reproduces textbook values', () => {
  // S=100, K=100, T=1, sigma=20%, r=5%, no dividend.
  assert.ok(Math.abs(bs.price({ ...base, type: 'call' }) - 10.450583572185565) < 1e-12);
  assert.ok(Math.abs(bs.price({ ...base, type: 'put' }) - 5.573526022256971) < 1e-12);

  // Hull, worked example: S=42, K=40, T=0.5, sigma=20%, r=10%.
  const hull = { spot: 42, strike: 40, time: 0.5, vol: 0.2, rate: 0.1, yield: 0 };
  assert.ok(Math.abs(bs.price({ ...hull, type: 'call' }) - 4.759422392871542) < 1e-9);
  assert.ok(Math.abs(bs.price({ ...hull, type: 'put' }) - 0.8085993729000922) < 1e-9);
});

test('put-call parity holds across the board', () => {
  for (const contract of sampleContracts()) {
    const residual = bs.parityResidual(contract);
    assert.ok(Math.abs(residual) < 1e-10 * contract.spot,
      `parity broke at ${JSON.stringify(contract)}: ${residual}`);
  }
});

test('prices respect their no-arbitrage bounds', () => {
  for (const contract of sampleContracts()) {
    for (const type of ['call', 'put']) {
      const value = bs.price({ ...contract, type });
      const dfSpot = contract.spot * Math.exp(-contract.yield * contract.time);
      const dfStrike = contract.strike * Math.exp(-contract.rate * contract.time);
      const lower = type === 'call'
        ? Math.max(dfSpot - dfStrike, 0)
        : Math.max(dfStrike - dfSpot, 0);
      const upper = type === 'call' ? dfSpot : dfStrike;
      assert.ok(value >= lower - 1e-10 && value <= upper + 1e-10,
        `${type} ${JSON.stringify(contract)} = ${value}, want [${lower}, ${upper}]`);
    }
  }
});

test('value rises with volatility and with time', () => {
  for (const type of ['call', 'put']) {
    let previous = -Infinity;
    for (let vol = 0; vol <= 1.5; vol += 0.05) {
      const value = bs.price({ ...base, vol, type });
      assert.ok(value >= previous - 1e-12, `not monotone in vol at ${vol}`);
      previous = value;
    }
    // Time monotonicity needs a zero rate for puts, which can otherwise lose
    // value with time because the strike is discounted further.
    previous = -Infinity;
    for (let time = 0; time <= 5; time += 0.1) {
      const value = bs.price({ ...base, rate: 0, time, type });
      assert.ok(value >= previous - 1e-12, `not monotone in time at ${time}`);
      previous = value;
    }
  }
});

test('analytic Greeks match finite differences of the price', () => {
  for (const contract of sampleContracts()) {
    for (const type of ['call', 'put']) {
      const inputs = { ...contract, type };
      const g = bs.greeks(inputs);
      const at = (o) => bs.price({ ...inputs, ...o });

      const hS = inputs.spot * 1e-5;
      const delta = (at({ spot: inputs.spot + hS }) - at({ spot: inputs.spot - hS })) / (2 * hS);
      const gamma = (at({ spot: inputs.spot + hS }) - 2 * at({}) + at({ spot: inputs.spot - hS }))
        / (hS * hS);

      const hV = 1e-6;
      const vega = (at({ vol: inputs.vol + hV }) - at({ vol: inputs.vol - hV })) / (2 * hV);

      const hR = 1e-6;
      const rho = (at({ rate: inputs.rate + hR }) - at({ rate: inputs.rate - hR })) / (2 * hR);

      const hT = Math.min(1e-6, inputs.time / 2);
      const theta = (at({ time: inputs.time - hT }) - at({ time: inputs.time + hT })) / (2 * hT);

      const label = `${type} ${JSON.stringify(contract)}`;
      assert.ok(Math.abs(g.delta - delta) < 1e-6, `delta ${label}: ${g.delta} vs ${delta}`);
      // Gamma is a second difference, so it carries far more rounding noise.
      assert.ok(Math.abs(g.gamma - gamma) < 1e-3 * Math.max(1, Math.abs(gamma)),
        `gamma ${label}: ${g.gamma} vs ${gamma}`);
      assert.ok(Math.abs(g.vegaPerUnitVol - vega) < 1e-4, `vega ${label}: ${g.vegaPerUnitVol} vs ${vega}`);
      assert.ok(Math.abs(g.rhoPerUnitRate - rho) < 1e-4, `rho ${label}: ${g.rhoPerUnitRate} vs ${rho}`);
      assert.ok(Math.abs(g.thetaPerYear - theta) < 1e-4, `theta ${label}: ${g.thetaPerYear} vs ${theta}`);
    }
  }
});

test('expired and zero-volatility options collapse to their payoffs', () => {
  assert.equal(bs.price({ ...base, time: 0, spot: 120, type: 'call' }), 20);
  assert.equal(bs.price({ ...base, time: 0, spot: 80, type: 'call' }), 0);
  assert.equal(bs.price({ ...base, time: 0, spot: 80, type: 'put' }), 20);

  // Zero vol: the forward is known, so the option is a discounted certainty.
  const zero = { ...base, vol: 0, time: 2, rate: 0.05 };
  const forward = 100 * Math.exp(0.1);
  assert.ok(Math.abs(bs.price({ ...zero, type: 'call' })
    - (forward - 100) * Math.exp(-0.1)) < 1e-12);
  assert.equal(bs.price({ ...zero, type: 'put' }), 0);

  // And the limit is approached continuously from above.
  assert.ok(Math.abs(bs.price({ ...zero, vol: 1e-7, type: 'call' })
    - bs.price({ ...zero, type: 'call' })) < 1e-4);
});

test('bad inputs are rejected', () => {
  assert.throws(() => bs.price({ ...base, spot: 0, type: 'call' }), RangeError);
  assert.throws(() => bs.price({ ...base, strike: -1, type: 'call' }), RangeError);
  assert.throws(() => bs.price({ ...base, time: -1, type: 'call' }), RangeError);
  assert.throws(() => bs.price({ ...base, vol: -0.2, type: 'call' }), RangeError);
  assert.throws(() => bs.price({ ...base, type: 'straddle' }), RangeError);
});

test('the binomial tree converges to Black-Scholes for European exercise', () => {
  for (const contract of sampleContracts()) {
    for (const type of ['call', 'put']) {
      const inputs = { ...contract, type };
      const tree = binomial.price({ ...inputs, steps: 600, american: false });
      const closed = bs.price(inputs);
      assert.ok(Math.abs(tree - closed) < 2e-3 * Math.max(1, closed),
        `${type} ${JSON.stringify(contract)}: tree ${tree} vs BS ${closed}`);
    }
  }
});

test('tree error falls as O(1/steps)', () => {
  // Averaging the odd and even trees removes the oscillation but leaves a
  // smooth first-order error, so doubling the steps should roughly halve it.
  const inputs = { ...base, type: 'call' };
  const closed = bs.price(inputs);
  const errorAt = (steps) =>
    Math.abs(binomial.price({ ...inputs, steps, american: false }) - closed);

  let previous = errorAt(100);
  for (const steps of [200, 400, 800, 1600]) {
    const current = errorAt(steps);
    const ratio = previous / current;
    assert.ok(ratio > 1.8 && ratio < 2.2,
      `error ratio at ${steps} steps was ${ratio.toFixed(3)}, expected about 2`);
    previous = current;
  }
  assert.ok(previous < 1e-4, `1600 steps still off by ${previous}`);
});

test('American exercise is worth at least European exercise', () => {
  for (const contract of sampleContracts()) {
    for (const type of ['call', 'put']) {
      const inputs = { ...contract, type, steps: 200 };
      const american = binomial.price({ ...inputs, american: true });
      const european = binomial.price({ ...inputs, american: false });
      assert.ok(american >= european - 1e-9,
        `${type} ${JSON.stringify(contract)}: ${american} < ${european}`);
      assert.ok(american >= bs.intrinsic(inputs) - 1e-9, 'priced below intrinsic');
    }
  }
});

test('an American call on a non-dividend payer is never exercised early', () => {
  for (const contract of sampleContracts()) {
    if (contract.yield !== 0 || contract.rate < 0) continue;
    const inputs = { ...contract, type: 'call', steps: 200 };
    const american = binomial.price({ ...inputs, american: true });
    const european = binomial.price({ ...inputs, american: false });
    assert.ok(Math.abs(american - european) < 1e-10,
      `early exercise had value at ${JSON.stringify(contract)}`);
  }
  assert.equal(binomial.earlyExerciseBoundary({ ...base, type: 'call', steps: 80 }), null);
});

test('the early-exercise boundary sits where holding stops paying', () => {
  const boundary = binomial.earlyExerciseBoundary({ ...base, type: 'put', steps: 150 });
  assert.ok(boundary > 0 && boundary < base.strike, `boundary ${boundary} out of range`);

  const inputs = { ...base, type: 'put', steps: 150, american: true };
  // Just below the boundary the option is worth exactly its intrinsic value.
  const below = binomial.price({ ...inputs, spot: boundary * 0.97 });
  assert.ok(Math.abs(below - (base.strike - boundary * 0.97)) < 1e-6,
    `below the boundary the option should be at intrinsic, got ${below}`);
  // Just above it, holding is still worth something extra.
  const above = binomial.price({ ...inputs, spot: boundary * 1.03 });
  assert.ok(above > base.strike - boundary * 1.03 + 1e-6,
    'above the boundary there should be time value left');

  // A dividend-paying stock does give an American call an exercise boundary.
  const callBoundary = binomial.earlyExerciseBoundary({
    ...base, type: 'call', yield: 0.08, steps: 150,
  });
  assert.ok(callBoundary > base.strike, `expected a boundary above the strike, got ${callBoundary}`);
});

test('tree Greeks agree with the analytic ones for European exercise', () => {
  for (const contract of sampleContracts()) {
    if (contract.time < 0.2) continue; // very short trees are too coarse to compare
    for (const type of ['call', 'put']) {
      const inputs = { ...contract, type, steps: 500 };
      const tree = binomial.greeks({ ...inputs, american: false });
      const exact = bs.greeks(inputs);
      const label = `${type} ${JSON.stringify(contract)}`;
      // Delta and gamma come off the tree's own nodes and are tight. Vega,
      // theta and rho are differences of two tree prices, so they inherit the
      // tree's ~1% discretisation error and need a relative tolerance.
      const close = (got, want, absolute, relative) =>
        Math.abs(got - want) < Math.max(absolute, relative * Math.abs(want));
      assert.ok(close(tree.delta, exact.delta, 2e-3, 0), `delta ${label}`);
      assert.ok(close(tree.gamma, exact.gamma, 2e-3, 0), `gamma ${label}`);
      assert.ok(close(tree.vegaPerUnitVol, exact.vegaPerUnitVol, 0.05, 0.02), `vega ${label}`);
      assert.ok(close(tree.thetaPerYear, exact.thetaPerYear, 0.05, 0.02), `theta ${label}`);
      assert.ok(close(tree.rhoPerUnitRate, exact.rhoPerUnitRate, 0.05, 0.02), `rho ${label}`);
    }
  }
});

test('implied volatility recovers the volatility that made the price', () => {
  for (const contract of sampleContracts()) {
    for (const type of ['call', 'put']) {
      const inputs = { ...contract, type };
      const target = bs.price(inputs);
      const vega = bs.vega(inputs);

      // A price only carries volatility information if it responds to
      // volatility at all. Deep in or out of the money the price sits on top
      // of its zero-volatility limit to the last bit of a double, and there
      // is genuinely nothing to invert.
      const resolution = 64 * Number.EPSILON * Math.max(inputs.spot, inputs.strike);
      if (target - bs.price({ ...inputs, vol: 0 }) <= resolution) continue;

      const { vol, identifiable } = impliedVol({ ...inputs, price: target });
      assert.ok(identifiable, `not identifiable at ${JSON.stringify(inputs)}`);
      // Recoverable precision is bounded by how far the price moves per unit
      // of volatility: a tiny vega means the last digits are unrecoverable no
      // matter how good the solver is.
      const achievable = Math.max(1e-9, (10 * resolution) / vega);
      assert.ok(Math.abs(vol - contract.vol) < achievable,
        `${type} ${JSON.stringify(contract)}: got ${vol}, want ${contract.vol} ` +
        `(achievable ${achievable.toExponential(2)})`);
    }
  }
});

test('implied volatility handles extreme but valid quotes', () => {
  for (const vol of [0.02, 0.05, 1.5, 4]) {
    const inputs = { ...base, vol, type: 'call' };
    const solved = impliedVol({ ...inputs, price: bs.price(inputs) });
    assert.ok(Math.abs(solved.vol - vol) < 1e-6, `got ${solved.vol}, want ${vol}`);
  }
});

test('a quote that carries no volatility information is reported as such', () => {
  // At 0.5% volatility this call is worth its discounted forward intrinsic to
  // within 1e-14, and vega is about 7e-21. No solver can recover 0.005 from
  // that price, so the honest answer is "not identifiable" rather than a
  // number invented from rounding noise.
  const inputs = { ...base, vol: 0.005, type: 'call' };
  assert.ok(bs.vega(inputs) < 1e-15);
  const solved = impliedVol({ ...inputs, price: bs.price(inputs) });
  assert.equal(solved.identifiable, false);
});

test('implied volatility works against an American tree', () => {
  const inputs = { spot: 100, strike: 110, time: 1, rate: 0.05, yield: 0, type: 'put', steps: 200 };
  for (const vol of [0.2, 0.35, 0.8]) {
    const target = binomial.price({ ...inputs, vol, american: true });
    const solved = impliedVol({ ...inputs, price: target, american: true });
    assert.ok(Math.abs(solved.vol - vol) < 1e-4, `got ${solved.vol}, want ${vol}`);
  }
});

test('implied volatility rejects prices that no volatility can produce', () => {
  const call = { ...base, type: 'call' };
  assert.throws(() => impliedVol({ ...call, price: 0.5 }), /below the no-arbitrage floor/);
  assert.throws(() => impliedVol({ ...call, price: 120 }), /above the no-arbitrage ceiling/);
  assert.throws(() => impliedVol({ ...call, time: 0, price: 5 }), /expired/);
  assert.throws(() => impliedVol({ ...call, price: NaN }), /finite/);
});

test('an American option quoted at intrinsic has no identifiable volatility', () => {
  // Below its exercise boundary the tree returns intrinsic for every
  // volatility, so there is no single number to report.
  const deepItm = { spot: 100, strike: 130, time: 1, rate: 0.05, yield: 0, type: 'put' };
  const result = impliedVol({ ...deepItm, price: 30, american: true });
  assert.equal(result.identifiable, false);
  assert.equal(result.vol, 0);
});

test('valuation ties the pieces together', () => {
  const european = valuation({ ...base, type: 'call' });
  assert.ok(Math.abs(european.fairValue - bs.price({ ...base, type: 'call' })) < 1e-12);
  assert.equal(european.earlyExercisePremium, null);
  assert.ok(Math.abs(european.breakEven - (100 + european.fairValue)) < 1e-12);
  assert.ok(Math.abs(european.timeValue + european.intrinsic - european.fairValue) < 1e-12);

  const american = valuation({ ...base, type: 'put', style: 'american', steps: 200 });
  assert.ok(american.fairValue > american.europeanValue, 'American put should carry a premium');
  assert.ok(american.earlyExercisePremium > 0);
  assert.ok(american.earlyExerciseBoundary > 0);
  assert.ok(Math.abs(american.probabilities.itm - 0.4403823076297575) < 1e-9);
});

test('the value curve never dips below the payoff at expiry', () => {
  for (const style of ['european', 'american']) {
    const curve = valueCurve({ ...base, type: 'put', style, steps: 120 }, { points: 40 });
    assert.equal(curve.length, 40);
    for (const point of curve) {
      // A European put can trade below intrinsic; it cannot trade below the
      // discounted payoff, which is what its curve must respect.
      const floor = style === 'american'
        ? point.payoff
        : Math.max(base.strike * Math.exp(-base.rate * base.time) - point.spot, 0);
      assert.ok(point.value >= floor - 1e-6,
        `${style} curve dipped below its floor at spot ${point.spot}`);
    }
    // Values increase monotonically as a put goes further in the money.
    for (let i = 1; i < curve.length; i++) {
      assert.ok(curve[i].value <= curve[i - 1].value + 1e-6, 'put value should fall as spot rises');
    }
  }
});

test('employee grant value applies the expected term and forfeiture', () => {
  const grant = {
    spot: 12, strike: 12, expectedTerm: 6, vol: 0.55, rate: 0.04,
    quantity: 10000, forfeitureRate: 0.05, vestingYears: 4,
  };
  const result = employeeGrantValue(grant);

  const expectedPerOption = bs.price({
    spot: 12, strike: 12, time: 6, vol: 0.55, rate: 0.04, yield: 0, type: 'call',
  });
  assert.ok(Math.abs(result.perOption - expectedPerOption) < 1e-12);
  assert.ok(Math.abs(result.retention - Math.pow(0.95, 4)) < 1e-12);
  assert.ok(Math.abs(result.expectedExpense - result.perOption * result.expectedToVest) < 1e-9);
  assert.ok(Math.abs(result.annualExpense * 4 - result.expectedExpense) < 1e-9);

  // No forfeiture assumption means the whole grant is expected to vest.
  const clean = employeeGrantValue({ ...grant, forfeitureRate: 0 });
  assert.equal(clean.expectedToVest, 10000);
  assert.ok(Math.abs(clean.expectedExpense - clean.grossValue) < 1e-9);
});
