/**
 * UI layer. All the maths lives in ../src; this file reads the controls,
 * calls the engine and renders the readout.
 */

import {
  valuation, valueCurve, employeeGrantValue, yearsFromDays,
  impliedVol, priceBounds, blackScholes as bs, binomial,
  ensembleValuation, series as seriesTools, market,
} from '../src/index.js';

const $ = (id) => document.getElementById(id);

/* ------------------------------------------------------------ formatting */

const money = (n, digits = 2) => n.toLocaleString('en-US', {
  minimumFractionDigits: digits, maximumFractionDigits: digits,
});
const count = (n) => n.toLocaleString('en-US', { maximumFractionDigits: 0 });
const percent = (n, digits = 2) => `${(n * 100).toFixed(digits)}%`;
const signed = (n, digits) => (n >= 0 ? '+' : '−') + Math.abs(n).toFixed(digits);

/** Reads a form into a plain object, coercing anything numeric. */
function readForm(form) {
  const out = {};
  for (const [key, raw] of new FormData(form)) {
    const asNumber = Number(raw);
    out[key] = raw === '' || Number.isNaN(asNumber) ? raw : asNumber;
  }
  return out;
}

function showError(element, message) {
  element.textContent = message;
  element.hidden = false;
}

/** Builds a <dl> of label/value rows, optionally with a closing footnote. */
function renderFacts(container, rows, footnote) {
  const nodes = rows.map(([term, value, quiet]) => {
    const row = document.createElement('div');
    row.className = 'fact';
    const dt = document.createElement('dt');
    dt.textContent = term;
    const dd = document.createElement('dd');
    dd.textContent = value;
    if (quiet) dd.classList.add('is-quiet');
    row.append(dt, dd);
    return row;
  });

  if (footnote) {
    const note = document.createElement('p');
    note.className = 'footnote';
    note.textContent = footnote;
    nodes.push(note);
  }
  container.replaceChildren(...nodes);
}

/* --------------------------------------------------------------- greeks */

const GREEKS = [
  { key: 'delta', glyph: 'Δ', name: 'Delta', digits: 4, showSign: true,
    hint: 'value per $1 of underlying' },
  { key: 'gamma', glyph: 'Γ', name: 'Gamma', digits: 4, showSign: false,
    hint: 'delta per $1 of underlying' },
  { key: 'vega', glyph: 'ν', name: 'Vega', digits: 4, showSign: false,
    hint: 'per 1 point of volatility' },
  { key: 'theta', glyph: 'Θ', name: 'Theta', digits: 4, showSign: true,
    hint: 'per calendar day' },
  { key: 'rho', glyph: 'ρ', name: 'Rho', digits: 4, showSign: true,
    hint: 'per 1% of rates' },
];

function renderGreeks(container, greeks, multiplier) {
  container.replaceChildren(...GREEKS.map(({ key, glyph, name, digits, showSign, hint }) => {
    const value = greeks[key];

    const cell = document.createElement('div');
    cell.className = 'greek';

    const head = document.createElement('div');
    head.className = 'greek-head';
    const mark = document.createElement('span');
    mark.className = 'greek-glyph';
    mark.textContent = glyph;
    mark.setAttribute('aria-hidden', 'true');
    const label = document.createElement('span');
    label.className = 'greek-name';
    label.textContent = name;
    head.append(mark, label);

    const amount = document.createElement('div');
    amount.className = 'greek-value';
    if (showSign) {
      amount.classList.add(value >= 0 ? 'is-positive' : 'is-negative');
      amount.textContent = signed(value, digits);
    } else {
      amount.textContent = value.toFixed(digits);
    }

    const note = document.createElement('div');
    note.className = 'greek-hint';
    note.textContent = multiplier > 1
      ? `${hint} · ${signed(value * multiplier, 2)} per contract`
      : hint;

    cell.append(head, amount, note);
    return cell;
  }));
}

/* ---------------------------------------------------------- price mode */

const priceForm = $('price-form');

function renderPrice() {
  const errorBox = $('price-error');
  errorBox.hidden = true;

  const f = readForm(priceForm);
  const contract = {
    spot: f.spot,
    strike: f.strike,
    time: yearsFromDays(f.days),
    vol: f.vol / 100,
    rate: f.rate / 100,
    yield: f.yield / 100,
    type: f.type,
    style: f.style,
    steps: 400,
  };

  let result;
  try {
    result = valuation(contract);
  } catch (error) {
    showError(errorBox, error.message);
    return;
  }

  const multiplier = f.multiplier > 0 ? f.multiplier : 1;
  $('fair-value').textContent = money(result.fairValue, 4);
  $('per-contract').textContent =
    `${money(result.fairValue * multiplier)} per contract of ${count(multiplier)}`;
  $('intrinsic').textContent = money(result.intrinsic);
  $('time-value').textContent = money(result.timeValue);
  $('break-even').textContent = money(result.breakEven);

  renderGreeks($('greeks'), result.greeks, multiplier);

  const rows = [
    ['Moneyness', `${(result.moneyness * 100).toFixed(1)}% of strike`],
    ['Forward price', money(result.forward)],
    ['Finishes in the money', percent(result.probabilities.itm, 1)],
    ['Touches the strike', percent(result.probabilities.touch, 1)],
  ];

  if (result.style === 'american') {
    rows.push(['Value if European only', money(result.europeanValue, 4)]);
    rows.push(['Early-exercise premium', money(result.earlyExercisePremium, 4)]);
    rows.push(['Exercise becomes optimal', result.earlyExerciseBoundary === null
      ? 'never'
      : `${f.type === 'put' ? 'below' : 'above'} ${money(result.earlyExerciseBoundary)}`]);
    rows.push(['Model', '400-step binomial tree', true]);
  } else {
    rows.push(['Put-call parity residual', result.parityResidual.toExponential(1), true]);
    rows.push(['Model', 'Black-Scholes-Merton', true]);
  }

  renderFacts($('diagnostics'), rows,
    'Both probabilities are risk-neutral: they describe what this price ' +
    'implies, not what the stock is expected to do.');

  renderChart(contract, result);
}

/* ---------------------------------------------------------------- chart */

const SVG_NS = 'http://www.w3.org/2000/svg';

function el(name, attributes = {}) {
  const node = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  return node;
}

function renderChart(contract, result) {
  const width = 620;
  const height = 300;
  const pad = { top: 12, right: 14, bottom: 30, left: 50 };

  // Wide enough to show both wings without flattening the curve.
  const spread = Math.max(contract.spot, contract.strike) * 0.55;
  const centre = (contract.spot + contract.strike) / 2;
  const from = Math.max(centre - spread, contract.spot * 0.02);
  const to = centre + spread;

  const curve = valueCurve(contract, { from, to, points: 90 });
  const maxY = Math.max(...curve.map((p) => Math.max(p.value, p.payoff))) * 1.08 || 1;

  const x = (spot) => pad.left + ((spot - from) / (to - from)) * (width - pad.left - pad.right);
  const y = (value) => height - pad.bottom - (value / maxY) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label':
      `Fair value against underlying price for a ${contract.style} ${contract.type} ` +
      `struck at ${contract.strike}, currently worth ${result.fairValue.toFixed(2)}.`,
  });

  // Faint horizontal grid, labelled on the left.
  const ticks = 4;
  for (let i = 0; i <= ticks; i++) {
    const value = (maxY * i) / ticks;
    const yy = y(value);
    svg.append(el('line', {
      x1: pad.left, x2: width - pad.right, y1: yy, y2: yy,
      stroke: 'var(--line)', 'stroke-width': 1,
    }));
    const text = el('text', {
      x: pad.left - 9, y: yy + 4, 'text-anchor': 'end',
      fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
    });
    text.textContent = value.toFixed(maxY < 5 ? 2 : 0);
    svg.append(text);
  }

  for (let i = 0; i <= 4; i++) {
    const spot = from + ((to - from) * i) / 4;
    const text = el('text', {
      x: x(spot), y: height - pad.bottom + 18, 'text-anchor': 'middle',
      fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
    });
    text.textContent = spot.toFixed(0);
    svg.append(text);
  }

  const points = (accessor) => curve
    .map((p, i) => `${i === 0 ? 'M' : 'L'}${x(p.spot).toFixed(2)},${y(accessor(p)).toFixed(2)}`)
    .join(' ');

  // Wash under the value curve, to weight it against the payoff line.
  const baseline = y(0).toFixed(2);
  svg.append(el('path', {
    d: `${points((p) => p.value)} L${x(curve[curve.length - 1].spot).toFixed(2)},${baseline} ` +
       `L${x(curve[0].spot).toFixed(2)},${baseline} Z`,
    fill: 'var(--accent-wash)', stroke: 'none',
  }));

  svg.append(el('path', {
    d: points((p) => p.payoff), fill: 'none',
    stroke: 'var(--line-strong)', 'stroke-width': 1.75, 'stroke-dasharray': '5 4',
  }));
  svg.append(el('path', {
    d: points((p) => p.value), fill: 'none',
    stroke: 'var(--accent)', 'stroke-width': 2.25,
    'stroke-linejoin': 'round', 'stroke-linecap': 'round',
  }));

  // Where the underlying is trading now, and what the option is worth there.
  svg.append(el('line', {
    x1: x(contract.spot), x2: x(contract.spot), y1: pad.top, y2: height - pad.bottom,
    stroke: 'var(--ink-muted)', 'stroke-width': 1, 'stroke-dasharray': '3 3',
  }));
  svg.append(el('circle', {
    cx: x(contract.spot), cy: y(result.fairValue), r: 4.5,
    fill: 'var(--accent)', stroke: 'var(--surface)', 'stroke-width': 2.5,
  }));

  $('chart').replaceChildren(svg);
}

/* --------------------------------------------------------- implied vol */

const impliedForm = $('implied-form');

function renderImplied() {
  const errorBox = $('implied-error');
  errorBox.hidden = true;

  const f = readForm(impliedForm);
  const american = f.style === 'american';
  const inputs = {
    spot: f.spot,
    strike: f.strike,
    time: yearsFromDays(f.days),
    rate: f.rate / 100,
    yield: f.yield / 100,
    type: f.type,
    steps: 200,
  };

  try {
    const bounds = priceBounds({ ...inputs, american });
    $('iv-floor').textContent = money(bounds.lower, 4);
    $('iv-ceiling').textContent = money(bounds.upper, 4);
  } catch {
    // The solver below reports the same problem with a clearer message.
  }

  let solved;
  try {
    solved = impliedVol({ ...inputs, price: f.price, american });
  } catch (error) {
    $('implied-vol').textContent = '—';
    $('implied-note').textContent = '—';
    $('iv-iterations').textContent = '—';
    $('implied-greeks').replaceChildren();
    showError(errorBox, error.message);
    return;
  }

  $('iv-iterations').textContent = String(solved.iterations);

  if (solved.identifiable === false) {
    $('implied-vol').textContent = 'n/a';
    $('implied-note').textContent = american
      ? 'quoted at intrinsic — every volatility below the exercise boundary gives this price'
      : 'this price does not move with volatility, so none can be implied';
    $('implied-greeks').replaceChildren();
    return;
  }

  $('implied-vol').textContent = percent(solved.vol, 2);
  $('implied-note').textContent =
    `reprices to ${money(solved.priceAtVol, 4)} against a quote of ${money(f.price, 4)}`;

  const withVol = { ...inputs, vol: solved.vol };
  renderGreeks(
    $('implied-greeks'),
    american ? binomial.greeks({ ...withVol, american: true }) : bs.greeks(withVol),
    1,
  );
}

/* --------------------------------------------------------------- grant */

const grantForm = $('grant-form');

function renderGrant() {
  const errorBox = $('grant-error');
  errorBox.hidden = true;

  const f = readForm(grantForm);
  let result;
  try {
    result = employeeGrantValue({
      spot: f.spot,
      strike: f.strike,
      expectedTerm: f.expectedTerm,
      vol: f.vol / 100,
      rate: f.rate / 100,
      yield: f.yield / 100,
      quantity: f.quantity,
      forfeitureRate: f.forfeitureRate / 100,
      vestingYears: f.vestingYears,
    });
  } catch (error) {
    showError(errorBox, error.message);
    return;
  }

  $('grant-per-option').textContent = money(result.perOption, 4);
  $('grant-gross').textContent =
    `${money(result.grossValue)} across ${count(result.quantity)} options, before forfeiture`;
  $('grant-vesting').textContent = count(result.expectedToVest);
  $('grant-expense').textContent = money(result.expectedExpense);
  $('grant-annual').textContent =
    result.annualExpense === null ? 'n/a' : money(result.annualExpense);

  const moneyness = f.strike > f.spot ? 'out of the money'
    : f.strike < f.spot ? 'in the money' : 'at the money';

  renderFacts($('grant-facts'), [
    ['Granted', `${count(f.quantity)} options, ${moneyness}`],
    ['Valued over', `${f.expectedTerm} years (expected term)`],
    ['Survives to vest', `${percent(result.retention, 1)} after ${f.vestingYears} years`],
    ['Expected to be forfeited', count(result.quantity - result.expectedToVest)],
    ['Value per option', money(result.perOption, 4)],
    ['Recognised over', `${f.vestingYears} years, straight line`, true],
  ], 'Straight-line recognition assumes a single vesting tranche. Graded ' +
     'vesting is expensed tranche by tranche and runs a little higher early on.');
}


/* ------------------------------------------------- market reference data */

/**
 * The artifact build embeds the ticker directory and yield curves before
 * this script runs; the dev build fetches them from the static server. The
 * presence of the embedded blob is also how the page knows it cannot reach
 * the network (the artifact host blocks all external requests), which
 * switches ticker selection from live fetching to the manual data panel.
 */
const ensembleForm = $('ensemble-form');

const EMBEDDED = globalThis.__MARKET_DATA__ ?? null;
const IS_ARTIFACT = EMBEDDED !== null;

const reference = { tickers: null, rates: null };

async function loadReferenceData() {
  const status = $('ticker-status');
  try {
    if (IS_ARTIFACT) {
      reference.tickers = EMBEDDED.tickers;
      reference.rates = EMBEDDED.rates;
    } else {
      const [tickers, rates] = await Promise.all([
        fetch('../data/tickers.json').then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
        fetch('../data/rates.json').then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }),
      ]);
      reference.tickers = tickers;
      reference.rates = rates;
    }
    status.textContent =
      `${count(reference.tickers.tickers.length)} US & Canadian listings · ` +
      `directory as of ${reference.tickers.asOf}`;
  } catch (error) {
    status.textContent = `Symbol directory unavailable (${error.message}) — paste prices below instead.`;
  }
}

/* ------------------------------------------------------ ticker combobox */

const tickerInput = $('ticker-search');
const tickerListbox = $('ticker-listbox');
let hits = [];
let activeHit = -1;
let selectedTicker = null;

function closeListbox() {
  tickerListbox.hidden = true;
  tickerInput.setAttribute('aria-expanded', 'false');
  tickerInput.removeAttribute('aria-activedescendant');
  activeHit = -1;
}

function renderListbox() {
  if (hits.length === 0) { closeListbox(); return; }
  tickerListbox.replaceChildren(...hits.map((hit, index) => {
    const item = document.createElement('li');
    item.id = `ticker-hit-${index}`;
    item.setAttribute('role', 'option');
    item.setAttribute('aria-selected', String(index === activeHit));

    const symbol = document.createElement('span');
    symbol.className = 'hit-symbol';
    symbol.textContent = hit.symbol;
    const name = document.createElement('span');
    name.className = 'hit-name';
    name.textContent = hit.name;
    const exchange = document.createElement('span');
    exchange.className = 'hit-exchange';
    exchange.textContent = hit.isEtf ? `${hit.exchangeName} · ETF` : hit.exchangeName;

    item.append(symbol, name, exchange);
    // mousedown, not click: the input's blur would close the list first.
    item.addEventListener('mousedown', (event) => {
      event.preventDefault();
      chooseTicker(hit);
    });
    return item;
  }));
  tickerListbox.hidden = false;
  tickerInput.setAttribute('aria-expanded', 'true');
  if (activeHit >= 0) tickerInput.setAttribute('aria-activedescendant', `ticker-hit-${activeHit}`);
  else tickerInput.removeAttribute('aria-activedescendant');
}

tickerInput.addEventListener('input', () => {
  if (!reference.tickers) return;
  hits = market.searchTickers(reference.tickers.tickers, tickerInput.value, 8);
  activeHit = hits.length ? 0 : -1;
  renderListbox();
});

tickerInput.addEventListener('keydown', (event) => {
  if (tickerListbox.hidden) return;
  if (event.key === 'ArrowDown') {
    event.preventDefault();
    activeHit = (activeHit + 1) % hits.length;
    renderListbox();
  } else if (event.key === 'ArrowUp') {
    event.preventDefault();
    activeHit = (activeHit - 1 + hits.length) % hits.length;
    renderListbox();
  } else if (event.key === 'Enter') {
    event.preventDefault();
    if (activeHit >= 0) chooseTicker(hits[activeHit]);
  } else if (event.key === 'Escape') {
    closeListbox();
  }
});

tickerInput.addEventListener('blur', () => closeListbox());

/* -------------------------------------------- selection & auto-population */

/**
 * Fields the user has edited by hand stay theirs: auto-population only
 * writes into a field the user has never touched. Programmatic writes do
 * not fire input events, so listening for real input is enough.
 */
const dirty = { rate: false, strike: false };
ensembleForm.elements.rate.addEventListener('input', () => { dirty.rate = true; });
ensembleForm.elements.strike.addEventListener('input', () => { dirty.strike = true; });

/* Strike rocker: step by the increment listed options actually use at this
   price level. Dispatching a real input event routes the change through the
   same path as typing — dirty-marking and the debounced re-run included. */
let lastSpot = 90;

function stepStrike(direction) {
  const input = ensembleForm.elements.strike;
  const step = lastSpot < 25 ? 0.5 : lastSpot < 100 ? 1 : lastSpot < 250 ? 5 : 10;
  const current = Number(input.value) || lastSpot;
  const next = Math.max(step, Math.round((current + direction * step) / step) * step);
  input.value = String(Math.round(next * 100) / 100);
  input.dispatchEvent(new Event('input', { bubbles: true }));
}

$('strike-down').addEventListener('click', () => stepStrike(-1));
$('strike-up').addEventListener('click', () => stepStrike(1));

/**
 * Selecting a second ticker while the first is still fetching must not let
 * the slow response win: each selection bumps the generation, and a response
 * from an older generation is dropped on arrival.
 */
let fetchGeneration = 0;

async function chooseTicker(entry) {
  const generation = ++fetchGeneration;
  selectedTicker = entry;
  tickerInput.value = entry.symbol;
  closeListbox();
  applyCurveRate();

  if (IS_ARTIFACT) {
    renderFetchPanel(entry);
    return;
  }

  const status = $('ticker-status');
  status.textContent = `Fetching two years of ${entry.symbol} from ` +
    `${entry.country === 'CA' ? 'TMX' : 'Nasdaq'}…`;
  $('fetch-panel').hidden = true;
  try {
    const response = await fetch(
      `/api/history?symbol=${encodeURIComponent(entry.symbol)}&exchange=${entry.exchange}`);
    const payload = await response.json();
    if (generation !== fetchGeneration) return; // a newer selection superseded this one
    if (!payload.ok) throw new Error(payload.error);
    const parsed = market.parseMarketData(payload.body);
    if (!parsed || parsed.prices.length < 30) throw new Error('provider returned too little data');
    applyMarketData(parsed, entry, payload.provider);
    status.textContent =
      `${count(reference.tickers.tickers.length)} US & Canadian listings · ` +
      `directory as of ${reference.tickers.asOf}`;
  } catch (error) {
    if (generation !== fetchGeneration) return;
    // The live path failed (offline, provider down): fall back to the same
    // manual panel the artifact uses rather than dead-ending.
    status.textContent = `Live fetch failed: ${error.message}`;
    renderFetchPanel(entry);
  }
}

/** Fill the history box and dependent fields from a parsed data set. */
function applyMarketData(parsed, entry, provider) {
  const prices = parsed.prices;
  const spot = prices[prices.length - 1];

  ensembleForm.elements.prices.value =
    prices.map((p) => (p >= 1000 ? p.toFixed(0) : p.toPrecision(6))).join('\n');

  if (!dirty.strike) {
    // Snap an untouched strike to at-the-money, on the increments listed
    // options actually use.
    const step = spot < 25 ? 0.5 : spot < 100 ? 1 : spot < 250 ? 5 : 10;
    ensembleForm.elements.strike.value = String(Math.round(spot / step) * step);
  }

  const bits = [];
  if (provider) bits.push(provider);
  else if (parsed.source) bits.push(parsed.source);
  bits.push(`${count(prices.length)} closes`);
  if (parsed.dates?.length) bits.push(`${parsed.dates[0]} → ${parsed.dates[parsed.dates.length - 1]}`);
  const currency = parsed.currency ?? entry?.currency;
  if (currency) bits.push(currency);
  if (parsed.splits.length) {
    bits.push(`adjusted for ${parsed.splits.map((s) =>
      `a ${s.ratio} split${s.date ? ` on ${s.date}` : ''}`).join(', ')}`);
  } else if (parsed.adjusted) {
    bits.push('split- and dividend-adjusted');
  }
  // If the file identifies itself and disagrees with the selected ticker,
  // say so — pricing RY off AAPL's history is a silent disaster otherwise.
  let warning = '';
  if (parsed.symbol && entry) {
    const droppedBase = parsed.symbol.split(/[.\-]/)[0].toUpperCase();
    const chosenBase = entry.symbol.split(/[.\-]/)[0].toUpperCase();
    if (droppedBase !== chosenBase) {
      warning = `<br><b>Careful:</b> this file says it is ${parsed.symbol}, ` +
        `but ${entry.symbol} is selected. The numbers below price ${parsed.symbol}'s history.`;
    }
  }

  const note = $('data-note');
  note.innerHTML = `<b>${entry ? entry.symbol : 'Data'}</b> · ${bits.join(' · ')}${warning}`;
  note.hidden = false;

  renderSymbolHeader(parsed, entry, spot);
  renderEnsemble();
}

/** The quote strip: ticker, name, last close and the last day's move. */
function renderSymbolHeader(parsed, entry, spot) {
  const prices = parsed.prices;
  $('sym-ticker').textContent = entry?.symbol ?? parsed.symbol ?? 'Pasted data';
  const meta = [];
  if (entry?.name) meta.push(entry.name);
  if (entry?.exchangeName) meta.push(entry.exchangeName);
  if (!entry && parsed.source) meta.push(parsed.source);
  const asOf = parsed.dates?.[parsed.dates.length - 1];
  if (asOf) meta.push(`as of ${asOf}`);
  $('sym-meta').textContent = meta.join(' · ');

  const currency = parsed.currency ?? entry?.currency ?? '';
  $('sym-last').textContent = `${money(spot)}${currency ? ` ${currency}` : ''}`;

  const change = $('sym-change');
  if (prices.length >= 2) {
    const previous = prices[prices.length - 2];
    const move = spot - previous;
    const pct = previous > 0 ? (move / previous) * 100 : 0;
    change.textContent = `${move >= 0 ? '+' : '−'}${Math.abs(move).toFixed(2)} ` +
      `(${move >= 0 ? '+' : '−'}${Math.abs(pct).toFixed(2)}%)`;
    change.classList.toggle('is-up', move >= 0);
    change.classList.toggle('is-down', move < 0);
    change.hidden = false;
  } else {
    change.hidden = true;
  }
  $('symbol-header').hidden = false;
}

/** Interpolate the bundled yield curve at the current horizon. */
function applyCurveRate() {
  if (dirty.rate || !reference.rates) return;
  const days = Number(ensembleForm.elements.days.value);
  if (!(days > 0)) return;
  const country = selectedTicker?.country === 'CA' ? 'ca' : 'us';
  const curve = reference.rates[country];
  const rate = market.rateForHorizon(curve.points, days);
  if (rate === null) return;
  ensembleForm.elements.rate.value = (rate * 100).toFixed(2);
  $('rate-note').textContent =
    `${(rate * 100).toFixed(2)}% from the ` +
    `${country === 'ca' ? 'Bank of Canada' : 'U.S. Treasury'} curve ` +
    `(as of ${curve.asOf}), interpolated at ${days} days. Edit to override.`;
}

ensembleForm.elements.days.addEventListener('input', applyCurveRate);

/* ------------------------------------------------------ expiry date field */

const expiryDateInput = $('expiry-date');

const isoDatePlus = (days) =>
  new Date(Date.now() + days * 86400000).toISOString().slice(0, 10);

/** Simple view thinks in dates; the models think in days. Date is master
 *  while it is visible: editing it rewrites the hidden days field before
 *  the form's own input handler reads it (target listeners run first). */
expiryDateInput.addEventListener('input', () => {
  const chosen = new Date(`${expiryDateInput.value}T12:00:00`);
  if (Number.isNaN(chosen.getTime())) return;
  const days = Math.max(1, Math.round((chosen - Date.now()) / 86400000));
  ensembleForm.elements.days.value = String(days);
  applyCurveRate();
});

/* ------------------------------------------------- manual data (artifact) */

/**
 * The published page cannot call any data provider itself — its host blocks
 * every external request, and a framed Google Sheet could not be read across
 * origins even if it rendered — so the flow is one copy-paste hop with the
 * page doing everything else: it writes the GOOGLEFINANCE formula for the
 * selected ticker, a click opens a fresh sheet, and the drop zone reads the
 * two columns the sheet fills exactly as Sheets copies them.
 */
function renderFetchPanel(entry) {
  const panel = $('fetch-panel');
  $('fetch-title').textContent =
    `Get ${entry.symbol} closes with Google Sheets (this page cannot fetch data itself):`;

  const formula = market.googleFinanceFormula(entry.symbol, entry.exchange);
  const steps = [];

  steps.push({ build: (item) => {
    item.append('Copy this formula ');
    const field = document.createElement('input');
    field.type = 'text';
    field.readOnly = true;
    field.className = 'formula-field';
    field.value = formula;
    field.setAttribute('aria-label', `GOOGLEFINANCE formula for ${entry.symbol}`);
    field.addEventListener('focus', () => field.select());
    field.addEventListener('click', () => field.select());
    const copy = document.createElement('button');
    copy.type = 'button';
    copy.className = 'copy-button';
    copy.textContent = 'Copy';
    copy.addEventListener('click', async () => {
      field.select();
      let done = false;
      try { await navigator.clipboard.writeText(formula); done = true; } catch { /* fall through */ }
      if (!done) { try { done = document.execCommand('copy'); } catch { /* leave selected */ } }
      copy.textContent = done ? 'Copied ✓' : 'Press Ctrl+C';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1800);
    });
    item.append(field, copy);
  } });

  steps.push({ html:
    `<a href="https://sheets.new" target="_blank" rel="noopener">Open a new ` +
    'Google Sheet</a> and paste it into cell A1 — GOOGLEFINANCE fills two ' +
    `years of daily closes for ${entry.symbol}.` });

  steps.push({ html:
    'Select the two filled columns (click A1, then Ctrl/Cmd-A), copy, and ' +
    'paste them below — dates, split adjustment and the rest are handled.' });

  const alternatives = [];
  const stooq = market.stooqSymbol(entry.symbol, entry.exchange);
  if (stooq) {
    alternatives.push(`<a href="https://stooq.com/q/d/l/?s=${encodeURIComponent(stooq)}&i=d" ` +
      `target="_blank" rel="noopener">Stooq CSV download</a>`);
  }
  const yahoo = market.yahooSymbol(entry.symbol, entry.exchange);
  alternatives.push(`<a href="https://query1.finance.yahoo.com/v8/finance/chart/` +
    `${encodeURIComponent(yahoo)}?range=2y&interval=1d" target="_blank" ` +
    `rel="noopener">Yahoo Finance JSON</a>`);
  steps.push({ html: `No Google account handy? ${alternatives.join(' or ')} ` +
    'drop straight in too.' });

  $('fetch-steps').replaceChildren(...steps.map((step) => {
    const item = document.createElement('li');
    if (step.build) step.build(item);
    else item.innerHTML = step.html;
    return item;
  }));
  panel.hidden = false;
}

function ingestDroppedText(text) {
  let parsed = null;
  try { parsed = market.parseMarketData(text); } catch { parsed = null; }
  if (!parsed || parsed.prices.length === 0) {
    showError($('ensemble-error'),
      'Could not read that as price data. Expected a CSV with date and close ' +
      'columns, Yahoo/Nasdaq JSON, or a plain list of prices.');
    return;
  }
  $('ensemble-error').hidden = true;
  applyMarketData(parsed, selectedTicker, null);
}

const dropzone = $('dropzone');

dropzone.addEventListener('dragover', (event) => {
  event.preventDefault();
  dropzone.classList.add('is-over');
});
dropzone.addEventListener('dragleave', () => dropzone.classList.remove('is-over'));
dropzone.addEventListener('drop', async (event) => {
  event.preventDefault();
  dropzone.classList.remove('is-over');
  const file = event.dataTransfer?.files?.[0];
  if (file) ingestDroppedText(await file.text());
  else {
    const text = event.dataTransfer?.getData('text');
    if (text) ingestDroppedText(text);
  }
});
dropzone.addEventListener('paste', (event) => {
  const text = event.clipboardData?.getData('text');
  if (text) { event.preventDefault(); ingestDroppedText(text); }
});
$('drop-file').addEventListener('change', async (event) => {
  const file = event.target.files?.[0];
  if (file) ingestDroppedText(await file.text());
  event.target.value = '';
});
// Clicking anywhere on the zone (except the browse label) focuses it so
// Ctrl+V works; keyboard users can tab to it directly.
dropzone.addEventListener('click', (event) => {
  if (!event.target.closest('.dropzone-browse')) dropzone.focus();
});

/* ------------------------------------------------------------ ensemble */



// (declared above, before the market-data wiring)
const REGIME_NAMES = {
  2: ['Calm', 'Turbulent'],
  3: ['Calm', 'Unsettled', 'Crisis'],
};

/** Sequential ramp: deeper means more volatile, matching the state order. */
const regimeFill = (index, states) =>
  `var(--regime-${states === 2 ? [1, 3][index] : index + 1})`;
const regimeSolid = (index, states) =>
  `var(--regime-${states === 2 ? [1, 3][index] : index + 1}-solid)`;

/** Attaches a tooltip layer to a chart container and returns its controls. */
function tooltipFor(container) {
  container.classList.add('chart-host');
  const tip = document.createElement('div');
  tip.className = 'chart-tip';
  return {
    node: tip,
    show(x, y, html) {
      tip.innerHTML = html;
      tip.style.left = `${x}px`;
      tip.style.top = `${y}px`;
      tip.dataset.visible = 'true';
    },
    hide() { tip.dataset.visible = 'false'; },
  };
}

function renderEnsemble() {
  const panel = document.querySelector('main [data-panel="ensemble"]');
  const errorBox = $('ensemble-error');
  errorBox.hidden = true;

  const f = readForm(ensembleForm);
  // The multi-format parser accepts a pasted CSV or provider JSON straight
  // into the history box, not just bare numbers.
  const parsed = market.parseMarketData(f.prices);
  const prices = parsed?.prices ?? [];

  $('series-summary').textContent = prices.length
    ? `${count(prices.length)} prices, ${money(prices[0])} to ${money(prices[prices.length - 1])}` +
      (parsed.source !== 'pasted prices' ? ` (${parsed.source})` : '')
    : 'no usable prices found';

  let result;
  try {
    result = ensembleValuation({
      prices,
      strike: f.strike,
      days: f.days,
      rate: f.rate / 100,
      yield: f.yield / 100,
      type: f.type,
      style: f.style,
      states: Number(f.states),
      paths: Number(f.paths),
      seed: Number(f.seed),
      periodsPerYear: Number(f.periodsPerYear),
    });
  } catch (error) {
    panel.classList.remove('is-computing');
    showError(errorBox, error.message);
    return;
  }

  const { consensus, outlook, hmm, monteCarlo, series } = result;

  /* ---- headline: what it is worth, and where the stock goes ---- */

  $('ens-value').textContent = money(consensus.value, 4);
  $('ens-range').textContent =
    `${money(consensus.low, 4)} to ${money(consensus.high, 4)} across the three models`;
  $('ens-spread').textContent = `${money(consensus.spread, 4)} (${percent(consensus.dispersion, 1)})`;
  $('ens-contract').textContent = money(consensus.value * 100);

  lastSpot = result.spot;
  renderSimpleReadout(result, f, prices);

  $('ens-outlook-label').textContent = `Projected price in ${count(result.days)} days`;
  $('ens-projected').textContent = money(outlook.median);
  $('ens-projected-note').textContent =
    `median of ${count(monteCarlo.paths)} paths, from ${money(result.spot)} today`;
  $('ens-band').textContent = `${money(outlook.p5)} – ${money(outlook.p95)}`;
  $('ens-itm').textContent = percent(
    result.type === 'put' ? 1 - outlook.probAboveStrike : outlook.probAboveStrike, 1);

  /* ---- the three answers, side by side ---- */

  renderDotPlot(result);
  $('ens-dotplot-note').textContent = consensus.dispersion < 0.05
    ? 'The three models agree closely, so the price is not resting on any one of them.'
    : `The models differ by ${percent(consensus.dispersion, 1)} of the average. ` +
      'The regime-switching simulation keeps the volatility-of-volatility that the ' +
      'closed form averages away, which is most of the gap.';

  renderRegimeTable(result);
  renderTransitionMatrix(result);
  renderModelSelection(result);
  renderHistoryChart(result, prices);
  renderDistributionChart(result);
  renderGreeks($('ens-greeks'), result.blackScholes.onRegime.greeks, 1);

  /* ---- diagnostics ---- */

  const rows = [
    ['Observations', `${count(series.observations)} prices, ${count(series.returns)} returns`],
    ['Trailing volatility', percent(series.trailingVol, 2)],
    ['Exponentially weighted', percent(series.smoothedVol, 2)],
    ['Regime-projected volatility', percent(hmm.projectedVol, 2)],
    ['Return skew', signed(series.skew, 3)],
    ['Excess kurtosis', signed(series.excessKurtosis, 3), true],
    ['Baum-Welch', hmm.converged
      ? `converged in ${hmm.iterations} iterations`
      : `stopped at ${hmm.iterations} iterations without converging`],
    ['Log-likelihood', hmm.logLikelihood.toFixed(1), true],
    ['BIC', `${hmm.bic.toFixed(1)} (prefers ${hmm.selection.preferred} regimes)`, true],
    ['Monte Carlo', `${count(monteCarlo.paths)} paths × ${monteCarlo.steps} steps`],
    ['Standard error', `± ${money(monteCarlo.european.standardError, 4)}`],
    ['95% interval', `${money(monteCarlo.european.confidence95[0], 4)} – ` +
      `${money(monteCarlo.european.confidence95[1], 4)}`],
    ['Variance reduction', percent(monteCarlo.european.varianceReduction, 0), true],
    ['GBM control check', monteCarlo.control.withinTolerance
      ? `passes — simulated ${money(monteCarlo.control.simulated, 4)} against ` +
        `${money(monteCarlo.control.analytic, 4)} closed form`
      : `off by ${money(Math.abs(monteCarlo.control.error), 4)} — raise the path count`],
  ];

  if (monteCarlo.american) {
    rows.push(['Exercised early', percent(monteCarlo.american.exercisedEarly, 1)]);
    rows.push(['American method', 'Longstaff-Schwartz least squares', true]);
  }

  renderFacts($('ens-diagnostics'), rows,
    'The control check reprices the contract by simulation under plain ' +
    'geometric Brownian motion, where the closed form is exact. If those two ' +
    'disagree by more than the standard error, the simulation is at fault ' +
    'rather than the model.');

  panel.classList.remove('is-computing');
}

/* ------------------------------------------------------ instruments -----
   The simple view is an instrument cluster: every readout is a drawn
   gauge fed by the live result, never a static illustration. */

const fmtDate = (date) => date.toLocaleDateString('en-US',
  { month: 'short', day: 'numeric', year: 'numeric' });

function currentExpiry(result) {
  return expiryDateInput.value
    ? new Date(`${expiryDateInput.value}T12:00:00`)
    : new Date(Date.now() + result.days * 86400000);
}

/** The beginner view: one instrument per fact. */
function renderSimpleReadout(result, form, prices) {
  const { consensus, outlook } = result;
  const symbol = selectedTicker?.symbol ?? 'the stock';
  const expiry = currentExpiry(result);

  $('s-dial-title').textContent = selectedTicker
    ? `Fair value · ${symbol} ${money(form.strike, 0)} ${form.type}`
    : `Fair value · ${money(form.strike, 0)} ${form.type}`;
  $('s-dial-exp').textContent = `exp ${fmtDate(expiry)} · ${count(result.days)}d`;
  $('s-fair').textContent = money(consensus.value, 2);
  $('s-contract').textContent = money(consensus.value * 100);
  $('s-agree').textContent = `± ${money(consensus.spread / 2)}`;
  renderDial(consensus);

  const isPut = form.type === 'put';
  const chance = isPut ? 1 - outlook.probAboveStrike : outlook.probAboveStrike;
  $('s-prob-date').textContent = fmtDate(expiry);
  $('s-chance-label').textContent =
    `chance ${symbol} ends ${isPut ? 'below' : 'above'} ${money(form.strike, 0)} · ` +
    'from the simulated futures';
  renderDonut(chance, `${isPut ? 'below' : 'above'} ${money(form.strike, 0)}`);

  renderLadder(outlook, form.strike, result.spot);
  $('s-ladder-note').textContent = `selected strike ${money(form.strike, 0)}`;

  $('s-outlook-label').textContent = `Outlook · where ${symbol} might land`;
  $('s-band').textContent =
    `9 of 10 simulations landed between ${money(outlook.p5)} and ${money(outlook.p95)}`;
  renderBarbell(outlook, result.spot, form.strike);

  $('s-tape-note').textContent =
    `${count(prices.length)} closes · last ${money(result.spot)}`;
  renderTape(prices);
}

/* ---- fair-value dial ----------------------------------------------------
   Scale spans the three models' range (padded); the shaded wedge is that
   range, the thin markers are the individual models, the needle is the
   consensus. Tight agreement reads as a narrow wedge under a steady needle. */

function renderDial(consensus) {
  const width = 320;
  const height = 168;
  const cx = width / 2;
  const cy = height - 16;
  const rOuter = 128;
  const rInner = 100;

  const span = Math.max(consensus.spread, consensus.value * 0.02, 1e-9);
  const lo = consensus.low - span * 0.8;
  const hi = consensus.high + span * 0.8;
  const angle = (v) => Math.PI + ((v - lo) / (hi - lo)) * Math.PI;
  const pt = (a, r) => [cx + r * Math.cos(a), cy + r * Math.sin(a)];

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Fair value dial: consensus ${consensus.value.toFixed(2)}, ` +
      `models span ${consensus.low.toFixed(2)} to ${consensus.high.toFixed(2)}.`,
  });

  // face arc
  const [ax, ay] = pt(Math.PI, rOuter);
  const [bx, by] = pt(2 * Math.PI, rOuter);
  svg.append(el('path', {
    d: `M${ax},${ay} A${rOuter},${rOuter} 0 0 1 ${bx},${by}`,
    fill: 'none', stroke: 'var(--line)', 'stroke-width': 2,
  }));

  // ticks with value labels at ends and centre
  for (let i = 0; i <= 8; i++) {
    const a = Math.PI + (i / 8) * Math.PI;
    const major = i % 4 === 0;
    const [x1, y1] = pt(a, rOuter);
    const [x2, y2] = pt(a, rOuter - (major ? 14 : 8));
    svg.append(el('line', {
      x1, y1, x2, y2,
      stroke: major ? 'var(--ink-muted)' : 'var(--line-strong)',
      'stroke-width': major ? 2 : 1,
    }));
    if (major && i === 4) {
      const value = lo + (i / 8) * (hi - lo);
      const [tx, ty] = pt(a, rOuter - 26);
      const text = el('text', {
        x: tx, y: ty + 4, 'text-anchor': 'middle',
        fill: 'var(--ink-muted)', 'font-size': 10.5,
        'font-family': 'var(--mono)', 'font-weight': 600,
      });
      text.textContent = value.toFixed(2);
      svg.append(text);
    }
  }

  // wedge: the models' range
  const a1 = angle(consensus.low);
  const a2 = angle(consensus.high);
  const [w1x, w1y] = pt(a1, rOuter - 2);
  const [w2x, w2y] = pt(a2, rOuter - 2);
  const [w3x, w3y] = pt(a2, rInner);
  const [w4x, w4y] = pt(a1, rInner);
  svg.append(el('path', {
    d: `M${w1x},${w1y} A${rOuter - 2},${rOuter - 2} 0 0 1 ${w2x},${w2y} ` +
       `L${w3x},${w3y} A${rInner},${rInner} 0 0 0 ${w4x},${w4y} Z`,
    fill: 'var(--accent-wash)', stroke: 'var(--accent)', 'stroke-width': 1,
  }));

  // individual model markers
  for (const estimate of consensus.estimates) {
    const a = angle(estimate.value);
    const [m1x, m1y] = pt(a, rOuter - 2);
    const [m2x, m2y] = pt(a, rInner + 6);
    svg.append(el('line', {
      x1: m1x, y1: m1y, x2: m2x, y2: m2y,
      stroke: 'var(--accent)', 'stroke-width': 1.5, opacity: .7,
    }));
  }

  // needle at the consensus, with hub
  const aN = angle(consensus.value);
  const [nx, ny] = pt(aN, rInner - 4);
  svg.append(el('line', {
    x1: cx, y1: cy, x2: nx, y2: ny,
    stroke: 'var(--led)', 'stroke-width': 3, 'stroke-linecap': 'round',
  }));
  svg.append(el('circle', { cx, cy, r: 7, fill: 'var(--led)' }));
  svg.append(el('circle', { cx, cy, r: 3, fill: 'var(--well)' }));

  const low = el('text', {
    x: cx - rOuter + 4, y: cy + 12, 'text-anchor': 'start',
    fill: 'var(--ink-muted)', 'font-size': 9.5,
    'font-family': 'var(--mono)', 'font-weight': 600, 'letter-spacing': 1.5,
  });
  low.textContent = 'LOW MODEL';
  const high = el('text', {
    x: cx + rOuter - 4, y: cy + 12, 'text-anchor': 'end',
    fill: 'var(--ink-muted)', 'font-size': 9.5,
    'font-family': 'var(--mono)', 'font-weight': 600, 'letter-spacing': 1.5,
  });
  high.textContent = 'HIGH MODEL';
  svg.append(low, high);

  $('dial').replaceChildren(svg);
}

/* ---- probability donut ------------------------------------------------- */

function renderDonut(chance, sublabel) {
  const size = 190;
  const c = size / 2;
  const r = 70;
  const stroke = 18;
  const circumference = 2 * Math.PI * r;

  const svg = el('svg', {
    viewBox: `0 0 ${size} ${size}`,
    role: 'img',
    'aria-label': `${Math.round(chance * 100)} percent chance of finishing ${sublabel}.`,
  });

  svg.append(el('circle', {
    cx: c, cy: c, r, fill: 'none',
    stroke: 'var(--sunk)', 'stroke-width': stroke,
  }));
  svg.append(el('circle', {
    cx: c, cy: c, r, fill: 'none',
    stroke: 'var(--led)', 'stroke-width': stroke, 'stroke-linecap': 'round',
    'stroke-dasharray': `${circumference * chance} ${circumference}`,
    transform: `rotate(-90 ${c} ${c})`,
  }));

  const big = el('text', {
    x: c, y: c + 2, 'text-anchor': 'middle',
    fill: 'var(--ink)', 'font-size': 34, 'font-weight': 700,
    'font-family': 'var(--mono)', id: 's-chance',
  });
  big.textContent = `${Math.round(chance * 100)}%`;
  const small = el('text', {
    x: c, y: c + 22, 'text-anchor': 'middle',
    fill: 'var(--ink-muted)', 'font-size': 9.5,
    'font-family': 'var(--mono)', 'font-weight': 600, 'letter-spacing': 1.2,
  });
  small.textContent = `ENDS ${sublabel.toUpperCase()}`;
  svg.append(big, small);

  $('donut').replaceChildren(svg);
}

/* ---- strike ladder ------------------------------------------------------
   A vertical scale spanning the plausible landing zone; each rung is a
   button that sets the strike, the chosen rung lights up, and a hollow
   pointer marks today's price. */

function niceStep(rough) {
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  for (const m of [1, 2, 2.5, 5, 10]) {
    if (rough <= m * magnitude) return m * magnitude;
  }
  return 10 * magnitude;
}

function renderLadder(outlook, strike, spot) {
  const width = 220;
  const height = 250;
  const pad = { top: 16, bottom: 16 };

  const lo = Math.min(outlook.p5, strike, spot);
  const hi = Math.max(outlook.p95, strike, spot);
  const step = niceStep((hi - lo) / 7);
  const bottom = Math.floor(lo / step) * step;
  const top = Math.ceil(hi / step) * step;
  const y = (v) => pad.top + ((top - v) / (top - bottom)) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Strike ladder from ${bottom} to ${top}; strike ${strike}, today ${spot.toFixed(2)}.`,
  });

  svg.append(el('line', {
    x1: 92, x2: 92, y1: pad.top, y2: height - pad.bottom,
    stroke: 'var(--line-strong)', 'stroke-width': 2,
  }));

  for (let v = bottom; v <= top + 1e-9; v += step) {
    const yy = y(v);
    const isStrike = Math.abs(v - strike) < step / 2 &&
      Math.abs(v - strike) <= Math.abs(Math.round(strike / step) * step - strike) + 1e-9 &&
      Math.round(v / step) === Math.round(strike / step);

    const group = el('g', { class: 'ladder-rung', role: 'button', tabindex: 0,
      'aria-label': `Set strike to ${v}` });

    if (isStrike) {
      svg.append(el('rect', {
        x: 66, y: yy - 11, width: 118, height: 22, rx: 5,
        fill: 'var(--accent-wash)', stroke: 'var(--accent)', 'stroke-width': 1,
      }));
    }
    group.append(el('line', {
      x1: 74, x2: 110, y1: yy, y2: yy,
      stroke: isStrike ? 'var(--led)' : 'var(--line-strong)',
      'stroke-width': isStrike ? 3 : 1.5,
    }));
    const label = el('text', {
      x: 120, y: yy + 4, fill: isStrike ? 'var(--accent)' : 'var(--ink-muted)',
      'font-size': 12, 'font-family': 'var(--mono)',
      'font-weight': isStrike ? 700 : 500,
    });
    label.textContent = String(Math.round(v * 100) / 100);
    group.append(label);
    if (isStrike) {
      const tag = el('text', {
        x: 214, y: yy + 3.5, 'text-anchor': 'end', fill: 'var(--accent)',
        'font-size': 8.5, 'font-family': 'var(--mono)', 'font-weight': 700,
        'letter-spacing': 1,
      });
      tag.textContent = 'STRIKE';
      group.append(tag);
    }
    // generous invisible hit area
    const hit = el('rect', {
      x: 60, y: yy - Math.min(12, (y(bottom) - y(top)) / ((top - bottom) / step) / 2),
      width: 154, height: Math.min(24, height / ((top - bottom) / step)),
      fill: 'transparent',
    });
    const setStrike = () => {
      const input = ensembleForm.elements.strike;
      input.value = String(Math.round(v * 100) / 100);
      input.dispatchEvent(new Event('input', { bubbles: true }));
    };
    group.addEventListener('click', setStrike);
    group.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setStrike(); }
    });
    group.append(hit);
    svg.append(group);
  }

  // today's price: hollow pointer on the left
  const spotY = y(spot);
  svg.append(el('path', {
    d: `M52,${spotY} l14,-7 l0,14 Z`,
    fill: 'none', stroke: 'var(--ink)', 'stroke-width': 1.5,
  }));
  const today = el('text', {
    x: 46, y: spotY + 3.5, 'text-anchor': 'end', fill: 'var(--ink-muted)',
    'font-size': 8.5, 'font-family': 'var(--mono)', 'font-weight': 700,
    'letter-spacing': 1,
  });
  today.textContent = 'TODAY';
  svg.append(today);

  $('ladder').replaceChildren(svg);
}

/* ---- outlook barbell ---------------------------------------------------- */

function renderBarbell(outlook, spot, strike) {
  const width = 640;
  const height = 96;
  const pad = 46;
  const yMid = 58;

  const lo = Math.min(outlook.p5, spot, strike);
  const hi = Math.max(outlook.p95, spot, strike);
  const span = hi - lo || 1;
  const x = (v) => pad + ((v - lo) / span) * (width - 2 * pad);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Outlook range ${outlook.p5.toFixed(2)} to ${outlook.p95.toFixed(2)}, ` +
      `median ${outlook.median.toFixed(2)}, today ${spot.toFixed(2)}.`,
  });

  // bar with end stops
  svg.append(el('line', {
    x1: x(outlook.p5), x2: x(outlook.p95), y1: yMid, y2: yMid,
    stroke: 'var(--line-strong)', 'stroke-width': 3, 'stroke-linecap': 'round',
  }));
  for (const v of [outlook.p5, outlook.p95]) {
    svg.append(el('line', {
      x1: x(v), x2: x(v), y1: yMid - 9, y2: yMid + 9,
      stroke: 'var(--line-strong)', 'stroke-width': 3, 'stroke-linecap': 'round',
    }));
    const label = el('text', {
      x: x(v), y: yMid + 26, 'text-anchor': 'middle', fill: 'var(--ink-muted)',
      'font-size': 11, 'font-family': 'var(--mono)', 'font-weight': 600,
    });
    label.textContent = v.toFixed(2);
    svg.append(label);
  }

  // strike marker (dashed) when it sits inside the drawn span
  svg.append(el('line', {
    x1: x(strike), x2: x(strike), y1: yMid - 16, y2: yMid + 16,
    stroke: 'var(--negative)', 'stroke-width': 1.5, 'stroke-dasharray': '4 3',
  }));
  // The strike caption shares the top lane with MEDIAN; when the two sit
  // close it steps aside horizontally instead of overprinting.
  const nearMedian = Math.abs(x(strike) - x(outlook.median)) < 96;
  const strikeLabel = el('text', {
    x: nearMedian ? x(strike) + (x(strike) >= x(outlook.median) ? 8 : -8) : x(strike),
    y: 12,
    'text-anchor': nearMedian ? (x(strike) >= x(outlook.median) ? 'start' : 'end') : 'middle',
    fill: 'var(--negative)',
    'font-size': 9, 'font-family': 'var(--mono)', 'font-weight': 700, 'letter-spacing': 1,
  });
  strikeLabel.textContent = `STRIKE ${Math.round(strike * 100) / 100}`;
  svg.append(strikeLabel);

  // today: hollow bead. Its label dodges below the bar when the median sits
  // close enough that the two captions would overprint.
  svg.append(el('circle', {
    cx: x(spot), cy: yMid, r: 6,
    fill: 'var(--well)', stroke: 'var(--ink)', 'stroke-width': 2,
  }));
  const crowded = Math.abs(x(spot) - x(outlook.median)) < 92;
  const todayLabel = el('text', {
    x: x(spot), y: crowded ? yMid + 30 : yMid - 16, 'text-anchor': 'middle',
    fill: 'var(--ink-muted)', 'font-size': 9, 'font-family': 'var(--mono)',
    'font-weight': 700, 'letter-spacing': 1,
  });
  todayLabel.textContent = `TODAY ${spot.toFixed(2)}`;
  svg.append(todayLabel);

  // median: filled bead, labelled above
  svg.append(el('circle', {
    cx: x(outlook.median), cy: yMid, r: 8,
    fill: 'var(--led)', stroke: 'var(--well)', 'stroke-width': 2.5,
  }));
  const medianLabel = el('text', {
    x: x(outlook.median), y: 18, 'text-anchor': 'middle', fill: 'var(--accent)',
    'font-size': 12, 'font-family': 'var(--mono)', 'font-weight': 700, id: 's-median',
  });
  medianLabel.textContent = `MEDIAN ${outlook.median.toFixed(2)}`;
  svg.append(medianLabel);
  svg.append(el('line', {
    x1: x(outlook.median), x2: x(outlook.median), y1: 24, y2: yMid - 10,
    stroke: 'var(--accent)', 'stroke-width': 1, 'stroke-dasharray': '2 3',
  }));

  $('barbell').replaceChildren(svg);
}

/* ---- price tape ---------------------------------------------------------- */

function renderTape(prices) {
  const width = 640;
  const height = 150;
  const pad = { top: 14, right: 66, bottom: 14, left: 10 };
  const series = prices.slice(-260);

  const lo = Math.min(...series);
  const hi = Math.max(...series);
  const span = hi - lo || 1;
  const x = (i) => pad.left + (i / (series.length - 1)) * (width - pad.left - pad.right);
  const y = (v) => pad.top + ((hi - v) / span) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Price tape: ${series.length} closes from ${series[0].toFixed(2)} ` +
      `to ${series[series.length - 1].toFixed(2)}.`,
  });

  const gradient = el('linearGradient', { id: 'tape-fade', x1: 0, y1: 0, x2: 0, y2: 1 });
  gradient.append(
    el('stop', { offset: '0%', 'stop-color': 'var(--led)', 'stop-opacity': .18 }),
    el('stop', { offset: '100%', 'stop-color': 'var(--led)', 'stop-opacity': 0 }));
  const defs = el('defs');
  defs.append(gradient);
  svg.append(defs);

  for (const v of [lo, hi]) {
    svg.append(el('line', {
      x1: pad.left, x2: width - pad.right, y1: y(v), y2: y(v),
      stroke: 'var(--line)', 'stroke-width': 1, 'stroke-dasharray': '2 4',
    }));
    const label = el('text', {
      x: width - pad.right + 8, y: y(v) + 3.5, fill: 'var(--ink-muted)',
      'font-size': 10, 'font-family': 'var(--mono)',
    });
    label.textContent = v.toFixed(0);
    svg.append(label);
  }

  const lineD = series.map((p, i) =>
    `${i === 0 ? 'M' : 'L'}${x(i).toFixed(2)},${y(p).toFixed(2)}`).join(' ');
  svg.append(el('path', {
    d: `${lineD} L${x(series.length - 1).toFixed(2)},${height - pad.bottom} ` +
       `L${x(0).toFixed(2)},${height - pad.bottom} Z`,
    fill: 'url(#tape-fade)', stroke: 'none',
  }));
  svg.append(el('path', {
    d: lineD, fill: 'none', stroke: 'var(--led)', 'stroke-width': 1.6,
    'stroke-linejoin': 'round',
  }));

  const last = series[series.length - 1];
  svg.append(el('circle', {
    cx: x(series.length - 1), cy: y(last), r: 4,
    fill: 'var(--led)', stroke: 'var(--well)', 'stroke-width': 2,
  }));
  const lastLabel = el('text', {
    x: width - pad.right + 8, y: y(last) + 3.5, fill: 'var(--accent)',
    'font-size': 11, 'font-family': 'var(--mono)', 'font-weight': 700,
  });
  lastLabel.textContent = last.toFixed(2);
  svg.append(lastLabel);

  $('tape').replaceChildren(svg);
}

/* ---- chart: where each model lands -------------------------------------
   Three labelled marks on one shared axis. Identity comes from the labels,
   so no categorical palette is needed and none is invented. */

function renderDotPlot(result) {
  const { consensus } = result;
  const width = 660;
  const rowHeight = 46;
  const pad = { top: 10, right: 20, bottom: 30, left: 20 };
  const height = pad.top + pad.bottom + consensus.estimates.length * rowHeight;

  const span = Math.max(consensus.spread, consensus.value * 0.04, 1e-6);
  const from = consensus.low - span * 0.35;
  const to = consensus.high + span * 0.35;
  const x = (value) => pad.left + ((value - from) / (to - from)) * (width - pad.left - pad.right);

  const container = $('ens-dotplot');
  const tip = tooltipFor(container);
  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Fair value by model: ${consensus.estimates
      .map((e) => `${e.label}, ${e.value.toFixed(4)}`).join('; ')}.`,
  });

  // Consensus reference, drawn behind the marks.
  svg.append(el('line', {
    x1: x(consensus.value), x2: x(consensus.value), y1: pad.top - 4,
    y2: height - pad.bottom + 4, stroke: 'var(--line-strong)',
    'stroke-width': 1, 'stroke-dasharray': '3 3',
  }));

  consensus.estimates.forEach((estimate, index) => {
    const y = pad.top + index * rowHeight + rowHeight / 2;

    svg.append(el('line', {
      x1: pad.left, x2: width - pad.right, y1: y, y2: y,
      stroke: 'var(--line)', 'stroke-width': 1,
    }));

    const label = el('text', {
      x: pad.left, y: y - 9, fill: 'var(--ink-muted)', 'font-size': 11.5,
    });
    label.textContent = estimate.label;
    svg.append(label);

    // A 2px surface ring keeps the mark legible where it overlaps the rule.
    svg.append(el('circle', {
      cx: x(estimate.value), cy: y, r: 6,
      fill: 'var(--accent)', stroke: 'var(--surface)', 'stroke-width': 2,
    }));

    // Below the mark, while the model name sits above the rule — otherwise a
    // mark near the left edge puts its value straight through the name.
    const value = el('text', {
      x: x(estimate.value), y: y + 19, 'text-anchor': 'middle',
      fill: 'var(--ink)', 'font-size': 12.5, 'font-family': 'var(--mono)',
      'font-weight': 600,
    });
    value.textContent = estimate.value.toFixed(4);
    svg.append(value);

    const hit = el('rect', {
      x: pad.left, y: y - rowHeight / 2, width: width - pad.left - pad.right,
      height: rowHeight, fill: 'transparent',
    });
    hit.addEventListener('pointerenter', () => {
      const box = container.getBoundingClientRect();
      tip.show(
        (x(estimate.value) / width) * box.width,
        (y / height) * box.height,
        `<span class="tip-label">${estimate.label}</span><br><b>${money(estimate.value, 4)}</b>` +
        `<br><span class="tip-label">${signed(estimate.value - consensus.value, 4)} vs consensus</span>`,
      );
    });
    hit.addEventListener('pointerleave', () => tip.hide());
    svg.append(hit);
  });

  const caption = el('text', {
    x: x(consensus.value), y: height - 10, 'text-anchor': 'middle',
    fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
  });
  caption.textContent = `consensus ${consensus.value.toFixed(4)}`;
  svg.append(caption);

  container.replaceChildren(svg, tip.node);
}

/* ---- table: the regimes Baum-Welch recovered --------------------------- */

function renderRegimeTable(result) {
  const { hmm } = result;
  const names = REGIME_NAMES[hmm.states] ?? REGIME_NAMES[2];
  const periods = result.series?.periodsPerYear ?? 252;

  const head = ['Regime', 'Volatility', 'Drift p.a.', 'Typical run', 'Probability now', 'Long-run share'];
  const table = $('ens-regimes');

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const title of head) {
    const th = document.createElement('th');
    th.scope = 'col';
    th.textContent = title;
    headRow.append(th);
  }
  thead.append(headRow);

  const tbody = document.createElement('tbody');
  for (let i = 0; i < hmm.states; i++) {
    const row = document.createElement('tr');

    const name = document.createElement('th');
    name.scope = 'row';
    const chip = document.createElement('span');
    chip.className = 'regime-chip';
    const swatch = document.createElement('span');
    swatch.className = 'regime-swatch';
    swatch.style.background = regimeSolid(i, hmm.states);
    chip.append(swatch, document.createTextNode(names[i] ?? `State ${i + 1}`));
    name.append(chip);
    row.append(name);

    const periodName = periods === 252 ? 'days' : periods === 52 ? 'weeks' : 'months';
    for (const cell of [
      percent(hmm.annualisedVols[i], 1),
      signed(hmm.annualisedDrifts[i] * 100, 1) + '%',
      `${hmm.expectedDurations[i].toFixed(0)} ${periodName}`,
      percent(hmm.current[i], 1),
      percent(hmm.stationary[i], 1),
    ]) {
      const td = document.createElement('td');
      td.textContent = cell;
      row.append(td);
    }
    tbody.append(row);
  }

  const caption = table.querySelector('caption');
  table.replaceChildren(caption, thead, tbody);
}

function renderTransitionMatrix(result) {
  const { hmm } = result;
  const names = REGIME_NAMES[hmm.states] ?? REGIME_NAMES[2];
  const table = $('ens-transition');

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  const corner = document.createElement('th');
  corner.scope = 'col';
  corner.textContent = 'From ↓ To →';
  headRow.append(corner);
  for (let j = 0; j < hmm.states; j++) {
    const th = document.createElement('th');
    th.scope = 'col';
    th.textContent = names[j] ?? `State ${j + 1}`;
    headRow.append(th);
  }
  thead.append(headRow);

  const tbody = document.createElement('tbody');
  for (let i = 0; i < hmm.states; i++) {
    const row = document.createElement('tr');
    const label = document.createElement('th');
    label.scope = 'row';
    label.textContent = names[i] ?? `State ${i + 1}`;
    row.append(label);
    for (let j = 0; j < hmm.states; j++) {
      const td = document.createElement('td');
      td.textContent = percent(hmm.transition[i][j], 1);
      if (i === j) td.classList.add('is-diagonal');
      row.append(td);
    }
    tbody.append(row);
  }

  const caption = table.querySelector('caption');
  table.replaceChildren(caption, thead, tbody);
}

/** Warns when the chosen number of regimes is not the number the data supports. */
function renderModelSelection(result) {
  const { selection, negligible, states } = result.hmm;
  const names = REGIME_NAMES[states] ?? REGIME_NAMES[2];
  const notice = $('ens-selection');
  const messages = [];

  if (selection.preferred !== states) {
    messages.push(
      `<b>BIC prefers ${selection.preferred} regimes</b>, not ${states}. ` +
      `Scores: ${selection.scores.map((s) => `${s.states} → ${s.bic.toFixed(0)}`).join(', ')} ` +
      '(lower is better). Extra states always fit the past better; BIC charges ' +
      'for the parameters they cost.');
  }

  for (const index of negligible) {
    messages.push(
      `The <b>${names[index] ?? `state ${index + 1}`}</b> regime holds only ` +
      `${percent(result.hmm.stationary[index], 1)} of the time in the long run, ` +
      'which usually means it is fitting a handful of individual days rather ' +
      'than a market state.');
  }

  notice.innerHTML = messages.join('<br><br>');
  notice.hidden = messages.length === 0;
}

/* ---- chart: history shaded by regime ----------------------------------- */

function renderHistoryChart(result, prices) {
  const { hmm } = result;
  const width = 900;
  const height = 260;
  const pad = { top: 12, right: 14, bottom: 26, left: 52 };
  const container = $('ens-history');
  const tip = tooltipFor(container);

  const low = Math.min(...prices);
  const high = Math.max(...prices);
  const padding = (high - low) * 0.08 || 1;
  const yFrom = low - padding;
  const yTo = high + padding;

  const x = (i) => pad.left + (i / (prices.length - 1)) * (width - pad.left - pad.right);
  const y = (p) => height - pad.bottom - ((p - yFrom) / (yTo - yFrom)) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label':
      `${prices.length} closing prices from ${prices[0].toFixed(2)} to ` +
      `${prices[prices.length - 1].toFixed(2)}, shaded by the volatility regime ` +
      'the model assigns to each stretch.',
  });

  // Regime bands: one rect per contiguous run, not per observation.
  // The Viterbi path is indexed by return, so state k describes the move
  // into price k+1.
  let runStart = 0;
  for (let i = 1; i <= hmm.viterbi.length; i++) {
    if (i === hmm.viterbi.length || hmm.viterbi[i] !== hmm.viterbi[runStart]) {
      const state = hmm.viterbi[runStart];
      svg.append(el('rect', {
        x: x(runStart), y: pad.top,
        width: Math.max(0.8, x(i) - x(runStart)),
        height: height - pad.top - pad.bottom,
        fill: regimeFill(state, hmm.states),
      }));
      runStart = i;
    }
  }

  const ticks = 4;
  for (let i = 0; i <= ticks; i++) {
    const value = yFrom + ((yTo - yFrom) * i) / ticks;
    const yy = y(value);
    svg.append(el('line', {
      x1: pad.left, x2: width - pad.right, y1: yy, y2: yy,
      stroke: 'var(--line)', 'stroke-width': 1,
    }));
    const text = el('text', {
      x: pad.left - 9, y: yy + 4, 'text-anchor': 'end',
      fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
    });
    text.textContent = value.toFixed(0);
    svg.append(text);
  }

  // Platform-blue price line over a soft gradient fill; the regime washes
  // behind it carry the risk story in their own hues.
  const gradient = el('linearGradient', { id: 'price-fade', x1: 0, y1: 0, x2: 0, y2: 1 });
  gradient.append(
    el('stop', { offset: '0%', 'stop-color': 'var(--accent)', 'stop-opacity': .16 }),
    el('stop', { offset: '100%', 'stop-color': 'var(--accent)', 'stop-opacity': 0 }));
  const defs = el('defs');
  defs.append(gradient);
  svg.append(defs);

  const lineD = prices.map((p, i) =>
    `${i === 0 ? 'M' : 'L'}${x(i).toFixed(2)},${y(p).toFixed(2)}`).join(' ');
  svg.append(el('path', {
    d: `${lineD} L${x(prices.length - 1).toFixed(2)},${height - pad.bottom} ` +
       `L${x(0).toFixed(2)},${height - pad.bottom} Z`,
    fill: 'url(#price-fade)', stroke: 'none',
  }));
  svg.append(el('path', {
    d: lineD,
    fill: 'none', stroke: 'var(--accent)', 'stroke-width': 1.8,
    'stroke-linejoin': 'round',
  }));

  for (let i = 0; i <= 4; i++) {
    const index = Math.round(((prices.length - 1) * i) / 4);
    const text = el('text', {
      x: x(index), y: height - 9, 'text-anchor': 'middle',
      fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
    });
    text.textContent = String(index + 1);
    svg.append(text);
  }

  const crosshair = el('line', {
    y1: pad.top, y2: height - pad.bottom, stroke: 'var(--ink-muted)',
    'stroke-width': 1, 'stroke-dasharray': '3 3', opacity: 0,
  });
  const marker = el('circle', {
    r: 4, fill: 'var(--accent)', stroke: 'var(--surface)', 'stroke-width': 2, opacity: 0,
  });
  svg.append(crosshair, marker);

  const names = REGIME_NAMES[hmm.states] ?? REGIME_NAMES[2];
  const surface = el('rect', {
    x: pad.left, y: pad.top, width: width - pad.left - pad.right,
    height: height - pad.top - pad.bottom, fill: 'transparent',
  });
  surface.addEventListener('pointermove', (event) => {
    const box = container.getBoundingClientRect();
    const ratio = (event.clientX - box.left) / box.width;
    const index = Math.max(0, Math.min(prices.length - 1, Math.round(ratio * (prices.length - 1))));
    const posterior = hmm.posteriors[Math.max(0, index - 1)] ?? [];
    const state = hmm.viterbi[Math.max(0, index - 1)] ?? 0;

    crosshair.setAttribute('x1', x(index));
    crosshair.setAttribute('x2', x(index));
    crosshair.setAttribute('opacity', 1);
    marker.setAttribute('cx', x(index));
    marker.setAttribute('cy', y(prices[index]));
    marker.setAttribute('opacity', 1);

    tip.show((x(index) / width) * box.width, (y(prices[index]) / height) * box.height,
      `<span class="tip-label">observation ${index + 1}</span><br>` +
      `<b>${money(prices[index])}</b><br>` +
      `<span class="tip-label">${names[state] ?? `State ${state + 1}`} · ` +
      `${percent(posterior[state] ?? 0, 0)} confident</span>`);
  });
  surface.addEventListener('pointerleave', () => {
    crosshair.setAttribute('opacity', 0);
    marker.setAttribute('opacity', 0);
    tip.hide();
  });
  svg.append(surface);

  container.replaceChildren(svg, tip.node);

  const legend = $('ens-history-legend');
  legend.replaceChildren(...Array.from({ length: hmm.states }, (unused, i) => {
    const item = document.createElement('span');
    const swatch = document.createElement('i');
    swatch.className = 'swatch';
    swatch.style.background = regimeSolid(i, hmm.states);
    swatch.style.height = '10px';
    swatch.style.width = '10px';
    swatch.style.borderRadius = '3px';
    item.append(swatch, document.createTextNode(
      `${names[i] ?? `State ${i + 1}`} · ${percent(hmm.annualisedVols[i], 0)} vol`));
    return item;
  }));
}

/* ---- chart: terminal price distribution -------------------------------- */

function renderDistributionChart(result) {
  const { outlook, strike, spot } = result;
  const width = 620;
  const height = 280;
  const pad = { top: 54, right: 14, bottom: 34, left: 44 };
  const container = $('ens-distribution');
  const tip = tooltipFor(container);

  const bins = outlook.histogram;
  const from = bins[0].from;
  const to = bins[bins.length - 1].to;
  const peak = Math.max(...bins.map((b) => b.frequency)) || 1;

  const x = (price) => pad.left + ((price - from) / (to - from)) * (width - pad.left - pad.right);
  const y = (freq) => height - pad.bottom - (freq / peak) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label':
      `Simulated distribution of the price at expiry: median ${outlook.median.toFixed(2)}, ` +
      `90% of paths between ${outlook.p5.toFixed(2)} and ${outlook.p95.toFixed(2)}.`,
  });

  const baseline = height - pad.bottom;
  bins.forEach((bin) => {
    const left = x(bin.from);
    const right = x(bin.to);
    // 2px gap between bars, and 4px rounded tops anchored to the baseline.
    const barWidth = Math.max(1, right - left - 2);
    const top = y(bin.frequency);
    const radius = Math.min(4, barWidth / 2, Math.max(0, baseline - top));
    const inBand = bin.to > outlook.p5 && bin.from < outlook.p95;

    svg.append(el('path', {
      d: `M${left + 1},${baseline} L${left + 1},${top + radius} ` +
         `Q${left + 1},${top} ${left + 1 + radius},${top} ` +
         `L${left + 1 + barWidth - radius},${top} ` +
         `Q${left + 1 + barWidth},${top} ${left + 1 + barWidth},${top + radius} ` +
         `L${left + 1 + barWidth},${baseline} Z`,
      fill: inBand ? 'var(--accent)' : 'var(--line-strong)',
    }));

    const hit = el('rect', {
      x: left, y: pad.top, width: Math.max(1, right - left),
      height: baseline - pad.top, fill: 'transparent',
    });
    hit.addEventListener('pointerenter', () => {
      const box = container.getBoundingClientRect();
      tip.show(((left + right) / 2 / width) * box.width, (top / height) * box.height,
        `<span class="tip-label">${money(bin.from)} – ${money(bin.to)}</span><br>` +
        `<b>${percent(bin.frequency, 1)}</b> <span class="tip-label">of paths</span>`);
    });
    hit.addEventListener('pointerleave', () => tip.hide());
    svg.append(hit);
  });

  // Reference lines, directly labelled rather than put in a legend.
  // Reference lines are neutral ink, distinguished by weight and dash. Red
  // and green are reserved for good/bad here, and a strike price is neither.
  const markers = [
    { at: outlook.median, label: 'median', colour: 'var(--ink-muted)', dash: '4 3', weight: 1.5 },
    { at: strike, label: 'strike', colour: 'var(--ink)', dash: '6 3', weight: 2 },
    { at: spot, label: 'today', colour: 'var(--ink-muted)', dash: '2 3', weight: 1.5 },
  ];
  // Median, strike and spot are often within a few percent of each other, so
  // the labels get their own vertical lanes rather than stacking on one line
  // and overprinting each other into noise.
  const visible = markers.filter(({ at }) => at >= from && at <= to);
  // Every line starts below the whole label stack. Starting each one under
  // its own label only works for the bottom lane; the rest strike through
  // the labels beneath them.
  const lineTop = pad.top - 40 + visible.length * 13 + 2;
  visible.forEach(({ at, label, colour, dash, weight }, lane) => {
    const labelY = pad.top - 40 + lane * 13;
    svg.append(el('line', {
      x1: x(at), x2: x(at), y1: lineTop, y2: baseline,
      stroke: colour, 'stroke-width': weight, 'stroke-dasharray': dash,
    }));

    // Keep the text inside the plot when a marker sits against either edge.
    const anchor = x(at) < pad.left + 34 ? 'start' : x(at) > width - pad.right - 34 ? 'end' : 'middle';
    const text = el('text', {
      x: x(at), y: labelY, 'text-anchor': anchor,
      fill: colour, 'font-size': 10.5, 'font-weight': 600,
    });
    text.textContent = `${label} ${at.toFixed(2)}`;
    svg.append(text);
  });

  for (let i = 0; i <= 4; i++) {
    const price = from + ((to - from) * i) / 4;
    const text = el('text', {
      x: x(price), y: height - 12, 'text-anchor': 'middle',
      fill: 'var(--ink-muted)', 'font-size': 11, 'font-family': 'var(--mono)',
    });
    text.textContent = price.toFixed(0);
    svg.append(text);
  }

  container.replaceChildren(svg, tip.node);
}

/* -------------------------------------------------------------- wiring */

const MODES = {
  ensemble: renderEnsemble,
  price: renderPrice,
  implied: renderImplied,
  grant: renderGrant,
};

/* Debounced, because a full run fits three models over a few hundred
   observations and simulates tens of thousands of paths — enough work that
   firing it on every keystroke would make the inputs feel stuck. */
function debounce(fn, wait) {
  let timer = null;
  return function scheduled(...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}

for (const [mode, render] of Object.entries(MODES)) {
  const form = document.querySelector(`form[data-panel="${mode}"]`);
  const handler = mode === 'ensemble' ? debounce(render, 320) : render;
  form.addEventListener('input', (event) => {
    // Dim the figures the moment an input changes, so the pause before the
    // debounced run lands reads as work rather than as a frozen page.
    if (mode === 'ensemble') {
      document.querySelector('main [data-panel="ensemble"]')?.classList.add('is-computing');
    }
    handler(event);
  });
  form.addEventListener('submit', (event) => event.preventDefault());
}

for (const button of document.querySelectorAll('.mode')) {
  button.addEventListener('click', () => {
    const mode = button.dataset.mode;
    for (const other of document.querySelectorAll('.mode')) {
      const active = other === button;
      other.classList.toggle('is-active', active);
      other.setAttribute('aria-selected', String(active));
    }
    for (const panel of document.querySelectorAll('[data-panel]')) {
      panel.hidden = panel.dataset.panel !== mode;
    }
    MODES[mode]();
  });
}

$('theme').addEventListener('click', () => {
  const root = document.documentElement;
  // No stamp means the viewer is following their system; the first press
  // should flip away from whatever they are actually looking at.
  const current = root.dataset.theme
    ?? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  root.dataset.theme = current === 'dark' ? 'light' : 'dark';
});

/* ------------------------------------------------------- simple/advanced */

function setView(view) {
  document.body.dataset.view = view;
  for (const tab of document.querySelectorAll('.view-tab')) {
    const active = tab.dataset.view === view;
    tab.classList.toggle('is-active', active);
    tab.setAttribute('aria-selected', String(active));
  }
  if (view === 'simple') {
    // Simple view is a window onto the ensemble; make sure it is showing,
    // and keep the date field agreeing with however days was left.
    document.querySelector('.mode[data-mode="ensemble"]')?.click();
    const days = Number(ensembleForm.elements.days.value) || 90;
    expiryDateInput.value = isoDatePlus(days);
  }
}

for (const tab of document.querySelectorAll('.view-tab')) {
  tab.addEventListener('click', () => setView(tab.dataset.view));
}

expiryDateInput.value = isoDatePlus(Number(ensembleForm.elements.days.value) || 90);
setView('simple');

renderPrice();
renderImplied();
renderGrant();
renderEnsemble();
loadReferenceData().then(() => applyCurveRate());
