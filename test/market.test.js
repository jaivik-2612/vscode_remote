import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import {
  searchTickers, parseMarketData, repairSplits, rateForHorizon,
  exchangeInfo, yahooSymbol, stooqSymbol,
} from '../src/market.js';

/* ---------------------------------------------------------------- search */

const DIRECTORY = [
  ['AAPL', 'Apple Inc. - Common Stock', 'Q', 0],
  ['AAPL', 'Apple CDR (CAD Hedged)', 'T', 0],
  ['APLE', 'Apple Hospitality REIT, Inc. Common Shares', 'N', 0],
  ['GAP', 'Gap, Inc. (The) Common Stock', 'N', 0],
  ['SPY', 'State Street SPDR S&P 500 ETF Trust', 'P', 1],
  ['RY', 'Royal Bank of Canada', 'T', 0],
  ['RY', 'Royal Bank Of Canada Common Stock', 'N', 0],
  ['SHOP', 'Shopify Inc. - Class A Subordinate Voting Shares', 'Q', 0],
  ['BRK.B', 'Berkshire Hathaway Inc. New Common Stock', 'N', 0],
];

test('an exact symbol outranks a prefix, which outranks a name match', () => {
  const hits = searchTickers(DIRECTORY, 'AAPL');
  // Both AAPL listings first (exact), then APLE only via name substring.
  assert.equal(hits[0].symbol, 'AAPL');
  assert.equal(hits[1].symbol, 'AAPL');
  assert.notEqual(hits[0].exchange, hits[1].exchange);

  const byName = searchTickers(DIRECTORY, 'royal');
  assert.equal(byName[0].symbol, 'RY');
});

test('"appl" ranks Apple above Applied and Applovin', () => {
  const crowded = [
    ...DIRECTORY,
    ['AIT', 'Applied Industrial Technologies, Inc. Common Stock', 'N', 0],
    ['APP', 'Applovin Corporation - Class A Common Stock', 'Q', 0],
  ];
  const hits = searchTickers(crowded, 'appl');
  assert.equal(hits[0].symbol, 'AAPL',
    `expected Apple first, got ${hits.map((h) => h.symbol).join(', ')}`);
});

test('a name-start match outranks a word buried mid-name', () => {
  const crowded = [
    ...DIRECTORY,
    ['SHHI', 'Ninepoint Shopify HighShares ETF', 'T', 0],
  ];
  const hits = searchTickers(crowded, 'shopify');
  assert.equal(hits[0].symbol, 'SHOP');
  assert.ok(hits.findIndex((h) => h.symbol === 'SHHI') > 0);
});

test('name matching respects word starts', () => {
  // "gap" starts the name "Gap, Inc." but also sits inside no other entry.
  const hits = searchTickers(DIRECTORY, 'gap');
  assert.equal(hits[0].symbol, 'GAP');
});

test('search decorates hits with exchange metadata', () => {
  const [hit] = searchTickers(DIRECTORY, 'SHOP');
  assert.equal(hit.name, 'Shopify Inc. - Class A Subordinate Voting Shares');
  assert.equal(hit.country, 'US');
  assert.equal(hit.currency, 'USD');
  // Both RY listings match "royal"; the TSX one must carry CAD metadata.
  const royals = searchTickers(DIRECTORY, 'royal');
  assert.equal(royals.length, 2);
  assert.equal(royals.find((hit) => hit.exchange === 'T').currency, 'CAD');
  assert.equal(royals.find((hit) => hit.exchange === 'N').currency, 'USD');
});

test('search honours the limit and an empty query returns nothing', () => {
  assert.equal(searchTickers(DIRECTORY, 'a', 3).length, 3);
  assert.deepEqual(searchTickers(DIRECTORY, '   '), []);
});

test('symbol translation for external providers', () => {
  assert.equal(yahooSymbol('BRK.B', 'N'), 'BRK-B');
  assert.equal(yahooSymbol('RY', 'T'), 'RY.TO');
  assert.equal(yahooSymbol('ABC', 'X'), 'ABC.V');
  assert.equal(stooqSymbol('BRK.B', 'N'), 'brk-b.us');
  assert.equal(stooqSymbol('RY', 'T'), null, 'Stooq has no Canadian listings');
  assert.equal(exchangeInfo('T').name, 'TSX');
});

/* --------------------------------------------------------------- parsing */

test('parses a Stooq-style CSV, oldest first', () => {
  const csv = 'Date,Open,High,Low,Close,Volume\n' +
    '2026-01-02,10,11,9,10.5,1000\n2026-01-03,10.5,12,10,11.25,900\n';
  const parsed = parseMarketData(csv);
  assert.deepEqual(parsed.prices, [10.5, 11.25]);
  assert.deepEqual(parsed.dates, ['2026-01-02', '2026-01-03']);
  assert.equal(parsed.source, 'CSV');
});

test('prefers an Adj Close column and reorders a newest-first CSV', () => {
  const csv = 'Date,Close,Adj Close\n01/03/2026,100,50\n01/02/2026,98,49\n';
  const parsed = parseMarketData(csv);
  assert.deepEqual(parsed.prices, [49, 50], 'adjusted column, oldest first');
  assert.equal(parsed.adjusted, true);
  assert.deepEqual(parsed.dates, ['2026-01-02', '2026-01-03']);
});

test('parses Yahoo chart JSON, preferring adjclose and skipping nulls', () => {
  const json = JSON.stringify({
    chart: {
      result: [{
        meta: { symbol: 'RY.TO', currency: 'CAD' },
        timestamp: [1755600000, 1755686400, 1755772800],
        indicators: {
          quote: [{ close: [100, null, 104] }],
          adjclose: [{ adjclose: [99, null, 104] }],
        },
      }],
    },
  });
  const parsed = parseMarketData(json);
  assert.deepEqual(parsed.prices, [99, 104]);
  assert.equal(parsed.adjusted, true);
  assert.equal(parsed.symbol, 'RY.TO');
  assert.equal(parsed.currency, 'CAD');
  assert.equal(parsed.dates.length, 2);
});

test('parses Nasdaq historical JSON with $ strings, newest first', () => {
  const json = JSON.stringify({
    data: {
      symbol: 'AAPL',
      tradesTable: {
        rows: [
          { date: '08/19/2026', close: '$316.83', volume: '50,505,650' },
          { date: '08/18/2026', close: '$310.10', volume: '41,000,000' },
        ],
      },
    },
  });
  const parsed = parseMarketData(json);
  assert.deepEqual(parsed.prices, [310.1, 316.83]);
  assert.deepEqual(parsed.dates, ['2026-08-18', '2026-08-19']);
  assert.equal(parsed.currency, 'USD');
});

test('parses a TMX time series and sorts it oldest first', () => {
  const json = JSON.stringify({
    data: {
      getTimeSeriesData: [
        { dateTime: '2026-08-20T16:00:00-04:00', close: 283.33 },
        { dateTime: '2026-08-19T16:00:00-04:00', close: 286.92 },
      ],
    },
  });
  const parsed = parseMarketData(json);
  assert.deepEqual(parsed.prices, [286.92, 283.33]);
  assert.equal(parsed.currency, 'CAD');
});

test('falls back to plain pasted numbers, and refuses unknown JSON', () => {
  assert.deepEqual(parseMarketData('100\n101\n102').prices, [100, 101, 102]);
  assert.equal(parseMarketData('{"totally":"unrelated"}'), null,
    'unknown JSON should be refused, not guessed at');
  assert.equal(parseMarketData(''), null);
  assert.equal(parseMarketData(null), null);
});

/* ---------------------------------------------------------------- splits */

test('a 10:1 split cliff is repaired and reported', () => {
  // 400, 402, 404 then a 10:1 split: 40.5, 40.9
  const { prices, splits } = repairSplits([400, 402, 404, 40.5, 40.9],
    ['d1', 'd2', 'd3', 'd4', 'd5']);
  assert.equal(splits.length, 1);
  assert.equal(splits[0].ratio, '10:1');
  assert.equal(splits[0].date, 'd4');
  assert.ok(Math.abs(prices[0] - 40) < 1e-9, `expected 40, got ${prices[0]}`);
  assert.equal(prices[4], 40.9, 'post-split prices untouched');
});

test('a reverse split is repaired the other way', () => {
  const { prices, splits } = repairSplits([2, 2.1, 2.05, 41.2, 40.8]);
  assert.equal(splits[0].ratio, '1:20');
  assert.ok(Math.abs(prices[0] - 40) < 1e-9);
});

test('a genuine crash is not mistaken for a split', () => {
  // -42% is catastrophic but nowhere near a clean 2:1 ratio.
  const { splits } = repairSplits([100, 101, 58, 57]);
  assert.equal(splits.length, 0);
});

test('an already-adjusted series passes through untouched', () => {
  const series = [100, 101.5, 99.8, 102.2, 101.1];
  const { prices, splits } = repairSplits(series);
  assert.deepEqual(prices, series);
  assert.equal(splits.length, 0);
});

test('parseMarketData applies split repair to raw CSV closes', () => {
  const csv = 'Date,Close\n2026-01-02,400\n2026-01-03,404\n2026-01-06,40.4\n2026-01-07,41\n';
  const parsed = parseMarketData(csv);
  assert.equal(parsed.splits.length, 1);
  assert.ok(Math.abs(parsed.prices[0] - 40) < 1e-9);
});

/* ---------------------------------------------------------------- yields */

const CURVE = [
  { days: 30, rate: 0.038 },
  { days: 91, rate: 0.0383 },
  { days: 365, rate: 0.0395 },
  { days: 3652, rate: 0.0464 },
];

test('the curve interpolates linearly and clamps at both ends', () => {
  assert.equal(rateForHorizon(CURVE, 7), 0.038, 'below the first tenor: clamp');
  assert.equal(rateForHorizon(CURVE, 30), 0.038, 'exact node');
  const mid = rateForHorizon(CURVE, (91 + 365) / 2);
  assert.ok(Math.abs(mid - (0.0383 + 0.0395) / 2) < 1e-12, 'midpoint interpolates');
  assert.equal(rateForHorizon(CURVE, 99999), 0.0464, 'beyond the last tenor: clamp');
  assert.equal(rateForHorizon([], 30), null);
  assert.equal(rateForHorizon(null, 30), null);
});

/* ------------------------------------------------------------ data files */

test('the bundled ticker directory is present and plausible', () => {
  const db = JSON.parse(readFileSync(new URL('../data/tickers.json', import.meta.url)));
  assert.ok(db.tickers.length > 15000, `only ${db.tickers.length} tickers`);
  assert.ok(db.asOf >= '2026-01-01');
  const aapl = db.tickers.find(([s, , x]) => s === 'AAPL' && x === 'Q');
  const ry = db.tickers.find(([s, , x]) => s === 'RY' && x === 'T');
  assert.ok(aapl && /apple/i.test(aapl[1]));
  assert.ok(ry && /royal bank/i.test(ry[1]));
  // No duplicate symbol+exchange pairs.
  const keys = new Set(db.tickers.map(([s, , x]) => `${s}|${x}`));
  assert.equal(keys.size, db.tickers.length);
});

test('the bundled yield curves are current-ish, ordered and sane', () => {
  const rates = JSON.parse(readFileSync(new URL('../data/rates.json', import.meta.url)));
  for (const country of ['us', 'ca']) {
    const { points, asOf } = rates[country];
    assert.ok(points.length >= 8, `${country}: only ${points.length} tenors`);
    assert.ok(asOf >= '2026-01-01', `${country} curve as of ${asOf}`);
    for (let i = 1; i < points.length; i++) {
      assert.ok(points[i].days > points[i - 1].days, `${country}: tenors out of order`);
    }
    for (const point of points) {
      assert.ok(point.rate > 0 && point.rate < 0.2,
        `${country} ${point.label}: ${point.rate} is not a believable risk-free rate`);
    }
  }
});
