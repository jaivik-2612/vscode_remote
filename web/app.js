/**
 * UI layer. All the maths lives in ../src; this file reads the controls,
 * calls the engine and renders the readout.
 */

import {
  valuation, valueCurve, employeeGrantValue, yearsFromDays,
  impliedVol, priceBounds, blackScholes as bs, binomial,
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

/* -------------------------------------------------------------- wiring */

const MODES = {
  price: renderPrice,
  implied: renderImplied,
  grant: renderGrant,
};

for (const [mode, render] of Object.entries(MODES)) {
  const form = document.querySelector(`form[data-panel="${mode}"]`);
  form.addEventListener('input', render);
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

renderPrice();
renderImplied();
renderGrant();
