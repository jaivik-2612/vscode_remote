/**
 * UI layer. All the maths lives in ../src; this file only reads the forms,
 * calls the engine and renders the result.
 */

import {
  valuation, valueCurve, employeeGrantValue, yearsFromDays,
  impliedVol, priceBounds, blackScholes as bs, binomial,
} from '../src/index.js';

const $ = (id) => document.getElementById(id);

/* ------------------------------------------------------------ formatting */

const money = (n, digits = 2) => n.toLocaleString(undefined, {
  minimumFractionDigits: digits, maximumFractionDigits: digits,
});
const percent = (n, digits = 2) => `${(n * 100).toFixed(digits)}%`;
const signed = (n, digits = 4) => (n >= 0 ? '+' : '') + n.toFixed(digits);

/** Reads a form into a plain object of numbers and strings. */
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

/* ------------------------------------------------------------ price mode */

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
    `${money(result.fairValue * multiplier)} per contract of ${money(multiplier, 0)}`;
  $('intrinsic').textContent = money(result.intrinsic);
  $('time-value').textContent = money(result.timeValue);
  $('break-even').textContent = money(result.breakEven);

  renderGreeks($('greeks'), result.greeks, multiplier);
  renderDiagnostics(result, contract, f);
  renderChart(contract, result);
}

const GREEK_META = [
  {
    key: 'delta', name: 'Delta', digits: 4,
    hint: 'value change per $1 move in the underlying',
  },
  {
    key: 'gamma', name: 'Gamma', digits: 4,
    hint: 'delta change per $1 move',
  },
  {
    key: 'vega', name: 'Vega', digits: 4,
    hint: 'per 1 point of volatility',
  },
  {
    key: 'theta', name: 'Theta', digits: 4,
    hint: 'per calendar day',
  },
  {
    key: 'rho', name: 'Rho', digits: 4,
    hint: 'per 1% change in rates',
  },
];

function renderGreeks(container, greeks, multiplier) {
  container.replaceChildren(...GREEK_META.map(({ key, name, digits, hint }) => {
    const value = greeks[key];
    const card = document.createElement('div');
    card.className = 'card';

    const label = document.createElement('div');
    label.className = 'card-name';
    label.append(name);

    const amount = document.createElement('div');
    amount.className = 'card-value';
    // Delta and theta carry a meaningful sign; gamma and vega do not.
    if (key === 'delta' || key === 'theta' || key === 'rho') {
      amount.classList.add(value >= 0 ? 'is-positive' : 'is-negative');
      amount.textContent = signed(value, digits);
    } else {
      amount.textContent = value.toFixed(digits);
    }

    const note = document.createElement('div');
    note.className = 'card-hint';
    note.textContent = multiplier > 1
      ? `${hint} · ${signed(value * multiplier, 2)} per contract`
      : hint;

    card.append(label, amount, note);
    return card;
  }));
}

function renderDiagnostics(result, contract, form) {
  const rows = [
    ['Moneyness', `${(result.moneyness * 100).toFixed(1)}% of strike`],
    ['Forward price', money(result.forward)],
    ['Chance of finishing in the money', percent(result.probabilities.itm, 1)],
    ['Chance of touching the strike', percent(result.probabilities.touch, 1)],
  ];

  if (result.style === 'american') {
    rows.push(['Value if European only', money(result.europeanValue, 4)]);
    rows.push(['Early-exercise premium', money(result.earlyExercisePremium, 4)]);
    rows.push([
      'Early exercise becomes optimal',
      result.earlyExerciseBoundary === null
        ? 'never'
        : `${form.type === 'put' ? 'below' : 'above'} ${money(result.earlyExerciseBoundary)}`,
    ]);
  } else {
    rows.push([
      'Put-call parity check',
      `${result.parityResidual.toExponential(1)} residual`,
    ]);
  }

  rows.push([
    'Model',
    result.style === 'american'
      ? '400-step binomial tree'
      : 'Black-Scholes-Merton (closed form)',
  ]);

  $('diagnostics').replaceChildren(...rows.map(([term, value]) => {
    const row = document.createElement('div');
    row.className = 'diag-row';
    const dt = document.createElement('dt');
    dt.textContent = term;
    const dd = document.createElement('dd');
    dd.textContent = value;
    row.append(dt, dd);
    return row;
  }));

  // Risk-neutral probabilities are routinely misread as forecasts.
  const caveat = document.createElement('p');
  caveat.className = 'diag-note';
  caveat.textContent =
    'Probabilities are risk-neutral: they describe what the price implies, ' +
    'not what the stock is expected to do.';
  $('diagnostics').append(caveat);
}

/* ----------------------------------------------------------------- chart */

const SVG_NS = 'http://www.w3.org/2000/svg';

function el(name, attributes = {}) {
  const node = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) {
    node.setAttribute(key, value);
  }
  return node;
}

function renderChart(contract, result) {
  const width = 640;
  const height = 320;
  const pad = { top: 14, right: 16, bottom: 34, left: 52 };

  // Show a range wide enough to see both wings without squashing the curve.
  const spread = Math.max(contract.spot, contract.strike) * 0.55;
  const centre = (contract.spot + contract.strike) / 2;
  const from = Math.max(centre - spread, contract.spot * 0.02);
  const to = centre + spread;

  const curve = valueCurve(contract, { from, to, points: 90 });
  const maxY = Math.max(...curve.map((p) => Math.max(p.value, p.payoff))) * 1.06 || 1;

  const x = (spot) => pad.left + ((spot - from) / (to - from)) * (width - pad.left - pad.right);
  const y = (value) => height - pad.bottom - (value / maxY) * (height - pad.top - pad.bottom);

  const svg = el('svg', {
    viewBox: `0 0 ${width} ${height}`,
    role: 'img',
    'aria-label': `Option value against underlying price, strike ${contract.strike}`,
  });

  // Gridlines and axis labels.
  const ticks = 5;
  for (let i = 0; i <= ticks; i++) {
    const value = (maxY * i) / ticks;
    const yy = y(value);
    svg.append(el('line', {
      x1: pad.left, x2: width - pad.right, y1: yy, y2: yy,
      stroke: 'var(--line)', 'stroke-width': 1,
    }));
    const text = el('text', {
      x: pad.left - 8, y: yy + 4, 'text-anchor': 'end',
      fill: 'var(--muted)', 'font-size': 11,
    });
    text.textContent = value.toFixed(maxY < 5 ? 2 : 0);
    svg.append(text);
  }

  for (let i = 0; i <= 4; i++) {
    const spot = from + ((to - from) * i) / 4;
    const text = el('text', {
      x: x(spot), y: height - pad.bottom + 18, 'text-anchor': 'middle',
      fill: 'var(--muted)', 'font-size': 11,
    });
    text.textContent = spot.toFixed(0);
    svg.append(text);
  }

  const path = (accessor, attributes) => {
    const d = curve
      .map((p, i) => `${i === 0 ? 'M' : 'L'}${x(p.spot).toFixed(2)},${y(accessor(p)).toFixed(2)}`)
      .join(' ');
    return el('path', { d, fill: 'none', 'stroke-linejoin': 'round', ...attributes });
  };

  svg.append(path((p) => p.payoff, {
    stroke: 'var(--payoff)', 'stroke-width': 1.75, 'stroke-dasharray': '5 4',
  }));
  svg.append(path((p) => p.value, { stroke: 'var(--accent)', 'stroke-width': 2.25 }));

  // Marker for where the underlying is trading now.
  svg.append(el('line', {
    x1: x(contract.spot), x2: x(contract.spot),
    y1: pad.top, y2: height - pad.bottom,
    stroke: 'var(--muted)', 'stroke-width': 1.5, 'stroke-dasharray': '3 3',
  }));
  svg.append(el('circle', {
    cx: x(contract.spot), cy: y(result.fairValue), r: 4.5,
    fill: 'var(--accent)', stroke: 'var(--surface)', 'stroke-width': 2,
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

  let bounds;
  try {
    bounds = priceBounds({ ...inputs, american });
    $('iv-floor').textContent = money(bounds.lower, 4);
    $('iv-ceiling').textContent = money(bounds.upper, 4);
  } catch {
    // Fall through: the solver reports the same problem with a better message.
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
  const greeks = american
    ? binomial.greeks({ ...withVol, american: true })
    : bs.greeks(withVol);
  renderGreeks($('implied-greeks'), greeks, 1);
}

/* --------------------------------------------------------- grant mode */

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
    `${money(result.grossValue)} across ${money(result.quantity, 0)} options, before forfeiture`;
  $('grant-vesting').textContent =
    `${money(result.expectedToVest, 0)} (${percent(result.retention, 1)})`;
  $('grant-expense').textContent = money(result.expectedExpense);
  $('grant-annual').textContent =
    result.annualExpense === null ? 'n/a' : money(result.annualExpense);
}

/* -------------------------------------------------------------- wiring */

const RENDERERS = {
  price: { form: priceForm, render: renderPrice },
  implied: { form: impliedForm, render: renderImplied },
  grant: { form: grantForm, render: renderGrant },
};

for (const { form, render } of Object.values(RENDERERS)) {
  form.addEventListener('input', render);
  form.addEventListener('submit', (event) => event.preventDefault());
}

for (const tab of document.querySelectorAll('.tab')) {
  tab.addEventListener('click', () => {
    const mode = tab.dataset.mode;
    for (const other of document.querySelectorAll('.tab')) {
      other.classList.toggle('is-active', other === tab);
    }
    for (const panel of document.querySelectorAll('[data-mode-panel]')) {
      panel.hidden = panel.dataset.modePanel !== mode;
    }
    RENDERERS[mode].render();
  });
}

$('theme').addEventListener('click', () => {
  const root = document.documentElement;
  root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
  // The chart reads its colours from CSS variables at build time, so it has
  // to be redrawn for the new theme to take effect.
  renderPrice();
});

renderPrice();
renderImplied();
renderGrant();
