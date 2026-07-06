/* Carbon Footprint Tracker — app logic. No dependencies, data in localStorage. */
'use strict';

/* ================= helpers ================= */
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const ACTIVITY_BY_ID = Object.fromEntries(ACTIVITIES.map((a) => [a.id, a]));
const CATEGORY_BY_ID = Object.fromEntries(CATEGORIES.map((c) => [c.id, c]));

function todayStr(offsetDays = 0) {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function fmtKg(kg, digits) {
  if (digits === undefined) digits = kg >= 100 ? 0 : kg >= 10 ? 1 : 2;
  return `${kg.toFixed(digits)} kg`;
}

function fmtQty(n) {
  return Number.isInteger(n) ? String(n) : String(Math.round(n * 100) / 100);
}

function niceDate(iso) {
  if (iso === todayStr()) return 'Today';
  if (iso === todayStr(-1)) return 'Yesterday';
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function catColor(catId) {
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const c = CATEGORY_BY_ID[catId];
  return dark ? c.colorDark : c.colorLight;
}

/* ================= storage & state ================= */
const LS_LOGS = 'cft:logs';
const LS_SETTINGS = 'cft:settings';

const state = {
  logs: [],
  settings: { gridPreset: 'india', gridIntensity: 0.71 },
  logDate: todayStr(),
  range: 1,
};

function loadState() {
  try {
    const logs = JSON.parse(localStorage.getItem(LS_LOGS));
    if (Array.isArray(logs)) state.logs = logs.filter((e) => e && ACTIVITY_BY_ID[e.activityId] && e.date && e.qty > 0);
  } catch (_) { /* corrupted storage — start fresh */ }
  try {
    const s = JSON.parse(localStorage.getItem(LS_SETTINGS));
    if (s && typeof s.gridIntensity === 'number' && s.gridIntensity >= 0) Object.assign(state.settings, s);
  } catch (_) { /* keep defaults */ }
}

function saveLogs() { localStorage.setItem(LS_LOGS, JSON.stringify(state.logs)); }
function saveSettings() { localStorage.setItem(LS_SETTINGS, JSON.stringify(state.settings)); }

/* ================= emissions engine ================= */
/* Returns { total, co2, ch4, n2o } in kg CO2e for a quantity of an activity. */
function emissionsFor(activityId, qty) {
  const a = ACTIVITY_BY_ID[activityId];
  if (!a || !(qty > 0)) return { total: 0, co2: 0, ch4: 0, n2o: 0 };
  const total = a.kwhPerUnit !== undefined
    ? qty * a.kwhPerUnit * state.settings.gridIntensity
    : qty * a.per;
  const split = GAS_SPLITS[a.split] || GAS_SPLITS.fuel;
  return { total, co2: total * split.co2, ch4: total * split.ch4, n2o: total * split.n2o };
}

function entryEmissions(entry) { return emissionsFor(entry.activityId, entry.qty); }

function entriesForDate(date) { return state.logs.filter((e) => e.date === date); }

function entriesInRange(days) {
  const from = todayStr(-(days - 1));
  const to = todayStr();
  return state.logs.filter((e) => e.date >= from && e.date <= to);
}

function sumEmissions(entries) {
  const acc = { total: 0, co2: 0, ch4: 0, n2o: 0 };
  for (const e of entries) {
    const em = entryEmissions(e);
    acc.total += em.total; acc.co2 += em.co2; acc.ch4 += em.ch4; acc.n2o += em.n2o;
  }
  return acc;
}

/* ================= tabs ================= */
function switchTab(name) {
  $$('.tab').forEach((b) => {
    const on = b.dataset.tab === name;
    b.classList.toggle('active', on);
    b.setAttribute('aria-selected', String(on));
  });
  $$('.tab-panel').forEach((p) => p.classList.toggle('active', p.id === `tab-${name}`));
  if (name === 'dashboard') renderDashboard();
  if (name === 'tips') renderTips();
}

/* ================= log tab ================= */
function populateLogSelects() {
  $('#log-category').innerHTML = CATEGORIES
    .map((c) => `<option value="${c.id}">${c.icon} ${esc(c.label)}</option>`).join('');
  populateActivitySelect();
}

function populateActivitySelect() {
  const cat = $('#log-category').value;
  $('#log-activity').innerHTML = ACTIVITIES.filter((a) => a.cat === cat)
    .map((a) => `<option value="${a.id}">${esc(a.label)}</option>`).join('');
  updateQtyLabel();
}

function updateQtyLabel() {
  const a = ACTIVITY_BY_ID[$('#log-activity').value];
  if (!a) return;
  $('#log-qty-label').textContent = `Amount (${a.unit})`;
  $('#log-qty').placeholder = a.unit;
  updatePreview();
}

function updatePreview() {
  const a = ACTIVITY_BY_ID[$('#log-activity').value];
  const qty = parseFloat($('#log-qty').value);
  const el = $('#log-preview');
  if (!a || !(qty > 0)) { el.textContent = ''; return; }
  const em = emissionsFor(a.id, qty);
  el.innerHTML = `${fmtQty(qty)} ${esc(a.unit)} of “${esc(a.label)}” ≈ <strong>${fmtKg(em.total)} CO₂e</strong>`;
}

function addEntry(ev) {
  ev.preventDefault();
  const activityId = $('#log-activity').value;
  const qty = parseFloat($('#log-qty').value);
  if (!ACTIVITY_BY_ID[activityId] || !(qty > 0)) return;
  state.logs.push({ id: Date.now() + Math.random().toString(16).slice(2), date: state.logDate, activityId, qty });
  saveLogs();
  $('#log-qty').value = '';
  updatePreview();
  renderDay();
}

function removeEntry(id) {
  state.logs = state.logs.filter((e) => e.id !== id);
  saveLogs();
  renderDay();
}

function renderDay() {
  const entries = entriesForDate(state.logDate);
  $('#day-title').textContent = niceDate(state.logDate);
  const total = sumEmissions(entries).total;
  $('#day-total').textContent = entries.length ? `${fmtKg(total)} CO₂e` : '';
  $('#day-empty').style.display = entries.length ? 'none' : 'block';

  $('#day-entries').innerHTML = entries.map((e) => {
    const a = ACTIVITY_BY_ID[e.activityId];
    const em = entryEmissions(e);
    return `<li>
      <span class="entry-dot" style="background:${catColor(a.cat)}"></span>
      <span class="entry-label">${esc(a.label)}</span>
      <span class="entry-qty">${fmtQty(e.qty)} ${esc(a.unit)}</span>
      <span class="entry-co2">${fmtKg(em.total)}</span>
      <button class="entry-del" data-id="${e.id}" aria-label="Delete ${esc(a.label)} entry" title="Delete">✕</button>
    </li>`;
  }).join('');
}

/* ================= dashboard ================= */
function renderDashboard() {
  const days = state.range;
  const entries = entriesInRange(days);
  const em = sumEmissions(entries);
  const perDay = em.total / days;

  $('#stat-total-label').textContent = days === 1 ? 'Total today' : `Total, last ${days} days`;
  $('#stat-total').textContent = `${fmtKg(em.total)} CO₂e`;
  $('#stat-total-sub').textContent = days === 1 ? '' : `≈ ${fmtKg(perDay)} per day`;

  const vsTarget = perDay / BENCHMARKS.sustainable;
  const vsWorld = perDay / BENCHMARKS.worldAvg;
  const tgt = $('#stat-target');
  tgt.textContent = `${Math.round(vsTarget * 100)}%`;
  tgt.className = 'stat-value ' + (vsTarget <= 1 ? 'good' : 'bad');
  const glb = $('#stat-global');
  glb.textContent = `${Math.round(vsWorld * 100)}%`;
  glb.className = 'stat-value ' + (vsWorld <= 1 ? 'good' : 'bad');

  renderDonut(entries, em.total);
  renderGasBar(em);
  renderTrend();
  renderTopTable(entries, em.total);
}

function categoryTotals(entries) {
  const totals = {};
  for (const e of entries) {
    const a = ACTIVITY_BY_ID[e.activityId];
    totals[a.cat] = (totals[a.cat] || 0) + entryEmissions(e).total;
  }
  return CATEGORIES.map((c) => ({ cat: c, value: totals[c.id] || 0 })).filter((d) => d.value > 0.0005);
}

function donutArc(cx, cy, r, a0, a1) {
  const p = (a) => [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  const [x0, y0] = p(a0); const [x1, y1] = p(a1);
  const large = a1 - a0 > Math.PI ? 1 : 0;
  return `M ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1}`;
}

function renderDonut(entries, total) {
  const box = $('#chart-donut');
  const data = categoryTotals(entries);
  if (!data.length) { box.innerHTML = '<p class="empty-note">No data in this range yet.</p>'; return; }

  const size = 240, cx = size / 2, cy = size / 2, r = 88, w = 26;
  const gap = data.length > 1 ? 0.035 : 0; // ~2px angular gap between segments
  let angle = -Math.PI / 2;
  let paths = '';
  for (const d of data) {
    const sweep = (d.value / total) * Math.PI * 2;
    const tipAttr = `data-tip="<strong>${esc(d.cat.label)}</strong>${fmtKg(d.value)} CO₂e · ${Math.round((d.value / total) * 100)}%"`;
    if (sweep >= Math.PI * 2 - 0.001) {
      paths += `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${catColor(d.cat.id)}" stroke-width="${w}" ${tipAttr}/>`;
    } else {
      const a0 = angle + gap / 2, a1 = Math.max(a0 + 0.01, angle + sweep - gap / 2);
      paths += `<path d="${donutArc(cx, cy, r, a0, a1)}" fill="none" stroke="${catColor(d.cat.id)}"
        stroke-width="${w}" stroke-linecap="butt" ${tipAttr}/>`;
    }
    angle += sweep;
  }
  box.innerHTML = `<svg viewBox="0 0 ${size} ${size}" role="img" aria-label="Emissions by category" style="max-width:${size}px;margin:0 auto">
      ${paths}
      <text x="${cx}" y="${cy - 4}" text-anchor="middle" class="hero-num" font-size="26">${total.toFixed(1)}</text>
      <text x="${cx}" y="${cy + 18}" text-anchor="middle" class="axis-label">kg CO₂e</text>
    </svg>
    <div class="legend">${data.map((d) => `<span class="legend-item"><span class="legend-swatch" style="background:${catColor(d.cat.id)}"></span>${esc(d.cat.label)} <span class="legend-value">${fmtKg(d.value)}</span></span>`).join('')}</div>`;
}

function renderGasBar(em) {
  const box = $('#chart-gases');
  if (em.total <= 0) { box.innerHTML = '<p class="empty-note">No data in this range yet.</p>'; return; }

  const css = getComputedStyle(document.documentElement);
  const gases = [
    { key: 'co2', label: 'CO₂', name: 'Carbon dioxide', value: em.co2, color: css.getPropertyValue('--gas-co2').trim() },
    { key: 'ch4', label: 'CH₄', name: 'Methane', value: em.ch4, color: css.getPropertyValue('--gas-ch4').trim() },
    { key: 'n2o', label: 'N₂O', name: 'Nitrous oxide', value: em.n2o, color: css.getPropertyValue('--gas-n2o').trim() },
  ].filter((g) => g.value > 0.0005);

  const W = 420, H = 64, barY = 8, barH = 28, gapPx = 2;
  let x = 0, segs = '', labels = '';
  gases.forEach((g, i) => {
    const wSeg = (g.value / em.total) * (W - gapPx * (gases.length - 1));
    const pct = Math.round((g.value / em.total) * 100);
    segs += `<rect x="${x}" y="${barY}" width="${Math.max(wSeg, 1)}" height="${barH}" rx="4" fill="${g.color}"
      data-tip="<strong>${g.name} (${g.label})</strong>${fmtKg(g.value)} CO₂e · ${pct}%"/>`;
    if (wSeg > 44) labels += `<text x="${x + wSeg / 2}" y="${barY + barH + 18}" text-anchor="middle" class="value-label">${g.label} ${pct}%</text>`;
    x += wSeg + gapPx;
  });
  box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Greenhouse gas mix">${segs}${labels}</svg>
    <div class="legend">${gases.map((g) => `<span class="legend-item"><span class="legend-swatch" style="background:${g.color}"></span>${g.name} (${g.label}) <span class="legend-value">${fmtKg(g.value)}</span></span>`).join('')}</div>
    <p class="card-note" style="margin-top:8px">Methane and nitrous oxide are far stronger warmers per kg than CO₂ — shown here as CO₂-equivalent. Big CH₄ share usually means red meat, rice or landfill waste.</p>`;
}

function renderTrend() {
  const box = $('#chart-trend');
  const DAYS = 14;
  const days = [];
  for (let i = DAYS - 1; i >= 0; i--) {
    const date = todayStr(-i);
    days.push({ date, total: sumEmissions(entriesForDate(date)).total });
  }
  if (days.every((d) => d.total === 0)) { box.innerHTML = '<p class="empty-note">Log a few days and your trend appears here.</p>'; return; }

  const W = 640, H = 220, padL = 36, padR = 8, padT = 16, padB = 28;
  const plotW = W - padL - padR, plotH = H - padT - padB;
  const maxVal = Math.max(BENCHMARKS.sustainable * 1.2, ...days.map((d) => d.total)) * 1.08;
  const y = (v) => padT + plotH - (v / maxVal) * plotH;
  const slot = plotW / DAYS, barW = Math.min(28, slot - 4);

  let grid = '', bars = '', ticks = '';
  const tickStep = maxVal > 20 ? 10 : maxVal > 8 ? 5 : 2;
  for (let v = 0; v <= maxVal; v += tickStep) {
    grid += `<line x1="${padL}" x2="${W - padR}" y1="${y(v)}" y2="${y(v)}" stroke="var(--grid-line)" stroke-width="1"/>`;
    ticks += `<text x="${padL - 6}" y="${y(v) + 4}" text-anchor="end" class="axis-label">${v}</text>`;
  }

  const best = Math.max(...days.map((d) => d.total));
  days.forEach((d, i) => {
    const cx = padL + slot * i + slot / 2;
    if (d.total > 0) {
      const top = y(d.total), h = Math.max(padT + plotH - top, 2);
      const r = Math.min(4, barW / 2, h);
      bars += `<path d="M ${cx - barW / 2} ${padT + plotH} V ${top + r} Q ${cx - barW / 2} ${top} ${cx - barW / 2 + r} ${top} H ${cx + barW / 2 - r} Q ${cx + barW / 2} ${top} ${cx + barW / 2} ${top + r} V ${padT + plotH} Z"
        fill="${d.total <= BENCHMARKS.sustainable ? 'var(--cat-water)' : 'var(--cat-transport)'}"
        data-tip="<strong>${niceDate(d.date)}</strong>${fmtKg(d.total)} CO₂e"/>`;
      if (d.total === best) bars += `<text x="${cx}" y="${top - 6}" text-anchor="middle" class="value-label">${d.total.toFixed(1)}</text>`;
    }
    const [, , dayNum] = d.date.split('-');
    if (i % 2 === (DAYS - 1) % 2) ticks += `<text x="${cx}" y="${H - 8}" text-anchor="middle" class="axis-label">${Number(dayNum)}</text>`;
  });

  const targetY = y(BENCHMARKS.sustainable);
  const target = `<line x1="${padL}" x2="${W - padR}" y1="${targetY}" y2="${targetY}" stroke="var(--good)" stroke-width="1.5" stroke-dasharray="5 4"/>
    <text x="${padL + 4}" y="${targetY - 5}" text-anchor="start" class="axis-label" fill="var(--good)">sustainable ≈ ${BENCHMARKS.sustainable} kg/day</text>`;

  box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Daily emissions, last 14 days">
    ${grid}
    <line x1="${padL}" x2="${W - padR}" y1="${padT + plotH}" y2="${padT + plotH}" stroke="var(--baseline)" stroke-width="1"/>
    ${bars}${target}${ticks}
  </svg>
  <div class="legend">
    <span class="legend-item"><span class="legend-swatch" style="background:var(--cat-water)"></span>at or under target</span>
    <span class="legend-item"><span class="legend-swatch" style="background:var(--cat-transport)"></span>over target</span>
  </div>`;
}

function renderTopTable(entries, total) {
  const tbody = $('#top-table tbody');
  const byActivity = {};
  for (const e of entries) {
    const rec = byActivity[e.activityId] || (byActivity[e.activityId] = { qty: 0, co2e: 0 });
    rec.qty += e.qty;
    rec.co2e += entryEmissions(e).total;
  }
  const rows = Object.entries(byActivity)
    .map(([id, r]) => ({ a: ACTIVITY_BY_ID[id], ...r }))
    .filter((r) => r.co2e > 0.0005)
    .sort((x, y) => y.co2e - x.co2e)
    .slice(0, 8);

  $('#dash-empty').style.display = rows.length ? 'none' : 'block';
  $('#top-table').style.display = rows.length ? '' : 'none';
  tbody.innerHTML = rows.map((r) => `<tr>
      <td><span class="entry-dot" style="display:inline-block;background:${catColor(r.a.cat)};margin-right:8px"></span>${esc(r.a.label)}</td>
      <td class="num">${fmtQty(r.qty)} ${esc(r.a.unit)}</td>
      <td class="num">${r.co2e.toFixed(2)}</td>
      <td class="num">${Math.round((r.co2e / total) * 100)}%</td>
    </tr>`).join('');
}

/* ================= tips / suggestions engine ================= */
function weeklyStats() {
  const entries = entriesInRange(7);
  const per = {};
  for (const e of entries) {
    const rec = per[e.activityId] || (per[e.activityId] = { qty: 0, co2e: 0 });
    rec.qty += e.qty;
    rec.co2e += entryEmissions(e).total;
  }
  return { entries, per, total: sumEmissions(entries).total };
}

function buildTips() {
  const { entries, per, total } = weeklyStats();
  const tips = [];
  const get = (id) => per[id] || { qty: 0, co2e: 0 };
  const gi = state.settings.gridIntensity;

  if (!entries.length) {
    tips.push({ icon: '📝', title: 'Start logging', body: 'Add a few days of activities and personalised suggestions will appear here.' });
    return tips;
  }

  const perDay = total / 7;
  if (perDay <= BENCHMARKS.sustainable) {
    tips.push({ icon: '🏆', title: 'You are under the sustainable target', body: `Averaging ${fmtKg(perDay)} CO₂e/day, below the ≈${BENCHMARKS.sustainable} kg target. Keep it up — and check the guide below for the last easy wins.` });
  }

  const ac = get('ac');
  if (ac.qty / 7 > MINIMAL_BASELINES.ac.qty) {
    const overHrs = ac.qty - MINIMAL_BASELINES.ac.qty * 7;
    tips.push({ icon: '❄️', title: 'Trim air-conditioner hours', body: `You averaged ${(ac.qty / 7).toFixed(1)} h/day of AC. Setting 26 °C, closing doors, and switching to a fan after the room cools typically keeps comfort at ~${MINIMAL_BASELINES.ac.qty} h/day.`, saving: overHrs * 1.5 * gi });
  }
  if (ac.qty > 0 && get('fan').qty < ac.qty) {
    tips.push({ icon: '🌀', title: 'Fan first, AC second', body: 'A ceiling fan uses about 5% of the electricity of an AC. Using the fan for the milder hours and AC only for peak heat is the single biggest cooling saving.', saving: Math.min(ac.qty, 2 * 7) * (1.5 - 0.075) * gi * 0.3 });
  }

  const heater = get('heater');
  if (heater.qty / 7 > MINIMAL_BASELINES.heater.qty) {
    tips.push({ icon: '🔥', title: 'Heat the person, not the house', body: `Space heating averaged ${(heater.qty / 7).toFixed(1)} h/day. A blanket, warm layers and heating only the occupied room usually gets this to ~${MINIMAL_BASELINES.heater.qty} h/day.`, saving: (heater.qty - MINIMAL_BASELINES.heater.qty * 7) * 1.8 * gi });
  }

  const geyser = get('geyser');
  if (geyser.qty / 7 > MINIMAL_BASELINES.geyser.qty) {
    tips.push({ icon: '🚿', title: 'Shorter geyser runs', body: `The water heater ran ${(geyser.qty / 7 * 60).toFixed(0)} min/day on average. ~15 minutes heats a bucket-bath's worth; switch it off before you step in.`, saving: (geyser.qty - MINIMAL_BASELINES.geyser.qty * 7) * 2.0 * gi });
  }

  const redMeat = get('meal_redmeat');
  if (redMeat.qty >= 3) {
    tips.push({ icon: '🥗', title: 'Swap some red-meat meals', body: `${fmtQty(redMeat.qty)} beef/mutton meals this week. Each swap to chicken saves ~3.7 kg CO₂e and to a vegetarian meal ~4.3 kg — the single biggest food lever.`, saving: (redMeat.qty - 2) * 4.3 });
  }

  const carKm = get('car_petrol').qty + get('car_diesel').qty;
  if (carKm / 7 > 10) {
    tips.push({ icon: '🚌', title: 'Shift short car trips', body: `You drove ~${Math.round(carKm / 7)} km/day. Moving half of that to bus or metro cuts those kilometres' emissions by 45–80%; cycling or walking trips under 2 km cuts them to zero.`, saving: (carKm / 2) * (0.192 - 0.07) });
  }

  const flights = get('flight_dom').co2e + get('flight_int').co2e;
  if (flights > 0) {
    tips.push({ icon: '✈️', title: 'Flights dominate this week', body: `Flying added ${fmtKg(flights)} CO₂e. For routes under ~700 km, an intercity train emits about 6× less. When you must fly, prefer non-stop economy.` });
  }

  const stream = get('stream');
  if (stream.qty / 7 > MINIMAL_BASELINES.stream.qty) {
    tips.push({ icon: '📺', title: 'Lighter streaming habits', body: `~${(stream.qty / 7).toFixed(1)} h/day of streaming. Dropping from 4K to HD on small screens cuts the footprint of each hour by more than half.`, saving: (stream.qty - MINIMAL_BASELINES.stream.qty * 7) * 0.03 });
  }

  const waste = get('waste');
  if (waste.qty / 7 > 0.5) {
    tips.push({ icon: '♻️', title: 'Divert waste from landfill', body: 'Landfilled organic waste rots into methane, a far stronger greenhouse gas. Composting kitchen scraps and segregating recyclables removes most of it.', saving: waste.co2e * 0.6 });
  }

  if (state.settings.gridIntensity >= 0.6) {
    tips.push({ icon: '☀️', title: 'Your grid is carbon-heavy', body: `At ${state.settings.gridIntensity} kg CO₂/kWh, every appliance-hour counts. If available, rooftop solar or a green-power tariff would cut your electricity emissions by ~90%.` });
  }

  if (tips.length <= 2) {
    tips.push({ icon: '💡', title: 'General wins', body: 'Biggest levers in order: fly less, drive less, eat less red meat, cool/heat efficiently. Log more activity types to get sharper, personalised suggestions.' });
  }

  return tips;
}

function renderTips() {
  const tips = buildTips();
  $('#tips-list').innerHTML = tips.map((t) => `<li>
      <span class="tip-icon">${t.icon}</span>
      <span class="tip-body"><strong>${esc(t.title)}</strong>${esc(t.body)}
        ${t.saving && t.saving > 0.05 ? `<br><span class="tip-saving">Potential saving ≈ ${fmtKg(t.saving)} CO₂e/week</span>` : ''}
      </span>
    </li>`).join('');
  renderBaselines();
}

function renderBaselines() {
  const { per } = weeklyStats();
  const rows = [];
  for (const [id, base] of Object.entries(MINIMAL_BASELINES)) {
    const rec = per[id];
    if (!rec || rec.qty <= 0) continue;
    const a = ACTIVITY_BY_ID[id];
    const avg = rec.qty / 7;
    const over = Math.max(0, avg - base.qty);
    const savingPerDay = emissionsFor(id, over).total;
    rows.push({ a, base, avg, savingPerDay });
  }
  rows.sort((x, y) => y.savingPerDay - x.savingPerDay);

  $('#baseline-empty').style.display = rows.length ? 'none' : 'block';
  $('#baseline-table').style.display = rows.length ? '' : 'none';
  $('#baseline-table tbody').innerHTML = rows.map((r) => `<tr>
      <td>${esc(r.a.label)}<br><span class="card-note" style="margin:0">${esc(r.base.note)}</span></td>
      <td class="num">${r.avg.toFixed(1)} ${esc(r.a.unit)}</td>
      <td class="num">${fmtQty(r.base.qty)} ${esc(r.a.unit)}</td>
      <td class="num">${r.savingPerDay > 0.005 ? `<span class="saving">−${fmtKg(r.savingPerDay)}</span>` : '<span class="card-note" style="margin:0">on track ✓</span>'}</td>
    </tr>`).join('');
}

/* ================= settings ================= */
function renderSettings() {
  $('#grid-preset').innerHTML = GRID_PRESETS
    .map((p) => `<option value="${p.id}" ${p.id === state.settings.gridPreset ? 'selected' : ''}>${esc(p.label)}</option>`).join('');
  $('#grid-custom').value = state.settings.gridIntensity;
}

function onGridPreset() {
  const preset = GRID_PRESETS.find((p) => p.id === $('#grid-preset').value);
  state.settings.gridPreset = preset.id;
  if (preset.value !== null) {
    state.settings.gridIntensity = preset.value;
    $('#grid-custom').value = preset.value;
  }
  saveSettings();
  renderDay();
}

function onGridCustom() {
  const v = parseFloat($('#grid-custom').value);
  if (!(v >= 0) || v > 5) return;
  state.settings.gridIntensity = v;
  state.settings.gridPreset = 'custom';
  $('#grid-preset').value = 'custom';
  saveSettings();
  renderDay();
}

function exportData() {
  const blob = new Blob([JSON.stringify({ logs: state.logs, settings: state.settings }, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `carbon-footprint-${todayStr()}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
}

function importData(file) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const data = JSON.parse(reader.result);
      if (!Array.isArray(data.logs)) throw new Error('bad file');
      state.logs = data.logs.filter((e) => e && ACTIVITY_BY_ID[e.activityId] && e.date && e.qty > 0);
      if (data.settings && typeof data.settings.gridIntensity === 'number') Object.assign(state.settings, data.settings);
      saveLogs(); saveSettings();
      renderSettings(); renderDay();
      alert(`Imported ${state.logs.length} entries.`);
    } catch (_) {
      alert('Could not read that file — expected a JSON export from this app.');
    }
  };
  reader.readAsText(file);
}

function clearData() {
  if (!confirm('Delete all logged data from this browser? This cannot be undone.')) return;
  state.logs = [];
  saveLogs();
  renderDay();
}

/* ================= tooltip ================= */
function setupTooltip() {
  const tip = $('#tooltip');
  const show = (target, x, y) => {
    tip.innerHTML = target.getAttribute('data-tip');
    tip.hidden = false;
    const half = tip.offsetWidth / 2 + 6;
    tip.style.left = `${Math.min(Math.max(x, half), window.innerWidth - half)}px`;
    tip.style.top = `${y}px`;
  };
  document.addEventListener('pointermove', (ev) => {
    const t = ev.target.closest && ev.target.closest('[data-tip]');
    if (t) show(t, ev.clientX, ev.clientY);
    else tip.hidden = true;
  });
  document.addEventListener('pointerdown', (ev) => {
    const t = ev.target.closest && ev.target.closest('[data-tip]');
    if (t) show(t, ev.clientX, ev.clientY);
  });
}

/* ================= wiring ================= */
function init() {
  loadState();

  $('#log-date').value = state.logDate;
  $('#log-date').max = todayStr();
  populateLogSelects();
  renderDay();
  renderSettings();
  setupTooltip();

  $$('.tab').forEach((b) => b.addEventListener('click', () => switchTab(b.dataset.tab)));
  $$('.range-btn').forEach((b) => b.addEventListener('click', () => {
    state.range = Number(b.dataset.range);
    $$('.range-btn').forEach((x) => x.classList.toggle('active', x === b));
    renderDashboard();
  }));

  $('#log-category').addEventListener('change', populateActivitySelect);
  $('#log-activity').addEventListener('change', updateQtyLabel);
  $('#log-qty').addEventListener('input', updatePreview);
  $('#log-form').addEventListener('submit', addEntry);
  $('#log-date').addEventListener('change', () => {
    state.logDate = $('#log-date').value || todayStr();
    renderDay();
  });
  $('#day-entries').addEventListener('click', (ev) => {
    const btn = ev.target.closest('.entry-del');
    if (btn) removeEntry(btn.dataset.id);
  });

  $('#grid-preset').addEventListener('change', onGridPreset);
  $('#grid-custom').addEventListener('change', onGridCustom);
  $('#btn-export').addEventListener('click', exportData);
  $('#btn-import').addEventListener('change', (ev) => { if (ev.target.files[0]) importData(ev.target.files[0]); ev.target.value = ''; });
  $('#btn-clear').addEventListener('click', clearData);

  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    renderDay();
    if ($('#tab-dashboard').classList.contains('active')) renderDashboard();
  });
}

document.addEventListener('DOMContentLoaded', init);
