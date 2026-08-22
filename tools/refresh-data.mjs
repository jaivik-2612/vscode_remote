/**
 * Refreshes the bundled market reference data across all supported markets.
 *
 * Every source is the exchange's (or central bank's) own publication:
 *
 *   US       Nasdaq Trader symbol directory
 *   Canada   TMX Group company directory
 *   London   LSE Instrument list (current link discovered via LSE's own API)
 *   Euronext live.euronext.com full equity list (Paris, Amsterdam, Brussels,
 *            Lisbon, Dublin, Milan, Oslo and their growth/access segments)
 *   Germany  Deutsche Börse T7/XETRA all-tradable-instruments file
 *   Switz.   SIX Swiss Exchange FQS reference-data API
 *   Japan    JPX official listed-issues file (English)
 *   China    SSE commonQuery API + SZSE ShowReport workbook
 *   India    BSE ListofScripData API (NSE's CDN refuses datacenter clients)
 *
 * Yield curves: US Treasury, Bank of Canada, ECB (euro area), Bank of
 * England, Japan MoF, SNB. China and India publish through portals that
 * refuse automation, so those markets carry no curve and the app asks for a
 * manual rate instead.
 *
 * Each market refreshes independently: a failing source logs a warning and
 * keeps the previous snapshot's rows for that market rather than sinking
 * the whole run.
 */

import { writeFile, mkdir, readFile } from 'node:fs/promises';

const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

async function fetchRaw(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    signal: AbortSignal.timeout(options.timeout ?? 60000),
    headers: { 'User-Agent': UA, Accept: 'text/plain,application/json,*/*', ...options.headers },
  });
  if (!response.ok) throw new Error(`${url} -> HTTP ${response.status}`);
  return response;
}

const fetchText = async (url, options) => (await fetchRaw(url, options)).text();
const fetchJson = async (url, options) => JSON.parse(await fetchText(url, options));
const fetchBuffer = async (url, options) => Buffer.from(await (await fetchRaw(url, options)).arrayBuffer());

/** Some exchange hosts drop connections at random; a short retry loop wins. */
async function withRetries(attempt, tries = 5, delayMs = 1500) {
  let lastError;
  for (let i = 0; i < tries; i++) {
    try { return await attempt(); } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  throw lastError;
}

/** Semicolon/CSV cell splitter that respects double quotes. */
function splitDelimited(line, sep) {
  const cells = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      if (quoted && line[i + 1] === '"') { cell += '"'; i++; } else quoted = !quoted;
    } else if (!quoted && ch === sep) { cells.push(cell); cell = ''; }
    else cell += ch;
  }
  cells.push(cell);
  return cells.map((c) => c.trim());
}

let XLSX = null;
async function sheets() {
  if (!XLSX) XLSX = (await import('xlsx')).default ?? (await import('xlsx'));
  return XLSX;
}

/* ======================================================== North America */

const OTHER_EXCHANGE = { N: 'N', A: 'A', P: 'P', Z: 'Z', V: 'V' };

function parseNasdaqListed(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const cols = line.split('|');
    if (cols.length < 8 || cols[0] === 'Symbol' || cols[0].startsWith('File Creation')) continue;
    if (cols[3] === 'Y') continue;
    out.push([cols[0].trim(), cols[1].trim(), 'Q', cols[6] === 'Y' ? 1 : 0]);
  }
  return out;
}

function parseOtherListed(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const cols = line.split('|');
    if (cols.length < 8 || cols[0] === 'ACT Symbol' || cols[0].startsWith('File Creation')) continue;
    if (cols[6] === 'Y') continue;
    const exchange = OTHER_EXCHANGE[cols[2]];
    if (!exchange) continue;
    const symbol = cols[0].trim();
    if (symbol.includes('$')) continue; // preferred-share notation nothing accepts
    out.push([symbol, cols[1].trim(), exchange, cols[4] === 'Y' ? 1 : 0]);
  }
  return out;
}

async function fetchUnitedStates() {
  return [
    ...parseNasdaqListed(await fetchText('https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt')),
    ...parseOtherListed(await fetchText('https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt')),
  ];
}

function parseTmxDirectory(json, exchangeCode) {
  const out = [];
  for (const issuer of json.results ?? []) {
    const instruments = issuer.instruments?.length
      ? issuer.instruments : [{ symbol: issuer.symbol, name: issuer.name }];
    for (const instrument of instruments) {
      if (instrument.symbol) out.push([instrument.symbol.trim(), issuer.name.trim(), exchangeCode, 0]);
    }
  }
  return out;
}

async function fetchCanada() {
  const headers = { Accept: 'application/json' };
  return [
    ...parseTmxDirectory(await fetchJson('https://www.tsx.com/json/company-directory/search/tsx/%5E*', { headers }), 'T'),
    ...parseTmxDirectory(await fetchJson('https://www.tsx.com/json/company-directory/search/tsxv/%5E*', { headers }), 'X'),
  ];
}

/* ================================================================ London */

async function discoverLseWorkbookUrl() {
  try {
    const payload = await fetchJson('https://api.londonstockexchange.com/api/v1/components/refresh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        path: 'reports',
        components: [{
          componentId: 'block_content:4302c1be-76b4-4225-9bdd-bbc442bccafb',
          parameters: 'tabId=c661930a-66e7-41a7-993c-7b3b50d9754d',
        }],
      }),
    });
    const items = payload?.[0]?.content?.[0]?.value?.ctaItems ?? [];
    const hit = items.find((i) => /instrument list/i.test(i.ctaTitle ?? ''));
    if (hit?.ctaButton?.link) return hit.ctaButton.link;
  } catch { /* fall through to probing */ }
  // The suffix increments roughly monthly; probe upward from the last known.
  for (let n = 95; n >= 78; n--) {
    const url = `https://docs.londonstockexchange.com/sites/default/files/reports/Instrument%20list_${n}.xlsx`;
    try {
      const head = await fetchRaw(url, { method: 'HEAD', timeout: 15000 });
      if (head.ok) return url;
    } catch { /* keep probing */ }
  }
  throw new Error('could not locate the current LSE instrument list');
}

async function fetchLondon() {
  const xlsx = await sheets();
  const url = await discoverLseWorkbookUrl();
  const workbook = xlsx.read(await fetchBuffer(url, { timeout: 120000 }), { type: 'buffer' });
  const sheetName = workbook.SheetNames.find((n) => /1\.1/.test(n) && /share/i.test(n));
  if (!sheetName) throw new Error(`no Shares sheet in ${workbook.SheetNames.join(',')}`);
  const rows = xlsx.utils.sheet_to_json(workbook.Sheets[sheetName], { header: 1, raw: false });

  const headerAt = rows.findIndex((r) => String(r?.[0] ?? '').trim() === 'TIDM');
  if (headerAt === -1) throw new Error('LSE header row not found');
  const header = rows[headerAt].map((h) => String(h ?? '').trim());
  const col = (name) => header.findIndex((h) => h.toLowerCase() === name.toLowerCase());
  const iTidm = col('TIDM');
  const iName = col('Issuer Name');

  const out = [];
  for (let i = headerAt + 1; i < rows.length; i++) {
    const tidm = String(rows[i]?.[iTidm] ?? '').trim();
    if (!tidm) break;
    out.push([tidm, String(rows[i][iName] ?? '').trim(), 'LN', 0]);
  }
  return out;
}

/* ============================================================== Euronext */

const EURONEXT_MICS = 'ALXB,ALXL,ALXP,BGEM,ENXB,ENXL,ETLX,EXGM,MERK,MIVX,MLXB,MTAA,MTAH,TNLA,TNLB,XAMC,XAMS,XATL,XBRU,XESM,XLDN,XLIS,XMLI,XMSM,XOAS,XOSL,XPAR,XPMC';

function euronextExchange(marketNames) {
  const first = marketNames.split(',')[0].trim(); // reference market of dual listings
  if (/paris/i.test(first)) return 'PA';
  if (/amsterdam/i.test(first)) return 'AS';
  if (/brussels/i.test(first)) return 'BR';
  if (/lisbon/i.test(first)) return 'LI';
  if (/dublin/i.test(first)) return 'IR';
  if (/milan|italiana/i.test(first)) return 'MI';
  if (/oslo|expand|merkur/i.test(first)) return 'OL';
  return null;
}

async function fetchEuronext() {
  const csv = await fetchText(
    `https://live.euronext.com/product_directory/data/stocks-all-places/download?mics=${encodeURIComponent(EURONEXT_MICS)}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'format=csv&layout=vertical&decimal_separator=.&date_format=d/m/Y',
      timeout: 90000,
    });
  const lines = csv.replace(/^﻿/, '').split(/\r?\n/);
  const out = [];
  let unmapped = 0;
  // line 0 header, lines 1-3 metadata, data from line 4
  for (let i = 4; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const cells = splitDelimited(lines[i], ';');
    const [name, , symbol, marketNames] = cells;
    if (!symbol || !name) continue;
    const exchange = euronextExchange(marketNames ?? '');
    if (!exchange) { unmapped++; continue; }
    out.push([symbol, name, exchange, 0]);
  }
  if (unmapped) console.log(`  euronext: ${unmapped} rows on unmapped venues skipped`);
  return out;
}

/* ========================================================= XETRA and SIX */

async function fetchXetra() {
  const csv = await fetchText(
    'https://www.cashmarket.deutsche-boerse.com/resource/blob/1528/x/data/t7-xetr-allTradableInstruments.csv',
    { timeout: 120000 });
  const lines = csv.split(/\r?\n/);
  const headerAt = lines.findIndex((l) => l.startsWith('Instrument Type;') || l.includes(';Instrument Type;'));
  if (headerAt === -1) throw new Error('XETRA header not found');
  const header = splitDelimited(lines[headerAt], ';');
  const iType = header.indexOf('Instrument Type');
  const iName = header.indexOf('Instrument');
  const iMnemonic = header.indexOf('Mnemonic');

  const out = [];
  for (let i = headerAt + 1; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const cells = splitDelimited(lines[i], ';');
    if (cells[iType] !== 'CS') continue; // common stock only
    const symbol = cells[iMnemonic];
    if (!symbol) continue;
    out.push([symbol, cells[iName], 'DE', 0]);
  }
  return out;
}

async function fetchSwitzerland() {
  const csv = await withRetries(() => fetchText(
    'https://www.six-group.com/fqs/ref.csv?select=ISIN,ValorSymbol,ShortName,Currency,SecTypeCode,ProductLine&where=PortalSegment=EQ&pagesize=9999',
    { timeout: 45000 }));
  const lines = csv.split(/\r?\n/);
  const header = splitDelimited(lines[0], ';');
  const iSymbol = header.indexOf('ValorSymbol');
  const iName = header.indexOf('ShortName');
  const iLine = header.indexOf('ProductLine');
  const iType = header.indexOf('SecTypeCode');

  const out = [];
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const cells = splitDelimited(lines[i], ';');
    // BC blue chips, DS domestic shares, FS foreign listings; skip the 550+
    // sponsored cross-trading lines and subscription rights.
    if (!['BC', 'DS', 'FS'].includes(cells[iLine])) continue;
    if (cells[iType] === 'RI') continue;
    if (!cells[iSymbol]) continue;
    out.push([cells[iSymbol], cells[iName], 'SW', 0]);
  }
  return out;
}

/* ================================================================= Japan */

async function fetchJapan() {
  const xlsx = await sheets();
  const workbook = xlsx.read(await fetchBuffer(
    'https://www.jpx.co.jp/english/markets/statistics-equities/misc/tvdivq0000001vg2-att/data_e.xls',
    { timeout: 120000 }), { type: 'buffer' });
  const rows = xlsx.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]], { header: 1, raw: false });

  const out = [];
  for (let i = 1; i < rows.length; i++) {
    const code = String(rows[i]?.[1] ?? '').trim();
    const name = String(rows[i]?.[2] ?? '').trim();
    const segment = String(rows[i]?.[3] ?? '').trim();
    if (!code || !name) continue;
    if (/pro market/i.test(segment)) continue; // professionals-only venue
    const isEtf = /etf|etn/i.test(segment) ? 1 : 0;
    if (!isEtf && !/prime|standard|growth/i.test(segment)) continue;
    out.push([code, name, 'JP', isEtf]);
  }
  return out;
}

/* ================================================================= China */

async function fetchShanghai() {
  const base = 'https://query.sse.com.cn/sseQuery/commonQuery.do?REG_PROVINCE=&CSRC_CODE=&STOCK_CODE=' +
    '&sqlId=COMMON_SSE_CP_GPJCTPZ_GPLB_GP_L&COMPANY_STATUS=2,4,5,7,8&type=inParams&isPagination=true' +
    '&pageHelp.cacheSize=1&pageHelp.beginPage=1&pageHelp.pageSize=10000&pageHelp.pageNo=1&STOCK_TYPE=';
  const headers = { Referer: 'http://www.sse.com.cn/' };
  const out = [];
  for (const stockType of ['1', '8']) { // main board A + STAR market
    const payload = await withRetries(() => fetchJson(base + stockType, { headers, timeout: 60000 }));
    for (const row of payload?.pageHelp?.data ?? []) {
      const symbol = String(row.A_STOCK_CODE ?? row.COMPANY_CODE ?? '').trim();
      if (!symbol) continue;
      const english = String(row.COMPANY_ABBR_EN ?? '').trim();
      const englishFull = String(row.FULL_NAME_IN_ENGLISH ?? '').trim();
      const chinese = String(row.COMPANY_ABBR ?? '').trim();
      const name = (english && english !== '-') ? english
        : (englishFull && englishFull !== '-') ? englishFull : chinese;
      out.push([symbol, name, 'SS', 0]);
    }
  }
  if (out.length < 1000) throw new Error(`suspiciously few SSE rows: ${out.length}`);
  return out;
}

async function fetchShenzhen() {
  const xlsx = await sheets();
  const buffer = await withRetries(() => fetchBuffer(
    'https://www.szse.cn/api/report/ShowReport?SHOWTYPE=xlsx&CATALOGID=1110&TABKEY=tab1&random=0.42',
    { timeout: 120000 }), 8, 2000);
  const workbook = xlsx.read(buffer, { type: 'buffer' });
  const rows = xlsx.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]], { header: 1, raw: false });

  const header = rows[0].map((h) => String(h ?? '').trim());
  const iSymbol = header.findIndex((h) => h === 'A股代码');
  const iCn = header.findIndex((h) => h === 'A股简称');
  const iEn = header.findIndex((h) => h === '英文名称');
  if (iSymbol === -1) throw new Error(`SZSE header changed: ${header.slice(0, 8).join('|')}`);

  const out = [];
  for (let i = 1; i < rows.length; i++) {
    const symbol = String(rows[i]?.[iSymbol] ?? '').trim();
    if (!/^\d{6}$/.test(symbol)) continue;
    const english = String(rows[i]?.[iEn] ?? '').trim();
    const chinese = String(rows[i]?.[iCn] ?? '').trim();
    out.push([symbol, english || chinese, 'SZ', 0]);
  }
  return out;
}

/* ================================================================= India */

async function fetchIndia() {
  // NSE's CDN refuses datacenter clients outright, so the directory comes
  // from BSE's own API. GOOGLEFINANCE addresses BSE numerically (BOM:500002)
  // while people search the alpha id, so rows carry the numeric twin as aux.
  const rows = await fetchJson(
    'https://api.bseindia.com/BseIndiaAPI/api/ListofScripData/w?Group=&Scripcode=&industry=&segment=Equity&status=Active',
    { headers: { Referer: 'https://www.bseindia.com/' }, timeout: 90000 });
  const out = [];
  for (const row of rows ?? []) {
    const symbol = String(row.scrip_id ?? '').trim();
    const code = String(row.SCRIP_CD ?? '').trim();
    if (!symbol || !code || row.Status !== 'Active') continue;
    const name = String(row.Issuer_Name ?? row.Scrip_Name ?? '').trim();
    out.push([symbol, name, 'BO', 0, code]);
  }
  if (out.length < 1000) throw new Error(`suspiciously few BSE rows: ${out.length}`);
  return out;
}

/* ================================================================ curves */

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
    .filter(([name]) => row[name])
    .map(([name, days]) => ({ days, rate: toContinuous(Number(row[name])), label: name }));
  const [month, day, year] = row.Date.split('/');
  return { asOf: `${year}-${month}-${day}`, points };
}

async function fetchUnitedStatesCurve() {
  const year = new Date().getFullYear();
  return {
    ...parseTreasuryCsv(await fetchText(
      'https://home.treasury.gov/resource-center/data-chart-center/interest-rates/' +
      `daily-treasury-rates.csv/${year}/all?type=daily_treasury_yield_curve` +
      `&field_tdr_date_value=${year}&page&_format=csv`)),
    source: 'U.S. Treasury daily par yield curve',
  };
}

async function fetchCanadaCurve() {
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
  return { asOf: newest, points: points.sort((a, b) => a.days - b.days),
    source: 'Bank of Canada Valet API (T-bills, benchmark bonds)' };
}

async function fetchEuroCurve() {
  const TENORS = { '3M': 91, '6M': 182, '1Y': 365, '2Y': 730, '3Y': 1096,
    '5Y': 1826, '7Y': 2557, '10Y': 3652, '20Y': 7305, '30Y': 10957 };
  const key = Object.keys(TENORS).map((t) => `SR_${t}`).join('+');
  const csv = await fetchText(
    `https://data-api.ecb.europa.eu/service/data/YC/B.U2.EUR.4F.G_N_A.SV_C_YM.${key}` +
    '?lastNObservations=1&format=csvdata');
  const points = [];
  let asOf = '';
  for (const line of csv.split('\n').slice(1)) {
    const cells = line.split(',');
    const tenor = cells[0]?.match(/SR_(\w+)$/)?.[1];
    const dateAt = cells.findIndex((c) => /^\d{4}-\d{2}-\d{2}$/.test(c));
    if (!tenor || dateAt === -1 || !(tenor in TENORS)) continue;
    const value = Number(cells[dateAt + 1]);
    if (!Number.isFinite(value)) continue;
    points.push({ days: TENORS[tenor], rate: toContinuous(value), label: tenor });
    if (cells[dateAt] > asOf) asOf = cells[dateAt];
  }
  if (points.length < 5) throw new Error(`ECB curve too sparse: ${points.length}`);
  return { asOf, points: points.sort((a, b) => a.days - b.days),
    source: 'ECB euro-area AAA government yield curve' };
}

async function fetchUnitedKingdomCurve() {
  const from = new Date(Date.now() - 60 * 86400000);
  const fmt = `${String(from.getDate()).padStart(2, '0')}/${from.toLocaleString('en-GB', { month: 'short' })}/${from.getFullYear()}`;
  const csv = await fetchText(
    'https://www.bankofengland.co.uk/boeapps/database/_iadb-fromshowcolumns.asp' +
    `?csv.x=yes&Datefrom=${encodeURIComponent(fmt)}&Dateto=now` +
    '&SeriesCodes=IUDBEDR,IUDSNZC,IUDMNZC,IUDLNZC&CSVF=TN&UsingCodes=Y&VPD=Y');
  const lines = csv.trim().split('\n');
  const header = lines[0].split(',').map((s) => s.trim());
  const SERIES = { IUDBEDR: [7, 'Bank Rate'], IUDSNZC: [1826, '5 year gilt'],
    IUDMNZC: [3652, '10 year gilt'], IUDLNZC: [7305, '20 year gilt'] };
  const latest = {};
  let asOf = '';
  for (const line of lines.slice(1)) {
    const cells = line.split(',');
    for (let i = 1; i < header.length; i++) {
      const value = Number(cells[i]);
      if (Number.isFinite(value) && cells[i] !== '') latest[header[i]] = value;
    }
    if (cells[0]) asOf = cells[0];
  }
  const points = Object.entries(SERIES)
    .filter(([code]) => latest[code] !== undefined)
    .map(([code, [days, label]]) => ({ days, rate: toContinuous(latest[code]), label }))
    .sort((a, b) => a.days - b.days);
  if (points.length < 3) throw new Error('BoE curve too sparse');
  const parsed = new Date(asOf);
  return { asOf: Number.isNaN(parsed.getTime()) ? asOf : parsed.toISOString().slice(0, 10),
    points, source: 'Bank of England (Bank Rate, benchmark gilts)' };
}

async function fetchJapanCurve() {
  const csv = await fetchText(
    'https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/jgbcme.csv');
  const lines = csv.split(/\r?\n/);
  const headerAt = lines.findIndex((l) => l.startsWith('Date,'));
  const header = lines[headerAt].split(',').map((s) => s.trim());
  const dataRows = lines.slice(headerAt + 1).filter((l) => /^\d{4}\//.test(l));
  const last = dataRows[dataRows.length - 1].split(',');
  const points = [];
  for (let i = 1; i < header.length; i++) {
    const years = Number(header[i].replace(/Y$/, ''));
    const value = Number(last[i]);
    if (!Number.isFinite(years) || !Number.isFinite(value)) continue;
    points.push({ days: Math.round(years * 365.25), rate: toContinuous(value), label: header[i] });
  }
  if (points.length < 5) throw new Error('JGB curve too sparse');
  const [y, m, d] = last[0].split('/');
  return { asOf: `${y}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`,
    points: points.sort((a, b) => a.days - b.days),
    source: 'Japan Ministry of Finance JGB yields' };
}

async function fetchSwissCurve() {
  const csv = await fetchText('https://data.snb.ch/api/cube/rendoblim/data/csv/en', { timeout: 90000 });
  const rows = csv.split(/\r?\n/)
    .map((l) => splitDelimited(l, ';'))
    .filter((c) => c.length === 3 && /^\d{4}-\d{2}$/.test(c[0].replace(/"/g, '')));
  const clean = rows.map(([d, t, v]) => [d.replace(/"/g, ''), t.replace(/"/g, ''), v.replace(/"/g, '')]);
  const asOf = clean.reduce((max, [d]) => (d > max ? d : max), '');
  const points = [];
  for (const [date, tenor, value] of clean) {
    if (date !== asOf) continue;
    const years = Number(tenor.replace(/J$/, ''));
    const rate = Number(value);
    if (!Number.isFinite(years) || !Number.isFinite(rate)) continue;
    points.push({ days: Math.round(years * 365.25), rate: toContinuous(rate), label: `${years} year` });
  }
  if (points.length < 5) throw new Error('SNB curve too sparse');
  return { asOf, points: points.sort((a, b) => a.days - b.days),
    source: 'Swiss National Bank Confederation bond spot rates' };
}

/* ================================================================== main */

await mkdir('data', { recursive: true });
const today = new Date().toISOString().slice(0, 10);

let previous = { tickers: [] };
try { previous = JSON.parse(await readFile('data/tickers.json', 'utf8')); } catch { /* first run */ }

const DIRECTORY_JOBS = [
  { label: 'United States (Nasdaq Trader)', codes: ['Q', 'N', 'A', 'P', 'Z', 'V'], run: fetchUnitedStates },
  { label: 'Canada (TMX)', codes: ['T', 'X'], run: fetchCanada },
  { label: 'London (LSE)', codes: ['LN'], run: fetchLondon },
  { label: 'Euronext', codes: ['PA', 'AS', 'BR', 'LI', 'IR', 'MI', 'OL'], run: fetchEuronext },
  { label: 'Germany (XETRA)', codes: ['DE'], run: fetchXetra },
  { label: 'Switzerland (SIX)', codes: ['SW'], run: fetchSwitzerland },
  { label: 'Japan (JPX)', codes: ['JP'], run: fetchJapan },
  { label: 'Shanghai (SSE)', codes: ['SS'], run: fetchShanghai },
  { label: 'Shenzhen (SZSE)', codes: ['SZ'], run: fetchShenzhen },
  { label: 'India (BSE)', codes: ['BO'], run: fetchIndia },
];

const buckets = new Map();
for (const row of previous.tickers ?? []) {
  const list = buckets.get(row[2]) ?? [];
  list.push(row);
  buckets.set(row[2], list);
}

const settled = await Promise.allSettled(DIRECTORY_JOBS.map((job) => job.run()));
settled.forEach((result, index) => {
  const job = DIRECTORY_JOBS[index];
  if (result.status === 'fulfilled') {
    for (const code of job.codes) buckets.set(code, []);
    for (const row of result.value) {
      const list = buckets.get(row[2]) ?? [];
      list.push(row);
      buckets.set(row[2], list);
    }
    console.log(`ok    ${job.label}: ${result.value.length} rows`);
  } else {
    const kept = job.codes.reduce((n, c) => n + (buckets.get(c)?.length ?? 0), 0);
    console.log(`WARN  ${job.label} failed (${result.reason?.message ?? result.reason}); kept ${kept} previous rows`);
  }
});

const seen = new Set();
const tickers = [...buckets.values()].flat().filter((row) => {
  const key = `${row[0]}|${row[2]}`;
  if (seen.has(key)) return false;
  seen.add(key);
  return true;
});

await writeFile('data/tickers.json', JSON.stringify({
  asOf: today,
  sources: {
    us: 'Nasdaq Trader symbol directory', ca: 'TMX Group company directory',
    gb: 'LSE Instrument list', eun: 'Euronext equity list (live.euronext.com)',
    de: 'Deutsche Börse T7/XETRA tradable instruments', ch: 'SIX Swiss Exchange FQS',
    jp: 'JPX listed issues (English)', cn: 'SSE commonQuery + SZSE ShowReport',
    in: 'BSE ListofScripData',
  },
  // rows: [symbol, name, exchangeCode, isEtf, aux?] — aux carries e.g. the
  // BSE numeric scrip code that Google Finance addresses (BOM:500002).
  tickers,
}));
console.log(`data/tickers.json — ${tickers.length} symbols total`);

const CURVE_JOBS = [
  ['us', fetchUnitedStatesCurve], ['ca', fetchCanadaCurve], ['eu', fetchEuroCurve],
  ['gb', fetchUnitedKingdomCurve], ['jp', fetchJapanCurve], ['ch', fetchSwissCurve],
];

let previousRates = {};
try { previousRates = JSON.parse(await readFile('data/rates.json', 'utf8')); } catch { /* first run */ }

const rates = {
  fetched: today,
  note: 'Continuously compounded, converted from quoted yields: r = 2 ln(1 + y/2).',
  cn: { asOf: null, points: [], source: 'No automatable official source (ChinaBond refuses non-browser clients) — the app asks for a manual rate.' },
  in: { asOf: null, points: [], source: 'No automatable official source (FBIL/NSE refuse datacenter clients) — the app asks for a manual rate.' },
};
for (const [key, run] of CURVE_JOBS) {
  try {
    rates[key] = await run();
    console.log(`ok    curve ${key}: ${rates[key].points.length} tenors, as of ${rates[key].asOf}`);
  } catch (error) {
    if (previousRates[key]?.points?.length) {
      rates[key] = previousRates[key];
      console.log(`WARN  curve ${key} failed (${error.message}); kept previous as of ${rates[key].asOf}`);
    } else {
      rates[key] = { asOf: null, points: [], source: `fetch failed: ${error.message}` };
      console.log(`WARN  curve ${key} failed (${error.message}); no previous data`);
    }
  }
}
await writeFile('data/rates.json', JSON.stringify(rates, null, 1));
console.log('data/rates.json written');
