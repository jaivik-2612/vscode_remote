/**
 * Refreshes the bundled market reference data.
 *
 * Everything here comes from an official or first-party source:
 *
 *   US symbols   Nasdaq Trader symbol directory (nasdaqlisted / otherlisted)
 *   CA symbols   TMX Group company directory (TSX and TSX Venture)
 *   US yields    U.S. Treasury daily par yield curve
 *   CA yields    Bank of Canada Valet API (T-bills and benchmark bonds)
 *
 * Run `npm run refresh-data` to update data/tickers.json and data/rates.json.
 * The files carry their own as-of dates; the UI shows them so a stale
 * snapshot is visible rather than silent.
 */

import { writeFile, mkdir } from 'node:fs/promises';

const UA = 'option-fair-value/1.0 (personal research tool)';

async function fetchText(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { 'User-Agent': UA, Accept: 'text/plain,application/json,*/*', ...options.headers },
  });
  if (!response.ok) throw new Error(`${url} -> HTTP ${response.status}`);
  return response.text();
}

const fetchJson = async (url, options) => JSON.parse(await fetchText(url, options));

/* ------------------------------------------------------------ US symbols */

/** Exchange codes used in tickers.json; the UI maps them to display names. */
const OTHER_EXCHANGE = { N: 'N', A: 'A', P: 'P', Z: 'Z', V: 'V' };

function parseNasdaqListed(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const cols = line.split('|');
    // Symbol|Security Name|Market Category|Test Issue|Financial Status|Lot|ETF|NextShares
    if (cols.length < 8 || cols[0] === 'Symbol' || cols[0].startsWith('File Creation')) continue;
    if (cols[3] === 'Y') continue; // test issue
    out.push([cols[0].trim(), cols[1].trim(), 'Q', cols[6] === 'Y' ? 1 : 0]);
  }
  return out;
}

function parseOtherListed(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const cols = line.split('|');
    // ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Lot|Test Issue|NASDAQ Symbol
    if (cols.length < 8 || cols[0] === 'ACT Symbol' || cols[0].startsWith('File Creation')) continue;
    if (cols[6] === 'Y') continue; // test issue
    const exchange = OTHER_EXCHANGE[cols[2]];
    if (!exchange) continue;
    const symbol = cols[0].trim();
    // ACT '$' notation marks preferred shares (ABR$D). No listed options
    // exist on preferreds and no downstream provider accepts the notation,
    // so carrying them would only produce dead selections.
    if (symbol.includes('$')) continue;
    out.push([symbol, cols[1].trim(), exchange, cols[4] === 'Y' ? 1 : 0]);
  }
  return out;
}

/* ------------------------------------------------------------ CA symbols */

function parseTmxDirectory(json, exchangeCode) {
  const out = [];
  for (const issuer of json.results ?? []) {
    const instruments = issuer.instruments?.length
      ? issuer.instruments
      : [{ symbol: issuer.symbol, name: issuer.name }];
    for (const instrument of instruments) {
      if (!instrument.symbol) continue;
      // The issuer name is the readable one; instrument names are abbreviated.
      out.push([instrument.symbol.trim(), issuer.name.trim(), exchangeCode, 0]);
    }
  }
  return out;
}

/* ---------------------------------------------------------------- yields */

/**
 * Par yields are quoted with semi-annual compounding; the pricing models
 * want continuously compounded rates. r = 2 ln(1 + y/2).
 */
const toContinuous = (percent) => 2 * Math.log(1 + percent / 200);

function parseTreasuryCsv(csv) {
  const [header, latest] = csv.trim().split('\n');
  const names = header.split(',').map((s) => s.replace(/"/g, '').trim());
  const values = latest.split(',').map((s) => s.replace(/"/g, '').trim());
  const row = Object.fromEntries(names.map((name, i) => [name, values[i]]));

  const TENORS = [
    ['1 Mo', 30], ['2 Mo', 61], ['3 Mo', 91], ['4 Mo', 122], ['6 Mo', 182],
    ['1 Yr', 365], ['2 Yr', 730], ['3 Yr', 1096], ['5 Yr', 1826],
    ['7 Yr', 2557], ['10 Yr', 3652], ['20 Yr', 7305], ['30 Yr', 10957],
  ];
  const points = TENORS
    .filter(([name]) => row[name] !== undefined && row[name] !== '')
    .map(([name, days]) => ({ days, rate: toContinuous(Number(row[name])), label: name }));

  const [month, day, year] = row.Date.split('/');
  return { asOf: `${year}-${month}-${day}`, points };
}

async function fetchBankOfCanadaCurve() {
  // Groups mix live and discontinued series, so take each series' most
  // recent non-null observation rather than trusting the last row.
  const groups = await Promise.all([
    fetchJson('https://www.bankofcanada.ca/valet/observations/group/tbill_all/json?recent=30'),
    fetchJson('https://www.bankofcanada.ca/valet/observations/group/bond_yields_benchmark/json?recent=30'),
  ]);

  const WANTED = [
    { match: /^V80691342$/, days: 30, label: '1 month' },
    { match: /^V80691344$/, days: 91, label: '3 month' },
    { match: /^V80691345$/, days: 182, label: '6 month' },
    { match: /^V80691346$/, days: 365, label: '1 year' },
    { match: /^BD\.CDN\.2YR/, days: 730, label: '2 year' },
    { match: /^BD\.CDN\.3YR/, days: 1096, label: '3 year' },
    { match: /^BD\.CDN\.5YR/, days: 1826, label: '5 year' },
    { match: /^BD\.CDN\.7YR/, days: 2557, label: '7 year' },
    { match: /^BD\.CDN\.10YR/, days: 3652, label: '10 year' },
    { match: /^BD\.CDN\.LONG/, days: 10957, label: 'long' },
  ];

  const points = [];
  let newest = '';
  for (const spec of WANTED) {
    let best = null;
    for (const group of groups) {
      for (const series of Object.keys(group.seriesDetail ?? {})) {
        if (!spec.match.test(series)) continue;
        for (const observation of group.observations) {
          const value = observation[series]?.v;
          if (value === undefined || value === null || value === '') continue;
          if (!best || observation.d > best.date) best = { date: observation.d, value: Number(value) };
        }
      }
    }
    if (best) {
      points.push({ days: spec.days, rate: toContinuous(best.value), label: spec.label });
      if (best.date > newest) newest = best.date;
    }
  }
  return { asOf: newest, points: points.sort((a, b) => a.days - b.days) };
}

/* ------------------------------------------------------------------ main */

await mkdir('data', { recursive: true });
const today = new Date().toISOString().slice(0, 10);

console.log('fetching US symbol directory (Nasdaq Trader)…');
const nasdaq = parseNasdaqListed(
  await fetchText('https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt'));
const other = parseOtherListed(
  await fetchText('https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt'));

console.log('fetching Canadian directory (TMX)…');
const tsx = parseTmxDirectory(
  await fetchJson('https://www.tsx.com/json/company-directory/search/tsx/%5E*',
    { headers: { Accept: 'application/json' } }), 'T');
const tsxv = parseTmxDirectory(
  await fetchJson('https://www.tsx.com/json/company-directory/search/tsxv/%5E*',
    { headers: { Accept: 'application/json' } }), 'X');

// Dedupe on symbol+exchange, keeping the first (directories can overlap).
const seen = new Set();
const tickers = [...nasdaq, ...other, ...tsx, ...tsxv].filter(([symbol, , exchange]) => {
  const key = `${symbol}|${exchange}`;
  if (seen.has(key)) return false;
  seen.add(key);
  return true;
});

await writeFile('data/tickers.json', JSON.stringify({
  asOf: today,
  sources: {
    us: 'Nasdaq Trader symbol directory (nasdaqlisted.txt, otherlisted.txt)',
    ca: 'TMX Group company directory (tsx.com)',
  },
  // [symbol, name, exchange, isEtf] — exchange: Q NASDAQ, N NYSE,
  // A NYSE American, P NYSE Arca, Z Cboe BZX, V IEX, T TSX, X TSXV.
  tickers,
}));
console.log(`data/tickers.json — ${tickers.length} symbols ` +
  `(US ${nasdaq.length + other.length}, CA ${tsx.length + tsxv.length})`);

console.log('fetching yield curves (US Treasury, Bank of Canada)…');
const year = today.slice(0, 4);
const us = parseTreasuryCsv(await fetchText(
  'https://home.treasury.gov/resource-center/data-chart-center/interest-rates/' +
  `daily-treasury-rates.csv/${year}/all?type=daily_treasury_yield_curve` +
  `&field_tdr_date_value=${year}&page&_format=csv`));
const ca = await fetchBankOfCanadaCurve();

await writeFile('data/rates.json', JSON.stringify({
  fetched: today,
  note: 'Continuously compounded, converted from semi-annual par quotes: r = 2 ln(1 + y/2).',
  us: { ...us, source: 'U.S. Treasury daily par yield curve' },
  ca: { ...ca, source: 'Bank of Canada Valet API (T-bills, benchmark bonds)' },
}, null, 1));
console.log(`data/rates.json — US as of ${us.asOf} (${us.points.length} tenors), ` +
  `CA as of ${ca.asOf} (${ca.points.length} tenors)`);
