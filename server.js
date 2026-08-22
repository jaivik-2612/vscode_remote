/**
 * Server for the web UI: static files plus a small market-data proxy.
 *
 * The static side exists because ES module imports are blocked on file://.
 * The proxy side exists because the browser cannot call the data providers
 * directly — none of them send CORS headers — while a server-side fetch has
 * no such constraint. The proxy returns each provider's raw response body
 * untouched; the client parses it with the same parser that handles pasted
 * files, so there is exactly one parsing path to test.
 *
 * Providers, all official or first-party:
 *   US history  Nasdaq's historical quote API (Yahoo Finance chart as fallback)
 *   CA history  TMX Group's GraphQL time series (Yahoo Finance as fallback)
 *   Yield curves are served from data/rates.json (refresh with
 *   `npm run refresh-data`).
 *
 * No dependencies, so `npm start` works on a fresh clone.
 */

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('.', import.meta.url));
const PORT = Number(process.env.PORT) || 8080;
const HOST = process.env.HOST || '127.0.0.1';

const BROWSER_UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/126.0 Safari/537.36';

/* ------------------------------------------------------- market-data proxy */

/** Ten-minute response cache so scrubbing through tickers stays gentle on the providers. */
const cache = new Map();
const CACHE_TTL = 10 * 60 * 1000;
const CACHE_MAX = 200;

function cacheGet(key) {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > CACHE_TTL) { cache.delete(key); return null; }
  return hit.value;
}

function cachePut(key, value) {
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(key, { at: Date.now(), value });
}

async function fetchUpstream(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    signal: AbortSignal.timeout(15000),
    headers: {
      'User-Agent': BROWSER_UA,
      Accept: 'application/json,text/plain,*/*',
      ...options.headers,
    },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.text();
}

const isoDaysAgo = (days) => new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);

/** US daily history from Nasdaq's own API. Raw closes — the client repairs splits. */
function fetchNasdaqHistory(symbol) {
  const url = 'https://api.nasdaq.com/api/quote/' + encodeURIComponent(symbol) +
    `/historical?assetclass=stocks&fromdate=${isoDaysAgo(730)}&todate=${isoDaysAgo(0)}&limit=9999`;
  return fetchUpstream(url).then((body) => {
    const rows = JSON.parse(body)?.data?.tradesTable?.rows;
    if (!rows?.length) throw new Error('no rows');
    return { provider: 'Nasdaq', body };
  });
}

/** Canadian daily history straight from TMX. */
function fetchTmxHistory(symbol) {
  const query = 'query getTimeSeriesData($symbol: String!, $freq: String, $interval: Int, ' +
    '$start: String, $end: String) { getTimeSeriesData(symbol: $symbol, freq: $freq, ' +
    'interval: $interval, start: $start, end: $end) { dateTime open high low close volume } }';
  return fetchUpstream('https://app-money.tmx.com/graphql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Locale: 'en' },
    body: JSON.stringify({
      operationName: 'getTimeSeriesData',
      variables: { symbol, freq: 'day', interval: 1, start: isoDaysAgo(730), end: isoDaysAgo(0) },
      query,
    }),
  }).then((body) => {
    const rows = JSON.parse(body)?.data?.getTimeSeriesData;
    if (!rows?.length) throw new Error('no rows');
    return { provider: 'TMX', body };
  });
}

/** Yahoo fallback for either country; adjclose included. */
function fetchYahooHistory(yahooSym) {
  const url = 'https://query1.finance.yahoo.com/v8/finance/chart/' +
    encodeURIComponent(yahooSym) + '?range=2y&interval=1d&events=split%2Cdiv';
  return fetchUpstream(url).then((body) => {
    const result = JSON.parse(body)?.chart?.result?.[0];
    if (!result?.timestamp?.length) throw new Error('no rows');
    return { provider: 'Yahoo Finance', body };
  });
}

async function handleHistory(query, response) {
  const symbol = (query.get('symbol') ?? '').trim().toUpperCase();
  const exchange = (query.get('exchange') ?? 'Q').trim().toUpperCase();
  if (!/^[A-Z0-9.\-]{1,12}$/.test(symbol)) {
    respondJson(response, 400, { ok: false, error: 'bad symbol' });
    return;
  }

  const cacheKey = `${symbol}|${exchange}`;
  const cached = cacheGet(cacheKey);
  if (cached) { respondJson(response, 200, cached); return; }

  const canadian = exchange === 'T' || exchange === 'X';
  const yahooSym = symbol.replace(/\./g, '-') + (exchange === 'T' ? '.TO' : exchange === 'X' ? '.V' : '');
  const attempts = canadian
    ? [() => fetchTmxHistory(symbol), () => fetchYahooHistory(yahooSym)]
    : [() => fetchNasdaqHistory(symbol), () => fetchYahooHistory(yahooSym)];

  const failures = [];
  for (const attempt of attempts) {
    try {
      const { provider, body } = await attempt();
      const payload = { ok: true, provider, body };
      cachePut(cacheKey, payload);
      respondJson(response, 200, payload);
      return;
    } catch (error) {
      failures.push(error.message);
    }
  }
  respondJson(response, 502, {
    ok: false,
    error: `no provider could supply ${symbol}: ${failures.join('; ')}`,
  });
}

function respondJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-cache',
  });
  response.end(body);
}

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.webmanifest': 'application/manifest+json',
};

/**
 * Map a request path to a file inside ROOT, or null if it escapes.
 * Rejecting traversal matters even for a local dev server: it is one
 * `..%2f` away from serving the rest of the disk.
 */
function resolvePath(urlPath) {
  const decoded = decodeURIComponent(urlPath.split('?')[0]);
  const relative = normalize(decoded).replace(/^(\.\.[/\\])+/, '');
  const full = join(ROOT, relative);
  if (full !== ROOT.replace(/[/\\]$/, '') && !full.startsWith(ROOT.endsWith(sep) ? ROOT : ROOT + sep)) {
    return null;
  }
  return full;
}

const server = createServer(async (request, response) => {
  // Redirect rather than rewrite: serving the app's HTML at "/" would leave
  // its relative "./app.js" pointing at the server root, where it is not.
  if (request.url === '/') {
    response.writeHead(302, { location: '/web/' });
    response.end();
    return;
  }

  if (request.url.startsWith('/api/history')) {
    const query = new URL(request.url, 'http://localhost').searchParams;
    try {
      await handleHistory(query, response);
    } catch (error) {
      respondJson(response, 500, { ok: false, error: error.message });
    }
    return;
  }

  const urlPath = request.url.endsWith('/') ? `${request.url}index.html` : request.url;
  const filePath = resolvePath(urlPath);

  if (filePath === null) {
    response.writeHead(403, { 'content-type': 'text/plain' });
    response.end('Forbidden');
    return;
  }

  try {
    const body = await readFile(filePath);
    response.writeHead(200, {
      'content-type': CONTENT_TYPES[extname(filePath)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    response.end(body);
  } catch (error) {
    const status = error.code === 'ENOENT' || error.code === 'EISDIR' ? 404 : 500;
    response.writeHead(status, { 'content-type': 'text/plain' });
    response.end(status === 404 ? 'Not found' : 'Server error');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`FairShare running at http://${HOST}:${PORT}`);
});
