/**
 * Market reference data: ticker search, price-history parsing from the
 * formats real data providers hand out, and yield-curve interpolation.
 *
 * The parsing accepts anything a person plausibly ends up with after
 * following a data link — a Stooq CSV download, Nasdaq's historical JSON,
 * Yahoo's chart JSON, a generic date/close CSV out of a spreadsheet, or a
 * bare column of numbers — and turns them all into the same shape: closing
 * prices, oldest first.
 */

import { parsePrices } from './series.js';

/* ------------------------------------------------------------- exchanges */

const EXCHANGES = {
  Q: { name: 'NASDAQ', country: 'US', currency: 'USD', yahooSuffix: '' },
  N: { name: 'NYSE', country: 'US', currency: 'USD', yahooSuffix: '' },
  A: { name: 'NYSE American', country: 'US', currency: 'USD', yahooSuffix: '' },
  P: { name: 'NYSE Arca', country: 'US', currency: 'USD', yahooSuffix: '' },
  Z: { name: 'Cboe BZX', country: 'US', currency: 'USD', yahooSuffix: '' },
  V: { name: 'IEX', country: 'US', currency: 'USD', yahooSuffix: '' },
  T: { name: 'TSX', country: 'CA', currency: 'CAD', yahooSuffix: '.TO' },
  X: { name: 'TSXV', country: 'CA', currency: 'CAD', yahooSuffix: '.V' },
};

/** Everything the UI needs to know about an exchange code. */
export function exchangeInfo(code) {
  return EXCHANGES[code] ?? { name: code, country: 'US', currency: 'USD', yahooSuffix: '' };
}

/** Yahoo Finance symbol for a directory entry: BRK.B -> BRK-B, RY on TSX -> RY.TO. */
export function yahooSymbol(symbol, exchangeCode) {
  return symbol.replace(/\./g, '-') + exchangeInfo(exchangeCode).yahooSuffix;
}

/** Stooq symbol for a US directory entry: AAPL -> aapl.us. Stooq has no TSX. */
export function stooqSymbol(symbol, exchangeCode) {
  if (exchangeInfo(exchangeCode).country !== 'US') return null;
  return `${symbol.replace(/\./g, '-').toLowerCase()}.us`;
}

/* ---------------------------------------------------------------- search */

/**
 * Rank the ticker directory against what the user has typed so far.
 *
 * Scoring, best first: exact symbol, symbol prefix, then name matches, then
 * symbol substring, then name substring. Among name matches, a name that
 * *starts* with the query beats a word-start match deeper in ("Shopify
 * Inc." over "Ninepoint Shopify ETF"), and a query that covers more of the
 * matched word ranks higher ("appl" puts Apple's five-letter word ahead of
 * Applied's seven). Ties break toward shorter symbols and then
 * alphabetically, so the order is stable while typing.
 *
 * @param {Array<[string,string,string,number]>} tickers [symbol,name,exchange,isEtf]
 * @param {string} query
 * @param {number} [limit]
 */
export function searchTickers(tickers, query, limit = 8) {
  const q = query.trim().toUpperCase();
  if (!q) return [];
  const qLower = query.trim().toLowerCase();

  const scored = [];
  for (const [symbol, name, exchange, isEtf] of tickers) {
    let score;
    const symbolUpper = symbol.toUpperCase();
    if (symbolUpper === q) score = 0;
    else if (symbolUpper.startsWith(q)) score = 1;
    else {
      const nameLower = name.toLowerCase();
      const at = nameLower.indexOf(qLower);
      const wordStart = at === 0 || (at > 0 && nameLower[at - 1] === ' ');
      if (wordStart) {
        const wordEnd = nameLower.indexOf(' ', at);
        const wordLength = (wordEnd === -1 ? nameLower.length : wordEnd) - at;
        const uncovered = Math.min(0.9, Math.max(0, wordLength - qLower.length) * 0.05);
        score = (at === 0 ? 2 : 2.95) + uncovered;
      } else if (symbolUpper.includes(q)) score = 4;
      else if (at > 0) score = 5;
      else continue;
    }
    scored.push({ symbol, name, exchange, isEtf: Boolean(isEtf), score });
  }

  scored.sort((a, b) =>
    a.score - b.score ||
    a.symbol.length - b.symbol.length ||
    a.symbol.localeCompare(b.symbol) ||
    a.exchange.localeCompare(b.exchange));

  return scored.slice(0, limit).map(({ score, ...entry }) => {
    // Careful with the spread order: exchangeInfo has its own `name` (the
    // exchange's), which must not clobber the company name.
    const { name: exchangeName, country, currency, yahooSuffix } = exchangeInfo(entry.exchange);
    return { ...entry, exchangeName, country, currency, yahooSuffix };
  });
}

/* ------------------------------------------------------------ histories */

/**
 * Detect and undo share splits in a raw close series.
 *
 * Unadjusted closes (Nasdaq's historical API, TMX) contain a cliff at every
 * split — a 10:1 split reads as a −90% day and would wreck any volatility
 * estimate. A one-day move whose ratio sits within tolerance of a simple
 * split fraction (n:1 or 1:n, n ≤ 50) is treated as a split and the earlier
 * segment rescaled. Genuine −50% days exist, so this is a heuristic; every
 * repair is reported so the UI can say what it did rather than fix silently.
 *
 * Series that are already adjusted (Yahoo's adjclose, Stooq) have no such
 * cliffs, so the pass leaves them alone.
 */
export function repairSplits(prices, dates = null) {
  const repaired = prices.slice();
  const splits = [];

  for (let i = repaired.length - 1; i >= 1; i--) {
    const ratio = repaired[i - 1] / repaired[i];
    if (ratio < 1.6 && ratio > 1 / 1.6) continue;

    const candidate = ratio > 1 ? ratio : 1 / ratio;
    let matched = null;
    for (let n = 2; n <= 50; n++) {
      if (Math.abs(candidate / n - 1) < 0.02) { matched = n; break; }
    }
    if (matched === null) continue;

    const factor = ratio > 1 ? matched : 1 / matched;
    for (let j = 0; j < i; j++) repaired[j] /= factor;
    splits.push({
      index: i,
      date: dates?.[i] ?? null,
      ratio: ratio > 1 ? `${matched}:1` : `1:${matched}`,
    });
  }

  return { prices: repaired, splits: splits.reverse() };
}

const isYahooChart = (json) => Boolean(json?.chart?.result?.[0]?.timestamp);
const isNasdaqHistory = (json) => Boolean(json?.data?.tradesTable?.rows);
const isTmxSeries = (json) => Boolean(json?.data?.getTimeSeriesData);

function fromYahooChart(json) {
  const result = json.chart.result[0];
  const quote = result.indicators?.quote?.[0]?.close ?? [];
  // adjclose backs out splits and dividends, which is what a return series
  // wants; fall back to raw closes when it is absent.
  const adjusted = result.indicators?.adjclose?.[0]?.adjclose;
  const closes = adjusted ?? quote;

  const prices = [];
  const dates = [];
  for (let i = 0; i < closes.length; i++) {
    if (closes[i] === null || closes[i] === undefined) continue;
    prices.push(closes[i]);
    dates.push(new Date(result.timestamp[i] * 1000).toISOString().slice(0, 10));
  }
  return {
    prices, dates,
    source: 'Yahoo Finance chart JSON',
    adjusted: Boolean(adjusted),
    symbol: result.meta?.symbol ?? null,
    currency: result.meta?.currency ?? null,
  };
}

function fromNasdaqHistory(json) {
  const rows = json.data.tradesTable.rows; // newest first
  const prices = [];
  const dates = [];
  for (let i = rows.length - 1; i >= 0; i--) {
    const close = Number(String(rows[i].close).replace(/[$,]/g, ''));
    if (!Number.isFinite(close) || close <= 0) continue;
    prices.push(close);
    const [month, day, year] = String(rows[i].date).split('/');
    dates.push(`${year}-${month}-${day}`);
  }
  return {
    prices, dates,
    source: 'Nasdaq historical JSON',
    adjusted: false,
    symbol: json.data.symbol ?? null,
    currency: 'USD',
  };
}

function fromTmxSeries(json) {
  const rows = [...json.data.getTimeSeriesData]
    .filter((row) => Number.isFinite(row?.close) && row.close > 0)
    .sort((a, b) => String(a.dateTime).localeCompare(String(b.dateTime)));
  return {
    prices: rows.map((row) => row.close),
    dates: rows.map((row) => String(row.dateTime).slice(0, 10)),
    source: 'TMX time series',
    adjusted: false,
    symbol: null,
    currency: 'CAD',
  };
}

function fromCsv(text) {
  const lines = text.trim().split(/\r?\n/);
  const header = lines[0].toLowerCase().split(/[,;\t]/).map((cell) => cell.trim());
  const dateCol = header.findIndex((cell) => cell === 'date' || cell === 'data');
  // Prefer an adjusted-close column when the file has one.
  let closeCol = header.findIndex((cell) => cell.replace(/[\s_]/g, '') === 'adjclose');
  let adjusted = closeCol !== -1;
  if (closeCol === -1) closeCol = header.findIndex((cell) => cell === 'close' || cell === 'zamkniecie');
  if (dateCol === -1 || closeCol === -1) return null;

  const rows = [];
  for (let i = 1; i < lines.length; i++) {
    const cells = lines[i].split(/[,;\t]/);
    const close = Number(String(cells[closeCol] ?? '').replace(/[$"\s]/g, ''));
    const date = String(cells[dateCol] ?? '').replace(/"/g, '').trim();
    if (!Number.isFinite(close) || close <= 0 || !date) continue;
    rows.push({ date: normaliseDate(date), close });
  }
  rows.sort((a, b) => a.date.localeCompare(b.date));
  return {
    prices: rows.map((row) => row.close),
    dates: rows.map((row) => row.date),
    source: 'CSV', adjusted, symbol: null, currency: null,
  };
}

function normaliseDate(raw) {
  // MM/DD/YYYY -> YYYY-MM-DD; anything already ISO-ish passes through.
  const us = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (us) return `${us[3]}-${us[1].padStart(2, '0')}-${us[2].padStart(2, '0')}`;
  return raw;
}

/**
 * Parse whatever the user pasted or dropped into closing prices.
 *
 * @returns {{prices: number[], dates: string[]|null, source: string,
 *   adjusted: boolean, splits: Array, symbol: string|null,
 *   currency: string|null}|null} null when nothing usable was found.
 */
export function parseMarketData(text) {
  if (typeof text !== 'string' || text.trim() === '') return null;
  const trimmed = text.trim();

  let base = null;
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    let json;
    try { json = JSON.parse(trimmed); } catch { json = null; }
    if (json) {
      if (isYahooChart(json)) base = fromYahooChart(json);
      else if (isNasdaqHistory(json)) base = fromNasdaqHistory(json);
      else if (isTmxSeries(json)) base = fromTmxSeries(json);
      else return null; // JSON, but not a shape we know — say so, don't guess
    }
  }

  if (base === null && /(date|data)\s*[,;\t]/i.test(trimmed.split(/\r?\n/)[0] ?? '')) {
    base = fromCsv(trimmed);
  }

  if (base === null) {
    const prices = parsePrices(trimmed);
    if (prices.length === 0) return null;
    base = { prices, dates: null, source: 'pasted prices', adjusted: false, symbol: null, currency: null };
  }

  if (base === null || base.prices.length === 0) return null;

  // Adjusted series have no split cliffs; running the repair anyway costs
  // nothing and catches a mislabelled file.
  const { prices, splits } = repairSplits(base.prices, base.dates);
  return { ...base, prices, splits };
}

/* ---------------------------------------------------------------- yields */

/**
 * Risk-free rate for a horizon, linearly interpolated on the curve and
 * clamped to its ends. Returns a continuously compounded decimal.
 *
 * @param {Array<{days: number, rate: number}>} points sorted by days
 * @param {number} days
 */
export function rateForHorizon(points, days) {
  if (!points?.length) return null;
  if (days <= points[0].days) return points[0].rate;
  const last = points[points.length - 1];
  if (days >= last.days) return last.rate;
  for (let i = 1; i < points.length; i++) {
    if (days <= points[i].days) {
      const a = points[i - 1];
      const b = points[i];
      const w = (days - a.days) / (b.days - a.days);
      return a.rate + w * (b.rate - a.rate);
    }
  }
  return last.rate;
}
