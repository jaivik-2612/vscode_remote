# Option Fair Value

Works out what a stock option is worth, and what a quoted price implies about
the market's volatility expectations.

No dependencies. `npm start` and `npm test` work on a fresh clone.

```
npm start          # web app at http://127.0.0.1:8080
npm test           # 30 tests, no install needed
node build-artifact.mjs   # bundle the app into one standalone HTML file
node bin/optprice.js --spot 100 --strike 105 --days 90 --vol 25
```

## What it does

**Price an option.** Black-Scholes-Merton for European exercise, a
Cox-Ross-Rubinstein binomial tree for American. You get the fair value, the
split between intrinsic and time value, all five Greeks, the break-even, and
the risk-neutral chance of finishing in the money or touching the strike.

**Imply volatility from a price.** Point it at a traded price and it solves
for the volatility that reproduces it, so you can compare the market's number
against your own.

**Value an employee grant.** ASC 718 grant-date fair value: Black-Scholes over
the expected term rather than the contractual term, then reduced by the
options expected to be forfeited before vesting.

## Using it as a library

```js
import { valuation, impliedVol, yearsFromDays } from './src/index.js';

const result = valuation({
  spot: 100,
  strike: 105,
  time: yearsFromDays(90),
  vol: 0.25,        // 25% annualised
  rate: 0.045,      // continuously compounded
  yield: 0,         // continuous dividend yield
  type: 'call',
  style: 'american', // or 'european'
});

result.fairValue;             // 3.3541
result.greeks.delta;          // 0.4046
result.earlyExercisePremium;  // what the right to exercise early is worth
result.earlyExerciseBoundary; // the spot at which exercising beats holding
```

Rates and yields are continuously compounded, times are in years, and
volatility is a decimal rather than a percentage. The Greeks use the
conventions you see on a broker screen: **vega** per volatility point, **theta**
per calendar day, **rho** per percentage point of rates.

Going the other way:

```js
const { vol, identifiable } = impliedVol({
  spot: 100, strike: 105, time: yearsFromDays(90),
  rate: 0.045, yield: 0, type: 'call',
  price: 3.20,
});
```

`identifiable: false` means the quote sits somewhere the price does not move
with volatility — an American option trading at intrinsic, or an option so
deep in or out of the money that its price is flat in volatility. There is no
number to report there, and the solver says so rather than inventing one from
rounding noise.

## Layout

```
src/stats.js         normal CDF and its inverse
src/blackScholes.js  European pricing, Greeks, probabilities
src/binomial.js      American pricing, early-exercise boundary
src/impliedVol.js    volatility solver
src/index.js         valuation(), valueCurve(), employeeGrantValue()
web/                 browser UI
bin/optprice.js      command line
server.js            static server for the web UI
build-artifact.mjs   bundles web/ + src/ into dist/option-fair-value.html
```

`build-artifact.mjs` inlines the stylesheet and rewrites every module into an
IIFE so the whole app runs from a single file with no imports to resolve. It
reads the real sources rather than a second copy, so the standalone build
cannot drift from the served one.

## Accuracy

The normal CDF is Hart's rational approximation: absolute error around 1e-15,
and 8 significant digits even ten standard deviations out. That headroom
matters because the volatility solver differentiates the pricing function.

The binomial tree averages an odd and an even tree, which cancels the
oscillation you would otherwise see as steps are added. The remaining error is
smooth and **O(1/steps)** — around 3e-4 on a $10 option at the 400-step default.
Delta, gamma and theta are read off the tree's own nodes rather than by
bumping inputs, so they carry no finite-difference noise; vega and rho are
bumped and inherit the tree's ~1% discretisation error.

The test suite checks textbook values, put-call parity, no-arbitrage bounds,
every Greek against finite differences of the price, the tree's convergence
order, American-versus-European invariants, implied-volatility round trips,
and the first-passage probability against a seeded simulation.

## Assumptions worth knowing

These are the standard Black-Scholes assumptions, and they are what the
numbers rest on:

- Volatility is constant over the option's life. Real markets have a
  volatility smile — different strikes imply different volatilities.
- Dividends are a continuous yield, not discrete payments on known dates. For
  a stock with a large dividend just before expiry, this is a real
  simplification.
- The underlying moves as geometric Brownian motion, so no jumps.

A fair value is only as good as the volatility, rate and dividend estimates
you feed in — volatility especially, since it is the one input you cannot look
up. This is an educational tool, not investment advice.
