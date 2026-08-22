# FairShare

An educational fair-price calculator for stock options. The **Simple** view
answers two questions in plain language — what is this option fairly worth,
and where might the stock be on the day you pick — while the **Advanced**
view opens up the full machinery: volatility regimes, the three-model
ensemble, implied volatility and grant valuation.

FairShare is for education only. Nothing it produces is investment advice, a
recommendation, or a prediction of what will actually happen.

No dependencies. `npm start` and `npm test` work on a fresh clone.

```
npm start          # web app at http://127.0.0.1:8080
npm test           # no install needed
npm run refresh-data   # update the bundled symbol directory and yield curves
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
src/market.js        ticker search, provider-format parsing, yield curves
src/series.js        parsing a pasted history into returns and volatility
src/hmm.js           Baum-Welch: fits volatility regimes to the returns
src/monteCarlo.js    path simulation, Longstaff-Schwartz, distributions
src/valuation.js     valuation(), valueCurve(), employeeGrantValue()
src/ensemble.js      runs all three engines and reconciles them
src/index.js         package entry point
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


## Ticker lookup and auto-population

Start typing a ticker or company name in the `Three models` tab and pick from
the popup — it searches 17,000+ listings across NASDAQ, NYSE (incl. American
and Arca), Cboe BZX, IEX, TSX and TSX Venture. Selecting a ticker fills in:

- **price history** — two years of daily closes,
- **current price** — the last close (the strike also snaps to the nearest
  listed increment at the money, unless you have edited it),
- **risk-free rate** — interpolated from the US Treasury or Bank of Canada
  curve at your chosen expiry, re-interpolated when you change the days
  (a hand-edited rate is never overwritten),
- **volatility and drift** — estimated from the history by the three-model
  pipeline itself.

### Data sources — all official or first-party

| Data | Source |
|---|---|
| US symbol directory | Nasdaq Trader symbol files (`nasdaqlisted`, `otherlisted`) |
| Canadian directory | TMX Group company directory (tsx.com) |
| US daily history | Nasdaq's historical quote API (Yahoo Finance chart as fallback) |
| Canadian daily history | TMX Group's time-series API (Yahoo Finance as fallback) |
| US risk-free curve | U.S. Treasury daily par yield curve |
| Canadian risk-free curve | Bank of Canada Valet API |

Par yields are converted to continuously compounded rates (r = 2 ln(1 + y/2))
before the models see them. Raw close series are scanned for split cliffs and
repaired, with every repair reported in the UI.

The local app (`npm start`) fetches history live through a small proxy in
`server.js` — the providers send no CORS headers, so the browser cannot call
them directly. The published artifact cannot reach the network at all (its
host blocks every external request, and a framed Google Sheet could not be
read across origins even if it rendered), so it embeds the symbol directory
and yield-curve snapshots at build time and drives the history through
Google Sheets with one copy-paste hop: selecting a ticker writes the
GOOGLEFINANCE formula with the right exchange prefix (`NYSE:RY` vs
`TSE:RY`), a click opens a fresh sheet, and the drop zone reads the two
columns the sheet fills exactly as Sheets copies them — datetime-suffixed
dates, US or European number locales, `#N/A` rows and all. Stooq CSV, Yahoo
chart JSON, Nasdaq JSON, a generic date/close CSV, or a bare list of prices
drop in just the same.

`npm run refresh-data` refreshes `data/tickers.json` and `data/rates.json`;
both carry their as-of dates and the UI displays them.

## Install as an app (PWA)

Every push deploys the installable build to GitHub Pages
(`.github/workflows/pages.yml`). Open the published URL on a phone and:

- **iPhone / iPad** — Share button → *Add to Home Screen*. FairShare installs
  with the dial icon, launches full-screen, and works offline.
- **Android** — Chrome offers *Install app* from the menu.

The service worker precaches the entire app (it is one self-contained
document), so after the first visit it runs with no connection at all. Each
build carries a content-hashed cache name, so updates arrive on the next
launch after a deploy.

## Native apps (Capacitor)

The repo carries a Capacitor scaffold that wraps the exact same bundle as a
native Android and iOS app:

```
npm install          # Capacitor tooling (the web app itself needs nothing)
npm run build:app    # bundle to dist/app/ and sync both native projects
npx cap open android # Android Studio, build the AAB
npx cap open ios     # Xcode (macOS), archive and upload
```

App icons and splash screens are generated from `resources/` by
`npx capacitor-assets generate --android --ios`.

You do not need Android Studio to produce a release build: the **Android
build** workflow bundles, signs and verifies an AAB on every push. Without
signing secrets it uses a throwaway key and discards the result, so the
release path is proven continuously rather than being attempted for the
first time on the day it matters.

Publishing lives in `docs/`:

| | |
|---|---|
| [`SIGNING-WINDOWS.md`](docs/SIGNING-WINDOWS.md) | Generating the upload keystore, encoding it for GitHub, downloading and verifying the bundle, and testing it on a phone — all from Windows, no Mac needed |
| [`store/SUBMISSION.md`](docs/store/SUBMISSION.md) | The Play Console runbook, from registration through the 14-day closed test to production |
| [`store/LISTING.md`](docs/store/LISTING.md) | Listing copy, categories, and alt text, within Play's character limits |
| [`store/PRIVACY.md`](docs/store/PRIVACY.md) | The privacy policy, published to Pages as `/privacy.html` by the same build |

Store graphics are generated from the running app by
`node tools/store-assets.mjs` — icon, feature graphic, and screenshots for
phone and both tablet sizes, all at exactly the dimensions Play validates.
Re-run it whenever the UI changes so the listing never shows a stale screen.

## The three engines

The `Three models` tab starts from a price history rather than a volatility you
guess, and runs three things in order. They are not peers:

**Baum-Welch** is expectation-maximisation for a hidden Markov model. It does
not price anything — it cannot. What it does is read the return series and
recover the volatility *regimes* that generated it: a volatility per regime,
the probability of switching between them, and which regime today sits in.
Propagating that chain over the option's life gives the expected variance to
expiry, and that is the volatility the pricing models are otherwise missing.

**Black-Scholes** then prices the contract in closed form twice — once on plain
trailing volatility, once on the regime-projected number. The gap between them
is exactly what the regime model contributed.

**Monte Carlo** simulates paths whose volatility switches regime as they go and
prices from the discounted payoffs. Unlike the closed form it keeps the
volatility-of-volatility, so where the two disagree it is measuring what
collapsing the regimes into a single number costs. American exercise is priced
by Longstaff-Schwartz least squares on the same paths.

Re-running the simulation under the drift estimated from the history, rather
than the risk-free rate, gives the projected distribution of the stock itself.

### What the numbers are worth

- The projected price is a **model projection, not a forecast**. It rests on a
  drift estimated from a few hundred observations, and drift is far noisier
  than volatility — the 90% band is wide for a reason.
- Probabilities shown against a price are **risk-neutral**: they describe what
  the price implies, not what the stock is expected to do.
- Fitting more regimes always improves the in-sample likelihood, so the app
  scores 2, 3 and 4 states by BIC and says which the data actually supports. A
  regime the chain almost never visits is flagged as a fitting artefact.
- Every simulation is seeded, so the same inputs always give the same price.
  Change the seed to see how much the answer moves on luck alone.

### Validation

The models are checked against things with known answers, not just against
themselves: Baum-Welch recovers the parameters of a synthetic HMM it was never
told about, its log-likelihood is asserted never to decrease, simulated
European prices land inside their own 95% confidence interval of the
Black-Scholes closed form, Longstaff-Schwartz matches a 2000-step binomial
tree, and risk-neutral paths are asserted to keep the discounted stock a
martingale. The app also runs a live control at every valuation: it reprices
the contract by simulation under plain GBM, where the closed form is exact, and
reports the gap.
