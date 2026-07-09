/* Carbon Footprint Tracker — app logic. No dependencies.
 * Data lives in localStorage per account; with a cloud backend configured
 * (config.js) it is additionally backed up to the user's cloud account. */
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

function addDays(iso, n) {
  const [y, m, d] = iso.split('-').map(Number);
  const dt = new Date(y, m - 1, d + n);
  const p = (x) => String(x).padStart(2, '0');
  return `${dt.getFullYear()}-${p(dt.getMonth() + 1)}-${p(dt.getDate())}`;
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
  const forced = document.documentElement.dataset.theme;
  const dark = forced ? forced === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
  const c = CATEGORY_BY_ID[catId];
  return dark ? c.colorDark : c.colorLight;
}

/* ================= storage & state ================= */
const DEFAULT_SETTINGS = { country: 'CA', subdivision: '', gridIntensity: 0.191 };

/* Grid intensity for a country + optional province/state. */
function regionIntensity(country, subdivision) {
  const subs = GRID_SUBDIVISIONS[country];
  if (subdivision && subs) {
    const s = subs.find((x) => x.id === subdivision);
    if (s) return s.value;
  }
  const c = GRID_COUNTRIES.find((x) => x.id === country);
  return c ? c.value : 0.47;
}

/* Region chosen on the sign-up form, applied right after the account exists. */
let pendingRegion = null;

/* Password-reset token arriving via the emailed link's URL hash. */
function parseRecoveryHash() {
  if (!location.hash || !location.hash.includes('type=recovery')) return null;
  const p = new URLSearchParams(location.hash.slice(1));
  if (p.get('type') !== 'recovery' || !p.get('access_token')) return null;
  return {
    access_token: p.get('access_token'),
    refresh_token: p.get('refresh_token') || '',
    expires_in: Number(p.get('expires_in') || 3600),
  };
}

/* Error arriving via the hash (e.g. an expired reset link). */
function parseHashError() {
  if (!location.hash || !location.hash.includes('error')) return null;
  const p = new URLSearchParams(location.hash.slice(1));
  return p.get('error_description') || p.get('error') || null;
}

function clearHash() {
  history.replaceState(null, '', location.pathname + location.search);
}

const SAMPLE_DAY = [
  { a: 'bus', q: 8 }, { a: 'car_petrol', q: 5 }, { a: 'meal_veg', q: 2 },
  { a: 'rice', q: 1 }, { a: 'milk', q: 1 }, { a: 'coffee', q: 1 },
  { a: 'ac', q: 3 }, { a: 'fan', q: 8 }, { a: 'tv', q: 2 },
  { a: 'lights', q: 5 }, { a: 'geyser', q: 0.5 }, { a: 'lpg', q: 0.75 },
  { a: 'shower_hot', q: 1 }, { a: 'phone', q: 1 }, { a: 'stream', q: 1.5 },
];

const state = {
  user: null,            // active account: device account, or cloud session user
  logs: [],
  settings: { ...DEFAULT_SETTINGS },
  templates: [],
  logDate: todayStr(),
  range: 1,
  openEntry: null,
  backupStatus: 'ok',
  wired: false,
};

/* The signed-in identity: cloud session when a backend is configured,
 * otherwise a device account. null → the auth gate is shown. */
function activeUser() {
  if (Cloud.enabled()) {
    const s = Cloud.session();
    return s ? { id: 'c' + s.user.id, name: s.user.name, email: s.user.email, cloud: true } : null;
  }
  return Accounts.current();
}

/* Storage keys are namespaced per account. */
function dataKey(suffix) {
  return state.user ? `cft:u:${state.user.id}:${suffix}` : `cft:${suffix}`;
}

function loadState() {
  state.user = activeUser();
  state.logs = [];
  state.settings = { ...DEFAULT_SETTINGS };
  state.templates = [];
  try {
    const logs = JSON.parse(localStorage.getItem(dataKey('logs')));
    if (Array.isArray(logs)) state.logs = logs.filter((e) => e && ACTIVITY_BY_ID[e.activityId] && e.date && e.qty > 0);
  } catch (_) { /* corrupted storage — start fresh */ }
  try {
    const s = JSON.parse(localStorage.getItem(dataKey('settings')));
    if (s && typeof s.gridIntensity === 'number' && s.gridIntensity >= 0) Object.assign(state.settings, s);
  } catch (_) { /* keep defaults */ }
  /* Migrate settings saved before the country/subdivision picker existed. */
  if (!state.settings.country) {
    const OLD_PRESET_MAP = { canada: 'CA', us: 'US', uk: 'UNITED_KINGDOM', eu: 'OTHER', india: 'INDIA', world: 'OTHER', renew: 'OTHER', custom: 'OTHER' };
    state.settings.country = OLD_PRESET_MAP[state.settings.gridPreset] || 'CA';
    state.settings.subdivision = '';
    delete state.settings.gridPreset;
  }
  state.templates = lsGet(dataKey('templates'), []).filter((t) => t && t.name && Array.isArray(t.items));
}

function saveLogsLocal() { lsSet(dataKey('logs'), state.logs); }
function saveSettingsLocal() { lsSet(dataKey('settings'), state.settings); }
function saveTemplatesLocal() { lsSet(dataKey('templates'), state.templates); }
function saveLogs() { saveLogsLocal(); scheduleBackup(); }
function saveSettings() { saveSettingsLocal(); scheduleBackup(); }
function saveTemplates() { saveTemplatesLocal(); scheduleBackup(); }

/* ================= cloud backup ================= */
let backupTimer = null;

function backupPayload() {
  return { logs: state.logs, settings: state.settings, templates: state.templates, savedAt: new Date().toISOString() };
}

function scheduleBackup() {
  if (!state.user || !state.user.cloud) return;
  setBackupStatus('pending');
  clearTimeout(backupTimer);
  backupTimer = setTimeout(pushBackup, 2500);
}

async function pushBackup() {
  if (!state.user || !state.user.cloud) return;
  try {
    await Cloud.backup(backupPayload());
    lsSet(dataKey('lastBackup'), new Date().toISOString());
    setBackupStatus('ok');
  } catch (_) {
    setBackupStatus('fail');
  }
}

function setBackupStatus(s) {
  state.backupStatus = s;
  renderBackupStatus();
}

function renderBackupStatus() {
  const el = $('#backup-status');
  if (!el) return;
  const last = lsGet(dataKey('lastBackup'), null);
  const lastTxt = last
    ? new Date(last).toLocaleString([], { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
    : 'never';
  el.textContent = state.backupStatus === 'pending' ? '☁️ Backing up…'
    : state.backupStatus === 'fail' ? `⚠️ Couldn't reach the cloud — last backup: ${lastTxt}. Retries automatically.`
    : `☁️ Backed up to your cloud account · ${lastTxt}`;
}

function applyBackup(p) {
  state.logs = (p.logs || []).filter((e) => e && ACTIVITY_BY_ID[e.activityId] && e.date && e.qty > 0);
  if (p.settings && typeof p.settings.gridIntensity === 'number') state.settings = { ...DEFAULT_SETTINGS, ...p.settings };
  state.templates = Array.isArray(p.templates) ? p.templates.filter((t) => t && t.name && Array.isArray(t.items)) : [];
  saveLogsLocal(); saveSettingsLocal(); saveTemplatesLocal();
  renderSettings();
  renderDay();
}

/* On sign-in: restore from cloud when this device has nothing yet;
 * otherwise make sure a first backup exists. */
async function cloudAfterLogin() {
  try {
    const remote = await Cloud.fetchBackup();
    if (remote && remote.payload && Array.isArray(remote.payload.logs)
        && remote.payload.logs.length && state.logs.length === 0) {
      applyBackup(remote.payload);
    } else if (!remote) {
      await pushBackup();
    }
    setBackupStatus('ok');
  } catch (_) {
    setBackupStatus('fail');
  }
}

/* ================= auth gate ================= */
let recoveryToken = null; // set when the app is opened from a reset link

function renderGate(view) {
  document.body.classList.add('gated');
  $('#auth-gate').hidden = false;
  const cloud = Cloud.enabled();
  const users = cloud ? [] : Accounts.list();
  if (!view) view = (cloud || users.length) ? 'signin' : 'signup';

  $('#gate-title').textContent = view === 'reset' ? 'Choose a new password 🔑'
    : view === 'signup' ? 'Create your free account 🌱' : 'Welcome back 🌱';
  $('#gate-note').textContent = view === 'reset'
    ? 'You followed a password-reset link. Set a new password below — you’ll be signed in right after.'
    : cloud
      ? (view === 'signup'
        ? 'Sign up with your email — your data is saved on this device and backed up to the cloud, so you never lose it.'
        : 'Sign in with your email. If this is a new device, your data is restored from your cloud backup.')
      : (view === 'signup'
        ? 'Your account keeps your logs in their own space on this device.'
        : 'Sign in to your account on this device.');

  if (view === 'reset') {
    $('#gate-form').innerHTML = `<div class="gate-form">
      <div class="field"><label for="gate-pass">New password (8+ chars, letters, numbers &amp; a symbol)</label>
        <input id="gate-pass" type="password" autocomplete="new-password"></div>
      <div class="field"><label for="gate-pass2">Confirm new password</label>
        <input id="gate-pass2" type="password" autocomplete="new-password"></div>
      <button id="gate-submit" class="btn-primary">Set new password &amp; sign in</button>
    </div>`;
    $('#gate-msg').textContent = '';
    $('#gate-msg').className = 'account-msg';
    $('#gate-switch').innerHTML = '';
    $('#gate-submit').addEventListener('click', () => submitGate('reset', true));
    $('#gate-form').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') $('#gate-submit').click(); });
    return;
  }

  const form = $('#gate-form');
  if (view === 'signup') {
    form.innerHTML = `<div class="gate-form">
      <div class="field"><label for="gate-name">Name</label>
        <input id="gate-name" type="text" autocomplete="name" placeholder="Your name"></div>
      <div class="field"><label for="gate-email">Email</label>
        <input id="gate-email" type="email" autocomplete="email" placeholder="you@example.com"></div>
      <div class="field"><label for="gate-country">Country of residence</label>
        <select id="gate-country">${GRID_COUNTRIES.filter((c) => c.id !== 'OTHER').map((c) => `<option value="${c.id}" ${c.id === 'CA' ? 'selected' : ''}>${esc(c.label)}</option>`).join('')}<option value="OTHER">Other / not listed</option></select></div>
      <div class="field" id="gate-subdiv-field"><label for="gate-subdiv" id="gate-subdiv-label">Province</label>
        <select id="gate-subdiv"></select></div>
      <div class="field"><label for="gate-pass">Password (8+ chars, letters, numbers &amp; a symbol)</label>
        <input id="gate-pass" type="password" autocomplete="new-password"></div>
      <div class="field"><label for="gate-pass2">Confirm password</label>
        <input id="gate-pass2" type="password" autocomplete="new-password"></div>
      <button id="gate-submit" class="btn-primary">Create free account</button>
    </div>`;
    const syncSubdiv = () => {
      const country = $('#gate-country').value;
      const subs = GRID_SUBDIVISIONS[country];
      $('#gate-subdiv-field').style.display = subs ? '' : 'none';
      if (subs) {
        $('#gate-subdiv-label').textContent = country === 'CA' ? 'Province / territory' : 'State';
        $('#gate-subdiv').innerHTML = '<option value="">Not sure — national average</option>'
          + subs.map((s) => `<option value="${s.id}">${esc(s.label)}</option>`).join('');
      }
    };
    $('#gate-country').addEventListener('change', syncSubdiv);
    syncSubdiv();
  } else if (cloud) {
    form.innerHTML = `<div class="gate-form">
      <div class="field"><label for="gate-email">Email</label>
        <input id="gate-email" type="email" autocomplete="email" placeholder="you@example.com"></div>
      <div class="field"><label for="gate-pass">Password</label>
        <input id="gate-pass" type="password" autocomplete="current-password"></div>
      <button id="gate-submit" class="btn-primary">Sign in</button>
      <p class="card-note" style="margin:0"><button class="gate-link" id="gate-forgot" type="button">Forgot password?</button></p>
    </div>`;
    const last = lsGet('cft:lastEmail', '');
    if (last) $('#gate-email').value = last;
    $('#gate-forgot').addEventListener('click', async () => {
      const msg = (t, err) => { const el = $('#gate-msg'); el.textContent = t || ''; el.className = 'account-msg' + (err ? ' error' : ''); };
      const email = $('#gate-email').value.trim();
      if (!/.+@.+\..+/.test(email)) { msg('Type your email in the box above first, then tap "Forgot password?" again.', true); return; }
      try {
        await Cloud.requestPasswordReset(email);
        msg(`If an account exists for ${email}, a password-reset email is on its way — open the link on this device.`);
      } catch (_) {
        msg('Could not reach the server — check your connection and try again.', true);
      }
    });
  } else if (users.length) {
    form.innerHTML = `<div class="gate-form">
      <div class="field"><label for="gate-user">Account</label>
        <select id="gate-user">${users.map((u) => `<option value="${u.id}">${esc(u.name)}${u.email ? ` — ${esc(u.email)}` : ''}</option>`).join('')}</select></div>
      <div class="field"><label for="gate-pass">Password</label>
        <input id="gate-pass" type="password" autocomplete="current-password"></div>
      <button id="gate-submit" class="btn-primary">Sign in</button>
    </div>`;
  } else {
    /* Device mode with no accounts in this browser's storage: nothing to
     * sign in to — explain instead of hiding the option. */
    form.innerHTML = `<p class="card-note">No account exists in this browser yet — accounts live in the browser's storage in device mode. If you had one here before, the browser's site data was cleared (the claude.ai preview does this between visits). Create an account below; on a real host you stay signed in between visits.</p>`;
  }

  $('#gate-msg').textContent = '';
  $('#gate-msg').className = 'account-msg';
  $('#gate-switch').innerHTML = view === 'signup'
    ? 'Already have an account? <button class="gate-link" id="gate-toggle" type="button">Sign in</button>'
    : 'New here? <button class="gate-link" id="gate-toggle" type="button">Create a free account</button>';

  const toggle = $('#gate-toggle');
  if (toggle) toggle.addEventListener('click', () => renderGate(view === 'signup' ? 'signin' : 'signup'));
  const submit = $('#gate-submit');
  if (submit) submit.addEventListener('click', () => submitGate(view, cloud));
  form.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' && $('#gate-submit')) $('#gate-submit').click(); });
}

async function submitGate(view, cloud) {
  const msg = (t, err) => { const el = $('#gate-msg'); el.textContent = t || ''; el.className = 'account-msg' + (err ? ' error' : ''); };
  const btn = $('#gate-submit');
  btn.disabled = true;
  try {
    if (view === 'reset') {
      const pass = $('#gate-pass').value;
      const problem = passwordProblem(pass);
      if (problem) throw new Error(problem);
      if (pass !== $('#gate-pass2').value) throw new Error('The two passwords don’t match.');
      if (!recoveryToken) throw new Error('This reset link has expired — request a new one from the sign-in page.');
      await Cloud.completePasswordReset(recoveryToken, pass);
      recoveryToken = null;
      clearHash();
      init();
      return;
    }
    if (view === 'signup') {
      const name = $('#gate-name').value.trim();
      const email = $('#gate-email').value.trim();
      const pass = $('#gate-pass').value;
      if (!name) throw new Error('Please enter a name.');
      if (!/.+@.+\..+/.test(email)) throw new Error('Please enter a valid email address.');
      const problem = passwordProblem(pass);
      if (problem) throw new Error(problem);
      if (pass !== $('#gate-pass2').value) throw new Error('The two passwords don’t match.');
      pendingRegion = { country: $('#gate-country').value, subdivision: $('#gate-subdiv') ? $('#gate-subdiv').value : '' };
      if (cloud) {
        const res = await Cloud.signUp(name, email, pass);
        lsSet('cft:lastEmail', email);
        if (!res.confirmed) {
          msg('Almost there — open the confirmation link we emailed you, then sign in here.');
          btn.disabled = false;
          return;
        }
      } else {
        await Accounts.create(name, pass, email);
      }
    } else if (cloud) {
      const email = $('#gate-email').value.trim();
      await Cloud.signIn(email, $('#gate-pass').value);
      lsSet('cft:lastEmail', email);
    } else {
      const ok = await Accounts.login($('#gate-user').value, $('#gate-pass').value);
      if (!ok) throw new Error('Wrong password — try again.');
    }
    init();
  } catch (err) {
    msg(err.message, true);
    btn.disabled = false;
  }
}

/* ================= emissions engine ================= */
function useFactor(a) {
  if (a.useKwh !== undefined) return a.useKwh * state.settings.gridIntensity;
  return a.usePer || 0;
}

function embFactor(a) { return a.embPer || 0; }

function embSplitOf(a) {
  if (a.embSplit) return GAS_SPLITS[a.embSplit];
  if (a.cat === 'food') return GAS_SPLITS[a.split];
  return GAS_SPLITS.industry;
}

function emissionsFor(activityId, qty) {
  const a = ACTIVITY_BY_ID[activityId];
  if (!a || !(qty > 0)) return { total: 0, use: 0, emb: 0, co2: 0, ch4: 0, n2o: 0 };
  const use = qty * useFactor(a);
  const emb = qty * embFactor(a);
  const sU = GAS_SPLITS[a.split] || GAS_SPLITS.fuel;
  const sE = embSplitOf(a);
  return {
    total: use + emb, use, emb,
    co2: use * sU.co2 + emb * sE.co2,
    ch4: use * sU.ch4 + emb * sE.ch4,
    n2o: use * sU.n2o + emb * sE.n2o,
  };
}

function entryEmissions(entry) { return emissionsFor(entry.activityId, entry.qty); }

function entriesForDate(date) { return state.logs.filter((e) => e.date === date); }

function entriesInRange(days) {
  const from = todayStr(-(days - 1));
  const to = todayStr();
  return state.logs.filter((e) => e.date >= from && e.date <= to);
}

function sumEmissions(entries) {
  const acc = { total: 0, use: 0, emb: 0, co2: 0, ch4: 0, n2o: 0 };
  for (const e of entries) {
    const em = entryEmissions(e);
    for (const k of Object.keys(acc)) acc[k] += em[k];
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
  if (name === 'data') renderData();
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

function addEntryDirect(activityId, qty) {
  if (!ACTIVITY_BY_ID[activityId] || !(qty > 0)) return;
  state.logs.push({ id: Date.now() + Math.random().toString(16).slice(2), date: state.logDate, activityId, qty });
  saveLogs();
  renderDay();
}

function addEntry(ev) {
  ev.preventDefault();
  addEntryDirect($('#log-activity').value, parseFloat($('#log-qty').value));
  $('#log-qty').value = '';
  updatePreview();
}

function removeEntry(id) {
  state.logs = state.logs.filter((e) => e.id !== id);
  saveLogs();
  renderDay();
}

/* ---- welcome (first run) ---- */
function renderWelcome() {
  const card = $('#welcome-card');
  card.hidden = !(state.logs.length === 0 && !lsGet('cft:welcomed', false));
}

function dismissWelcome(loadSample) {
  lsSet('cft:welcomed', true);
  if (loadSample) {
    for (const s of SAMPLE_DAY) {
      state.logs.push({ id: Date.now() + Math.random().toString(16).slice(2), date: todayStr(), activityId: s.a, qty: s.q });
    }
    saveLogs();
  }
  renderDay();
}

/* ---- quick log: favorites, copy yesterday, templates ---- */
function quickFavorites() {
  const cutoff = todayStr(-30);
  const freq = {};
  const lastQty = {};
  for (const e of state.logs) {
    if (e.date >= cutoff) freq[e.activityId] = (freq[e.activityId] || 0) + 1;
    lastQty[e.activityId] = e.qty;
  }
  return Object.keys(freq)
    .sort((a, b) => freq[b] - freq[a])
    .slice(0, 6)
    .map((id) => ({ a: ACTIVITY_BY_ID[id], qty: lastQty[id] }));
}

function renderQuickLog() {
  const favs = quickFavorites();
  const prevDate = addDays(state.logDate, -1);
  const prevCount = entriesForDate(prevDate).length;
  const dayCount = entriesForDate(state.logDate).length;
  const hasTemplates = state.templates.length > 0;

  $('#quick-card').hidden = !(favs.length || hasTemplates || prevCount || dayCount);

  const repeat = $('#btn-repeat');
  repeat.hidden = !prevCount;
  repeat.textContent = `⟳ Copy ${prevDate === todayStr(-1) ? 'yesterday' : niceDate(prevDate)} (${prevCount})`;

  $('#quick-chips').innerHTML = favs.map((f) => {
    const short = f.a.label.replace(/\s*\(.*\)$/, '');
    return `<button class="chip" type="button" data-act="${f.a.id}" data-qty="${f.qty}"
      title="Add ${fmtQty(f.qty)} ${esc(f.a.unit)} of ${esc(f.a.label)}">
      ${CATEGORY_BY_ID[f.a.cat].icon} ${esc(short)} <span class="chip-qty">+${fmtQty(f.qty)} ${esc(f.a.unit)}</span></button>`;
  }).join('');

  $('#tmpl-row').style.display = hasTemplates ? '' : 'none';
  if (hasTemplates) {
    $('#tmpl-select').innerHTML = state.templates
      .map((t) => `<option value="${t.id}">${esc(t.name)} (${t.items.length} items)</option>`).join('');
  }
  $('#tmpl-save-row').hidden = !dayCount;
}

function copyPreviousDay() {
  const prev = entriesForDate(addDays(state.logDate, -1));
  for (const e of prev) {
    state.logs.push({ id: Date.now() + Math.random().toString(16).slice(2), date: state.logDate, activityId: e.activityId, qty: e.qty });
  }
  if (prev.length) { saveLogs(); renderDay(); }
}

function saveDayTemplate() {
  const items = entriesForDate(state.logDate).map((e) => ({ activityId: e.activityId, qty: e.qty }));
  if (!items.length) return;
  const name = ($('#tmpl-name').value || '').trim() || `Day of ${niceDate(state.logDate)}`;
  state.templates.push({ id: 't' + Date.now().toString(36), name, items });
  saveTemplates();
  $('#tmpl-name').value = '';
  renderQuickLog();
}

function applyTemplate() {
  const t = state.templates.find((x) => x.id === $('#tmpl-select').value);
  if (!t) return;
  for (const it of t.items) {
    if (ACTIVITY_BY_ID[it.activityId] && it.qty > 0) {
      state.logs.push({ id: Date.now() + Math.random().toString(16).slice(2), date: state.logDate, activityId: it.activityId, qty: it.qty });
    }
  }
  saveLogs();
  renderDay();
}

function deleteTemplate() {
  state.templates = state.templates.filter((x) => x.id !== $('#tmpl-select').value);
  saveTemplates();
  renderQuickLog();
}

/* ---- entry list with expandable detail & inline edit ---- */
function factorMath(a, qty, phase) {
  if (phase === 'use') {
    if (a.useKwh !== undefined) {
      return `${fmtQty(qty)} ${esc(a.unit)} × ${a.useKwh} kWh × ${state.settings.gridIntensity} kg/kWh (your grid)`;
    }
    return `${fmtQty(qty)} ${esc(a.unit)} × ${a.usePer} kg CO₂e/${esc(a.unit.replace(/s$/, ''))}`;
  }
  return `${fmtQty(qty)} ${esc(a.unit)} × ${a.embPer} kg CO₂e/${esc(a.unit.replace(/s$/, ''))}`;
}

function entryDetailHTML(e) {
  const a = ACTIVITY_BY_ID[e.activityId];
  const em = entryEmissions(e);
  const rows = [];
  if (em.use > 0 || (!a.embPer && !em.emb)) {
    const src = SOURCES[a.srcUse];
    rows.push(`<div class="detail-row">
      <span class="detail-phase">⚡ Operation${a.estUse ? ' <span class="badge-est">estimate</span>' : ''}</span>
      <span class="detail-math">${factorMath(a, e.qty, 'use')}</span>
      <span class="detail-val">${fmtKg(em.use)}</span>
    </div>${src ? `<p class="detail-src">Source: ${esc(src.short)}</p>` : ''}`);
  }
  if (em.emb > 0) {
    const src = SOURCES[a.srcEmb];
    rows.push(`<div class="detail-row">
      <span class="detail-phase">🏭 ${a.cat === 'food' ? 'Production & supply chain' : 'Manufacturing (amortised)'}${a.estEmb ? ' <span class="badge-est">estimate</span>' : ''}</span>
      <span class="detail-math">${factorMath(a, e.qty, 'emb')}</span>
      <span class="detail-val">${fmtKg(em.emb)}</span>
    </div>${a.embNote ? `<p class="detail-src">${esc(a.embNote)}</p>` : ''}${src ? `<p class="detail-src">Source: ${esc(src.short)}</p>` : ''}`);
  }
  return `<div class="entry-detail">
    ${rows.join('')}
    <div class="detail-gases">
      <span>Gases (as CO₂e):</span>
      <span>CO₂ <strong>${fmtKg(em.co2)}</strong></span>
      <span>CH₄ <strong>${fmtKg(em.ch4)}</strong></span>
      <span>N₂O <strong>${fmtKg(em.n2o)}</strong></span>
    </div>
    <div class="detail-edit">
      <label for="edit-${e.id}">Change amount (${esc(a.unit)}):</label>
      <input type="number" id="edit-${e.id}" value="${e.qty}" min="0" step="any">
      <button class="btn-secondary btn-small entry-update" type="button" data-id="${e.id}">Save</button>
    </div>
    <p class="detail-src">Full factor table and citations are in the Data tab.</p>
  </div>`;
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
    const open = state.openEntry === e.id;
    return `<li class="${open ? 'open' : ''}" data-entry="${e.id}">
      <div class="entry-row" role="button" tabindex="0" aria-expanded="${open}">
        <span class="entry-dot" style="background:${catColor(a.cat)}"></span>
        <span class="entry-label">${esc(a.label)}</span>
        <span class="entry-qty">${fmtQty(e.qty)} ${esc(a.unit)}</span>
        <span class="entry-co2">${fmtKg(em.total)}</span>
        <span class="entry-chevron" aria-hidden="true">${open ? '▾' : '▸'}</span>
        <button class="entry-del" data-id="${e.id}" aria-label="Delete ${esc(a.label)} entry" title="Delete">✕</button>
      </div>
      ${open ? entryDetailHTML(e) : ''}
    </li>`;
  }).join('');

  renderWelcome();
  renderQuickLog();
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
  renderPhaseBar(em);
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
  const gap = data.length > 1 ? 0.035 : 0;
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

function stackedBarSVG(parts, total, ariaLabel) {
  const W = 420, H = 64, barY = 8, barH = 28, gapPx = 2;
  let x = 0, segs = '', labels = '';
  parts.forEach((p) => {
    const wSeg = (p.value / total) * (W - gapPx * (parts.length - 1));
    const pct = Math.round((p.value / total) * 100);
    segs += `<rect x="${x}" y="${barY}" width="${Math.max(wSeg, 1)}" height="${barH}" rx="4" fill="${p.color}"
      data-tip="<strong>${esc(p.name)}</strong>${fmtKg(p.value)} CO₂e · ${pct}%"/>`;
    if (wSeg > 60) labels += `<text x="${x + wSeg / 2}" y="${barY + barH + 18}" text-anchor="middle" class="value-label">${esc(p.label)} ${pct}%</text>`;
    x += wSeg + gapPx;
  });
  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(ariaLabel)}">${segs}${labels}</svg>
    <div class="legend">${parts.map((p) => `<span class="legend-item"><span class="legend-swatch" style="background:${p.color}"></span>${esc(p.name)} <span class="legend-value">${fmtKg(p.value)}</span></span>`).join('')}</div>`;
}

function renderGasBar(em) {
  const box = $('#chart-gases');
  if (em.total <= 0) { box.innerHTML = '<p class="empty-note">No data in this range yet.</p>'; return; }
  const css = getComputedStyle(document.documentElement);
  const gases = [
    { label: 'CO₂', name: 'Carbon dioxide (CO₂)', value: em.co2, color: css.getPropertyValue('--gas-co2').trim() },
    { label: 'CH₄', name: 'Methane (CH₄)', value: em.ch4, color: css.getPropertyValue('--gas-ch4').trim() },
    { label: 'N₂O', name: 'Nitrous oxide (N₂O)', value: em.n2o, color: css.getPropertyValue('--gas-n2o').trim() },
  ].filter((g) => g.value > 0.0005);
  box.innerHTML = stackedBarSVG(gases, em.total, 'Greenhouse gas mix')
    + '<p class="card-note" style="margin-top:8px">Methane and nitrous oxide are far stronger warmers per kg than CO₂ — shown here as CO₂-equivalent. Big CH₄ share usually means red meat, rice or landfill waste.</p>';
}

function renderPhaseBar(em) {
  const box = $('#chart-phase');
  if (em.total <= 0) { box.innerHTML = '<p class="empty-note">No data in this range yet.</p>'; return; }
  const css = getComputedStyle(document.documentElement);
  const parts = [
    { label: 'Operation', name: 'Operation (fuel & electricity)', value: em.use, color: css.getPropertyValue('--cat-transport').trim() },
    { label: 'Embodied', name: 'Manufacturing & supply chain', value: em.emb, color: css.getPropertyValue('--cat-home').trim() },
  ].filter((p) => p.value > 0.0005);
  box.innerHTML = stackedBarSVG(parts, em.total, 'Operation vs embodied emissions')
    + '<p class="card-note" style="margin-top:8px">“Manufacturing & supply chain” is the footprint of making the things you use — a share of your car, AC or phone per use, and the full farm-to-shop footprint of food.</p>';
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

/* ================= data tab ================= */
function factorCellHTML(a, phase) {
  const unit1 = a.unit.replace(/s$/, '');
  if (phase === 'use') {
    if (a.useKwh !== undefined) {
      const val = a.useKwh * state.settings.gridIntensity;
      return `${a.estUse ? '≈' : ''}${val.toFixed(3)} kg/${esc(unit1)}<br><span class="cell-note">${a.useKwh} kWh × your grid (${state.settings.gridIntensity})</span>`;
    }
    if (!a.usePer) return '<span class="cell-note">—</span>';
    return `${a.estUse ? '≈' : ''}${a.usePer} kg/${esc(unit1)}`;
  }
  if (!a.embPer) return '<span class="cell-note">—</span>';
  return `${a.estEmb ? '≈' : ''}${a.embPer} kg/${esc(unit1)}${a.embNote ? `<br><span class="cell-note">${esc(a.embNote)}</span>` : ''}`;
}

function sourceLinkHTML(srcId) {
  const s = SOURCES[srcId];
  if (!s) return '';
  const href = s.url === 'SOURCES.md'
    ? 'https://github.com/jaivik-2612/vscode_remote/blob/main/carbon-tracker/SOURCES.md'
    : s.url;
  return `<a href="${href}" target="_blank" rel="noopener" title="${esc(s.label)}">${esc(s.short)}</a>`;
}

function renderData() {
  const box = $('#data-tables');
  let html = '';
  for (const c of CATEGORIES) {
    const acts = ACTIVITIES.filter((a) => a.cat === c.id);
    html += `<div class="card">
      <h2>${c.icon} ${esc(c.label)}</h2>
      <div class="chart-box"><table class="data-table">
        <thead><tr><th>Activity</th><th>Operation</th><th>${c.id === 'food' ? 'Production & supply chain' : 'Manufacturing (amortised)'}</th><th>Source</th></tr></thead>
        <tbody>${acts.map((a) => `<tr>
          <td>${esc(a.label)}<br><span class="cell-note">per ${esc(a.unit.replace(/s$/, ''))}</span></td>
          <td>${factorCellHTML(a, 'use')}</td>
          <td>${factorCellHTML(a, 'emb')}</td>
          <td class="src-cell">${[a.srcUse, a.srcEmb].filter(Boolean).filter((v, i, arr) => arr.indexOf(v) === i).map(sourceLinkHTML).join('<br>')}</td>
        </tr>`).join('')}</tbody>
      </table></div>
    </div>`;
  }

  const gridTable = (rows) => `<div class="chart-box grid-table"><table class="data-table">
      <thead><tr><th>Region</th><th class="num">kg CO₂/kWh</th></tr></thead>
      <tbody>${rows.map((r) => `<tr><td>${esc(r.label)}</td><td class="num">${r.value}</td></tr>`).join('')}</tbody>
    </table></div>`;
  html += `<div class="card">
    <h2>⚡ Electricity grid intensity (kg CO₂/kWh)</h2>
    <p class="card-note">Applied to every electric activity. You are currently using <strong>${state.settings.gridIntensity}</strong> — change your country/province in Settings.</p>
    <h3 class="data-subhead">Canadian provinces &amp; territories <span class="cell-note">(${sourceLinkHTML('eccc_nir')})</span></h3>
    ${gridTable(GRID_SUBDIVISIONS.CA)}
    <h3 class="data-subhead">US states <span class="cell-note">(${sourceLinkHTML('epa_egrid')})</span></h3>
    ${gridTable(GRID_SUBDIVISIONS.US)}
    <h3 class="data-subhead">Countries <span class="cell-note">(${sourceLinkHTML('ember')}, latest year)</span></h3>
    ${gridTable(GRID_COUNTRIES)}
  </div>
  <div class="card">
    <h2>🎯 Benchmarks</h2>
    <div class="chart-box"><table class="data-table">
      <thead><tr><th>Benchmark</th><th class="num">kg CO₂e/day</th><th>Basis</th></tr></thead>
      <tbody>
        <tr><td>Sustainable personal target</td><td class="num">${BENCHMARKS.sustainable}</td><td>≈2 t CO₂e/person/year, a widely used Paris-aligned target</td></tr>
        <tr><td>World average</td><td class="num">${BENCHMARKS.worldAvg}</td><td>≈4.7 t fossil CO₂/person/year (Global Carbon Budget) ÷ 365</td></tr>
        <tr><td>Canada / US average</td><td class="num">${BENCHMARKS.naAvg}</td><td>≈14 t fossil CO₂/person/year in North America ÷ 365</td></tr>
      </tbody>
    </table></div>
  </div>
  <div class="card">
    <h2>📚 Sources & method</h2>
    <ul class="source-list">${Object.entries(SOURCES).map(([id, s]) => `<li><strong>${esc(s.short)}</strong> — ${esc(s.label)}${s.url !== 'SOURCES.md' ? ` · <a href="${s.url}" target="_blank" rel="noopener">link</a>` : ''}</li>`).join('')}</ul>
    <p class="card-note" style="margin-top:12px">
      Values marked <strong>≈</strong> or <span class="badge-est">estimate</span> are derived (e.g. a manufacturing
      footprint divided by typical lifetime, or a per-kg factor scaled to a stated serving size) rather than read
      directly from a published table — the derivation is shown in the row and detailed in
      <a href="https://github.com/jaivik-2612/vscode_remote/blob/main/carbon-tracker/SOURCES.md" target="_blank" rel="noopener">SOURCES.md</a>.
      Gas splits (CO₂/CH₄/N₂O) are approximate allocations based on how each activity's emissions arise.
      All CH₄ and N₂O are expressed as CO₂-equivalent (GWP-100). Good for habit tracking; not for formal accounting.
    </p>
  </div>`;
  box.innerHTML = html;
}

/* ================= tips / suggestions engine ================= */
function weeklyStats() {
  const entries = entriesInRange(7);
  const per = {};
  for (const e of entries) {
    const rec = per[e.activityId] || (per[e.activityId] = { qty: 0, co2e: 0, use: 0 });
    const em = entryEmissions(e);
    rec.qty += e.qty;
    rec.co2e += em.total;
    rec.use += em.use;
  }
  return { entries, per, total: sumEmissions(entries).total };
}

function buildTips() {
  const { entries, per, total } = weeklyStats();
  const tips = [];
  const get = (id) => per[id] || { qty: 0, co2e: 0, use: 0 };
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
    tips.push({ icon: '🚿', title: 'Shorter water-heater runs', body: `The water heater ran ${(geyser.qty / 7 * 60).toFixed(0)} min/day on average. ~15 minutes of heating covers a shower; a timer or smart plug pays for itself fast.`, saving: (geyser.qty - MINIMAL_BASELINES.geyser.qty * 7) * 2.0 * gi });
  }

  const furnace = get('gas_furnace');
  if (furnace.qty / 7 > MINIMAL_BASELINES.gas_furnace.qty) {
    tips.push({ icon: '🌡️', title: 'Tame the furnace', body: `The gas furnace ran ~${(furnace.qty / 7).toFixed(1)} h/day. Each 1 °C lower on the thermostat cuts heating fuel ~7%; 20 °C when home, 17 °C at night, and sealed drafts usually get runtime to ~${MINIMAL_BASELINES.gas_furnace.qty} h/day.`, saving: (furnace.qty - MINIMAL_BASELINES.gas_furnace.qty * 7) * 3.2 });
  }

  const beef = get('meal_beef'), lamb = get('meal_lamb');
  const redMeatQty = beef.qty + lamb.qty;
  if (redMeatQty >= 2) {
    const vegPer = ACTIVITY_BY_ID.meal_veg.embPer;
    const avgRed = (beef.co2e + lamb.co2e) / redMeatQty;
    tips.push({ icon: '🥗', title: 'Swap some red-meat meals', body: `${fmtQty(redMeatQty)} beef/lamb meals this week at ~${fmtKg(avgRed)} each. Swapping one for chicken saves ~${fmtKg(avgRed - ACTIVITY_BY_ID.meal_chicken.embPer)}, for a vegetarian meal ~${fmtKg(avgRed - vegPer)} — the single biggest food lever.`, saving: (redMeatQty - 1) * (avgRed - vegPer) });
  }

  const carKm = get('car_petrol').qty + get('car_diesel').qty;
  if (carKm / 7 > 10) {
    const carF = ACTIVITY_BY_ID.car_petrol.usePer + ACTIVITY_BY_ID.car_petrol.embPer;
    const busF = ACTIVITY_BY_ID.bus.usePer + ACTIVITY_BY_ID.bus.embPer;
    tips.push({ icon: '🚌', title: 'Shift short car trips', body: `You drove ~${Math.round(carKm / 7)} km/day. Moving half of that to bus or metro cuts those kilometres' emissions by half or more; cycling or walking trips under 2 km cuts them to almost zero.`, saving: (carKm / 2) * (carF - busF) });
  }

  const flights = get('flight_dom').co2e + get('flight_int').co2e;
  if (flights > 0) {
    tips.push({ icon: '✈️', title: 'Flights dominate this week', body: `Flying added ${fmtKg(flights)} CO₂e. For routes under ~700 km, an intercity train emits about 6× less. When you must fly, prefer non-stop economy.` });
  }

  const stream = get('stream');
  if (stream.qty / 7 > MINIMAL_BASELINES.stream.qty) {
    tips.push({ icon: '📺', title: 'Lighter streaming habits', body: `~${(stream.qty / 7).toFixed(1)} h/day of streaming. Dropping from 4K to HD on small screens cuts the network footprint of each hour by more than half.`, saving: (stream.qty - MINIMAL_BASELINES.stream.qty * 7) * 0.02 });
  }

  const waste = get('waste');
  if (waste.qty / 7 > 0.5) {
    tips.push({ icon: '♻️', title: 'Divert waste from landfill', body: 'Landfilled organic waste rots into methane, a far stronger greenhouse gas. Composting kitchen scraps and segregating recyclables removes most of it.', saving: waste.co2e * 0.6 });
  }

  const em7 = sumEmissions(entries);
  if (em7.total > 0 && em7.emb / em7.total > 0.4) {
    tips.push({ icon: '🔧', title: 'Make your things last', body: `${Math.round((em7.emb / em7.total) * 100)}% of this week's footprint is manufacturing & supply chain, not energy use. The biggest lever there: keep devices and appliances longer, repair instead of replace, and buy second-hand — a phone kept 5 years instead of 3 nearly halves its manufacturing footprint per year.` });
  }

  if (state.settings.gridIntensity >= 0.6) {
    tips.push({ icon: '☀️', title: 'Your grid is carbon-heavy', body: `At ${state.settings.gridIntensity} kg CO₂/kWh, every appliance-hour counts. If available, rooftop solar or a green-power tariff would cut your electricity emissions by ~90%.` });
  }

  if (tips.length <= 2) {
    tips.push({ icon: '💡', title: 'General wins', body: 'Biggest levers in order: fly less, drive less, eat less red meat, cool/heat efficiently, keep your things longer. Log more activity types to get sharper, personalised suggestions.' });
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
    /* Operation phase only: using a thing less doesn't undo its manufacturing. */
    const savingPerDay = over * useFactor(a);
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

/* ================= accounts (settings card) ================= */
function renderChip() {
  const chip = $('#account-chip');
  chip.textContent = state.user ? `👤 ${state.user.name}` : '👤 —';
  chip.title = state.user
    ? `Signed in as ${state.user.name}${state.user.cloud ? ' (cloud backup on)' : ''} — manage in Settings`
    : 'Sign in';
}

function accountMsg(text, isError) {
  const el = $('#account-msg');
  if (!el) return;
  el.textContent = text || '';
  el.className = 'account-msg' + (isError ? ' error' : '');
}

function armTwoTap(btn, armedLabel, restLabel, fn) {
  if (btn.dataset.armed !== '1') {
    btn.dataset.armed = '1';
    btn.textContent = armedLabel;
    setTimeout(() => { if (btn.isConnected) { btn.dataset.armed = ''; btn.textContent = restLabel; } }, 4000);
    return;
  }
  btn.dataset.armed = '';
  btn.textContent = restLabel;
  fn();
}

function renderAccountUI() {
  const box = $('#account-ui');
  if (!state.user) { box.innerHTML = ''; return; }

  if (state.user.cloud) {
    box.innerHTML = `
      <p class="card-note">Signed in as <strong>${esc(state.user.name)}</strong> (${esc(state.user.email)}). Your data is saved on this device and backed up to your cloud account automatically a moment after every change.</p>
      <p id="backup-status" class="account-msg"></p>
      <div class="btn-row">
        <button id="acc-backup" class="btn-secondary">Back up now</button>
        <button id="acc-restore" class="btn-secondary">Restore from cloud</button>
        <button id="acc-logout" class="btn-secondary">Sign out</button>
      </div>
      <p id="account-msg" class="account-msg"></p>`;
    renderBackupStatus();
    $('#acc-backup').addEventListener('click', async () => {
      accountMsg('Backing up…');
      await pushBackup();
      accountMsg(state.backupStatus === 'ok' ? 'Backup complete.' : 'Could not reach the cloud — check your connection.', state.backupStatus !== 'ok');
    });
    $('#acc-restore').addEventListener('click', () => {
      armTwoTap($('#acc-restore'), 'Tap again to overwrite this device', 'Restore from cloud', async () => {
        try {
          const remote = await Cloud.fetchBackup();
          if (!remote || !remote.payload) { accountMsg('No cloud backup found yet.', true); return; }
          applyBackup(remote.payload);
          accountMsg(`Restored ${state.logs.length} entries from your cloud backup.`);
        } catch (_) {
          accountMsg('Could not reach the cloud — check your connection.', true);
        }
      });
    });
    $('#acc-logout').addEventListener('click', () => { Cloud.signOut(); location.reload(); });
    return;
  }

  box.innerHTML = `
    <p class="card-note">Signed in as <strong>${esc(state.user.name)}</strong>${state.user.email ? ` (${esc(state.user.email)})` : ''} — your logs and settings are saved under this account on this device. Cloud backup is off (no backend configured — see SETUP-CLOUD.md).</p>
    <div class="btn-row">
      <button id="acc-logout" class="btn-secondary">Sign out / switch account</button>
      <button id="acc-delete" class="btn-danger">Delete this account</button>
    </div>
    <p id="account-msg" class="account-msg"></p>`;
  $('#acc-logout').addEventListener('click', () => { Accounts.logout(); location.reload(); });
  $('#acc-delete').addEventListener('click', () => {
    armTwoTap($('#acc-delete'), 'Tap again to delete account & its data', 'Delete this account', () => {
      Accounts.remove(state.user.id);
      location.reload();
    });
  });
}

/* ================= settings ================= */
function renderSettings() {
  $('#grid-country').innerHTML = GRID_COUNTRIES
    .map((c) => `<option value="${c.id}" ${c.id === state.settings.country ? 'selected' : ''}>${esc(c.label)} (${c.value})</option>`).join('');
  const subs = GRID_SUBDIVISIONS[state.settings.country];
  $('#grid-subdiv-field').style.display = subs ? '' : 'none';
  if (subs) {
    $('#grid-subdiv-label').textContent = state.settings.country === 'CA' ? 'Province / territory' : 'State';
    const nat = GRID_COUNTRIES.find((c) => c.id === state.settings.country).value;
    $('#grid-subdiv').innerHTML = `<option value="">National average (${nat})</option>`
      + subs.map((s) => `<option value="${s.id}" ${s.id === state.settings.subdivision ? 'selected' : ''}>${esc(s.label)} (${s.value})</option>`).join('');
  }
  $('#grid-custom').value = state.settings.gridIntensity;
}

function onRegionChange(countryChanged) {
  state.settings.country = $('#grid-country').value;
  if (countryChanged) state.settings.subdivision = '';
  else state.settings.subdivision = $('#grid-subdiv').value;
  state.settings.gridIntensity = regionIntensity(state.settings.country, state.settings.subdivision);
  saveSettings();
  renderSettings();
  renderDay();
}

function onGridCustom() {
  const v = parseFloat($('#grid-custom').value);
  if (!(v >= 0) || v > 5) return;
  state.settings.gridIntensity = v;
  saveSettings();
  renderDay();
}

function exportData() {
  const blob = new Blob([JSON.stringify(backupPayload(), null, 2)], { type: 'application/json' });
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
      applyBackup(data);
      scheduleBackup();
      accountMsg(`Imported ${state.logs.length} entries.`);
    } catch (_) {
      accountMsg('Could not read that file — expected a JSON export from this app.', true);
    }
  };
  reader.readAsText(file);
}

function clearData() {
  const btn = $('#btn-clear');
  armTwoTap(btn, 'Tap again to delete everything', 'Delete all data', () => {
    state.logs = [];
    saveLogs();
    renderDay();
  });
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
function wireOnce() {
  if (state.wired) return;
  state.wired = true;

  setupTooltip();

  $$('.tab').forEach((b) => b.addEventListener('click', () => switchTab(b.dataset.tab)));
  $$('.range-btn').forEach((b) => b.addEventListener('click', () => {
    state.range = Number(b.dataset.range);
    $$('.range-btn').forEach((x) => x.classList.toggle('active', x === b));
    renderDashboard();
  }));

  $('#account-chip').addEventListener('click', () => switchTab('settings'));

  $('#log-category').addEventListener('change', populateActivitySelect);
  $('#log-activity').addEventListener('change', updateQtyLabel);
  $('#log-qty').addEventListener('input', updatePreview);
  $('#log-form').addEventListener('submit', addEntry);
  $('#log-date').addEventListener('change', () => {
    state.logDate = $('#log-date').value || todayStr();
    state.openEntry = null;
    renderDay();
  });

  $('#day-entries').addEventListener('click', (ev) => {
    const del = ev.target.closest('.entry-del');
    if (del) { removeEntry(del.dataset.id); return; }
    const upd = ev.target.closest('.entry-update');
    if (upd) {
      const input = $(`#edit-${CSS.escape(upd.dataset.id)}`);
      const qty = parseFloat(input && input.value);
      const entry = state.logs.find((e) => e.id === upd.dataset.id);
      if (entry && qty > 0) { entry.qty = qty; saveLogs(); renderDay(); }
      return;
    }
    if (ev.target.closest('.entry-detail')) return;
    const row = ev.target.closest('.entry-row');
    if (row) {
      const id = row.parentElement.dataset.entry;
      state.openEntry = state.openEntry === id ? null : id;
      renderDay();
    }
  });
  $('#day-entries').addEventListener('keydown', (ev) => {
    if (ev.key !== 'Enter' && ev.key !== ' ') return;
    const row = ev.target.closest('.entry-row');
    if (row && ev.target === row) {
      ev.preventDefault();
      const id = row.parentElement.dataset.entry;
      state.openEntry = state.openEntry === id ? null : id;
      renderDay();
    }
  });

  $('#btn-sample').addEventListener('click', () => dismissWelcome(true));
  $('#btn-welcome-dismiss').addEventListener('click', () => dismissWelcome(false));
  $('#btn-repeat').addEventListener('click', copyPreviousDay);
  $('#quick-chips').addEventListener('click', (ev) => {
    const chip = ev.target.closest('.chip');
    if (chip) addEntryDirect(chip.dataset.act, parseFloat(chip.dataset.qty));
  });
  $('#tmpl-save').addEventListener('click', saveDayTemplate);
  $('#tmpl-apply').addEventListener('click', applyTemplate);
  $('#tmpl-delete').addEventListener('click', deleteTemplate);

  $('#grid-country').addEventListener('change', () => onRegionChange(true));
  $('#grid-subdiv').addEventListener('change', () => onRegionChange(false));
  $('#grid-custom').addEventListener('change', onGridCustom);
  $('#btn-export').addEventListener('click', exportData);
  $('#btn-import').addEventListener('change', (ev) => { if (ev.target.files[0]) importData(ev.target.files[0]); ev.target.value = ''; });
  $('#btn-clear').addEventListener('click', clearData);

  window.addEventListener('online', () => { if (state.backupStatus === 'fail') scheduleBackup(); });
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    renderDay();
    if ($('#tab-dashboard').classList.contains('active')) renderDashboard();
  });

  if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) {
    navigator.serviceWorker.register('sw.js').catch(() => { /* not available (e.g. preview) */ });
  }
}

function init() {
  /* Arriving from a password-reset email link? Show the reset view first. */
  if (Cloud.enabled()) {
    const rec = parseRecoveryHash();
    if (rec) {
      recoveryToken = rec;
      renderGate('reset');
      return;
    }
    const hashErr = parseHashError();
    if (hashErr) {
      clearHash();
      renderGate('signin');
      const el = $('#gate-msg');
      el.textContent = hashErr.replace(/\+/g, ' ') + ' — request a new reset link below if needed.';
      el.className = 'account-msg error';
      return;
    }
  }

  const user = activeUser();
  if (!user) { renderGate(); return; }

  document.body.classList.remove('gated');
  $('#auth-gate').hidden = true;

  loadState();
  if (pendingRegion) {
    state.settings.country = pendingRegion.country;
    state.settings.subdivision = pendingRegion.subdivision || '';
    state.settings.gridIntensity = regionIntensity(state.settings.country, state.settings.subdivision);
    pendingRegion = null;
    saveSettings();
  }
  wireOnce();

  $('#log-date').value = state.logDate;
  $('#log-date').max = todayStr();
  populateLogSelects();
  renderChip();
  renderAccountUI();
  renderSettings();
  renderDay();
  if ($('#tab-dashboard').classList.contains('active')) renderDashboard();

  if (state.user.cloud) cloudAfterLogin();
}

document.addEventListener('DOMContentLoaded', init);
