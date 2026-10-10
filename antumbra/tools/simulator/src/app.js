/* Antumbra Simulator. One namespace on window: ANTUMBRA_SIM.
   Modules: util, store (Persistent Storage), state, journal, ui (router, panel, notes, popovers,
   gestures), settings (port of antumbra/settings.py), welcome, applier, boot, session (top bar,
   overview, drawer, notifications, lock), net, tor, android, camera, apps, power. */
(() => {
'use strict';

const ICONS = /*@ICONS@*/{};
const SIM = {};

/* ======================================================================= util */
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ic = (name, cls = '') => `<svg class="ic ${cls}" aria-hidden="true" focusable="false"><use href="#i-${name}"/></svg>`;
const frag = html => { const t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; };
const cpLen = s => Array.from(s).length;          // Python len(): code points
const pad2 = n => String(n).padStart(2, '0');
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const rnd = n => Math.floor(Math.random() * n);
const hex2 = n => n.toString(16).padStart(2, '0');
const icon = id => ICONS[id] || ICONS['app-icon-unknown'];
function cyrb53(str, seed = 0) {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
  for (let i = 0; i < str.length; i++) {
    const ch = str.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}
/* the screen-lock passphrase lives only in this page's memory: a fast hash is enough there */
const hashPass = (p, salt) => cyrb53(salt + '\u0000' + p, 7).toString(16) + cyrb53(p + '\u0001' + salt, 13).toString(16);
const randSalt = () => { try { return Array.from(crypto.getRandomValues(new Uint8Array(16)), hex2).join(''); } catch (e) { return Array.from({ length: 16 }, () => hex2(rnd(256))).join(''); } };
/* the simulated volume's passphrase is kept in the browser's storage: a slow, salted PBKDF2 hash
   (WebCrypto), so a passphrase typed here is not cheap to guess from it; a fast hash only where
   WebCrypto is missing */
const KDF = 'pbkdf2-sha256-310000';
async function slowHash(pass, salt) {
  try {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey('raw', enc.encode(pass), 'PBKDF2', false, ['deriveBits']);
    const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: enc.encode(salt), iterations: 310000 }, key, 256);
    return { kdf: KDF, hash: Array.from(new Uint8Array(bits), hex2).join('') };
  } catch (e) { return { kdf: 'cyrb53', hash: hashPass(pass, salt) }; }
}

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const h12 = d => d.getHours() % 12 || 12;
const ampm = d => (d.getHours() < 12 ? 'AM' : 'PM');
const Clock = {
  // gnome-desktop wall clock with date, 12-hour: "%b %-e_%l:%M %p", "_" = EM SPACE, %l space-padded
  top: d => `${MON[d.getMonth()]} ${d.getDate()} ${String(h12(d)).padStart(2, ' ')}:${pad2(d.getMinutes())} ${ampm(d)}`,
  time: d => `${h12(d)}:${pad2(d.getMinutes())} ${ampm(d)}`,
  date: d => `${DAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}`,      // "%A, %B %-e"
  hms: d => `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`,
};

/* timers that belong to one boot: a restart cancels them */
const T = {
  ids: new Set(),
  after(ms, fn) { const id = setTimeout(() => { this.ids.delete(id); fn(); }, ms); this.ids.add(id); return id; },
  clear(id) { clearTimeout(id); this.ids.delete(id); },
  clearAll() { this.ids.forEach(clearTimeout); this.ids.clear(); },
};
class Aborted extends Error {}
function wait(ms) { const b = S.boot; return new Promise((res, rej) => T.after(ms, () => (b === S.boot ? res() : rej(new Aborted())))); }

/* ====================================================================== store */
const STORE_KEY = 'antumbra-sim:persistent-storage:v1';
const PREF_KEY = 'antumbra-sim:prefs:v1';
const lsGet = k => { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : null; } catch (e) { return null; } };
const lsSet = (k, v) => { try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } };
/* The simulated ANTUMBRA_DATA partition: kept in this browser so it survives restarts and reloads.
   It is NOT encrypted: notes saved in it are plain text in the browser's storage. Never the
   passphrase itself: a slow salted hash only. A picture of the viewer's own is never stored. */
const STORAGE_BLOCKED = 'This browser blocks site storage: the simulated Persistent Storage lasts only until this page is reloaded.';
const Store = {
  vol: null, blocked: false,
  load() { const v = lsGet(STORE_KEY); this.vol = v && v.hash ? v : null; },
  save() {
    if (lsSet(STORE_KEY, this.vol) || !this.vol) return;
    if (!this.blocked) { this.blocked = true; Notes.add(STORAGE_BLOCKED, { force: true, ms: 9000 }); Panel.update(); }
  },
  exists() { return !!this.vol; },
  async create(pass) {
    const salt = randSalt();
    const { kdf, hash } = await slowHash(pass, salt);
    this.vol = { v: 1, kdf, salt, hash, created: new Date().toISOString(), android: false,
      files: [], wifi: [], fdroid: false, fdroidNotif: null, settings: {} };
    this.save();
  },
  async check(pass) {
    if (!this.vol) return false;
    const h = this.vol.kdf === KDF ? (await slowHash(pass, this.vol.salt)).hash : hashPass(pass, this.vol.salt);
    if (h !== this.vol.hash) return false;
    if (this.vol.kdf !== KDF) {          // a volume from an earlier version of this page: re-hash it slowly
      const salt = randSalt(), n = await slowHash(pass, salt);
      if (n.kdf === KDF) { Object.assign(this.vol, { salt, kdf: n.kdf, hash: n.hash }); this.save(); }
    }
    return true;
  },
  erase() { this.vol = null; lsSet(STORE_KEY, null); },
  writable() { try { localStorage.setItem('antumbra-sim:probe', '1'); localStorage.removeItem('antumbra-sim:probe'); return true; } catch (e) { return false; } },
};
const Persist = {
  warned: false, sheetShown: false,
  warn() { if (this.warned) return; this.warned = true; Notes.add(UNENCRYPTED, { force: true, ms: 12000 }); },
  /* the first time Create is chosen (once per page load): a modal sheet on the phone itself, so the
     viewer reads it before typing a passphrase; the panel's list keeps a copy */
  sheet(ret) {
    if (this.sheetShown) return false;
    this.sheetShown = this.warned = true;
    Notes.add(UNENCRYPTED, { force: true, quiet: true });
    sheet(`<h3 id="encTitle">Simulator note: this Persistent Storage is not encrypted</h3>
      <p>On the phone, Persistent Storage is an encrypted LUKS2 volume. This simulator only acts it out: what you keep in it stays <strong>in plain text in this browser's storage</strong> (localStorage) until you use "Erase simulated Persistent Storage" in the Simulator panel.</p>
      <p><strong>Do not type a passphrase you really use, and do not save real notes.</strong> The passphrase itself is never stored, only a slow salted hash of it (PBKDF2).</p>
      ${Store.blocked || !Store.writable() ? '<p>This browser blocks site storage here, so the simulated volume lasts only until this page is reloaded.</p>' : ''}`,
      { label: 'Simulator note: the simulated Persistent Storage is not encrypted', close: 'I understand', ret, cls: 'enc-sheet' });
    return true;
  },
};
const UNENCRYPTED = 'The simulated Persistent Storage is NOT encrypted: what you keep in it stays in plain text in this browser\'s storage until you use "Erase simulated Persistent Storage" in the panel. Do not type a passphrase you really use, and do not save real notes.';
const Prefs = Object.assign({ introSeen: false, notes: true, idle: true, androidImage: true, selfcheckFail: false, torOutcome: 'done' }, lsGet(PREF_KEY) || {});
const savePrefs = () => lsSet(PREF_KEY, Prefs);

/* ====================================================================== state */
const S = {
  boot: 0, scr: 'boot',
  image: { android: true, selfcheckFail: false },
  persistState: 'none',          // what antumbra-persistence status found at this boot
  welcomeApplied: false, applied: null,
  ram: null, net: null, tor: null, adr: null, cam: null, sess: null,
  battery: 82, brightness: 0.85, volume: 0.9,
  selfStatus: [], selfLate: 0,
};
function freshBootState() {
  S.welcomeApplied = false; S.applied = null; S.sess = null; S.netIfs = null;
  S.ram = {
    salt: randSalt(), persistent: false, camPerm: null, editorCount: 0,
    fs: { Desktop: [], Documents: [], Downloads: [], Music: [], Pictures: [], Public: [], Templates: [], Videos: [] },
    fdroidNotif: null, lockNoteShown: false,
  };
  const b0 = (rnd(64) << 2) | 2;   // ath10k without a provisioned address: random, locally administered
  S.net = { present: false, nm: false, enabled: true, ssid: null, connecting: null, ip: null,
    hw: [b0, rnd(256), rnd(256), rnd(256), rnd(256), rnd(256)].map(hex2).join(':'), cur: null, scan: null, scanAt: 0 };
  S.tor = { pct: 0, tag: 'starting', summary: 'Starting', dn: 1, mode: null, running: false, done: false, stuck: false, nBridges: 0 };
  S.adr = { state: 'off', fdroid: false, openWhenReady: false, noted: false };
  S.cam = { pos: 'down', streaming: false, source: 'bars', photo: null };
}
/* The address on wlan0 right now. antumbra-privacy.conf sets wifi.scan-rand-mac-address=yes, so while
   NetworkManager manages wlan0 and is neither connecting nor connected (device state below 40) its
   random scan address is on the interface: locally administered, unicast, a new one after 5 minutes.
   Activating a connection puts back the address antumbra-spoof-mac gave it (cloned-mac-address=preserve).
   antumbra-selfcheck's mac-wlan0 check accepts exactly that case as "mac-wlan0 (scan address)". */
const Wlan = {
  scanning() { const n = S.net; return n.present && n.nm && !n.ssid && !n.connecting; },
  addr() {
    const n = S.net;
    if (!n.present) return null;
    if (!this.scanning()) return n.cur;
    if (!n.scan || Date.now() - n.scanAt > 300000) {
      n.scan = [hex2((rnd(256) & 0xfc) | 0x02), ...Array.from({ length: 5 }, () => hex2(rnd(256)))].join(':');
      n.scanAt = Date.now();
    }
    return n.scan;
  },
};

/* ==================================================================== journal */
function J(unit, msg) {
  const t = Clock.hms(new Date());
  J.lines.push(`${t} ${unit}: ${msg}`);
  if (J.lines.length > 400) J.lines.shift();
  const el = $('#journal');
  if (el) {
    const d = document.createElement('div');
    d.innerHTML = `<b>${esc(t)}</b> ${esc(unit)}: ${esc(msg)}`;
    el.append(d);
    while (el.childElementCount > 400) el.firstElementChild.remove();
    el.scrollTop = el.scrollHeight;
  }
}
J.lines = [];

/* ========================================================================= ui */
const UI = {
  scale: 1, wide: false, cur: null,
  screen: null,
  init() {
    this.screen = $('#screen');
    // focus and scrollIntoView can scroll overflow:hidden containers; the phone's frame never scrolls
    const FIXED = '.screen, .scr, .w-root, .w-mid, .session, .applayer, .win, .overview, .ov-main, .folder-page, .drawer, .lock, .lock-pages, .lock-page, .snap-view, .modal-back, .awin-wrap, .awin, .adr, .adr-shade';
    this.screen.addEventListener('scroll', e => {
      const t = e.target;
      if (t && t.matches && t.matches(FIXED) && (t.scrollTop || t.scrollLeft)) { t.scrollTop = 0; t.scrollLeft = 0; }
    }, true);
    this.layout();
    this.fullH = innerHeight; this.fullW = innerWidth;
    // a keyboard that resizes the layout viewport (rather than overlaying it) counts too
    addEventListener('resize', () => { this.layout(); this.kb(); });
    const vv = window.visualViewport;
    if (vv) { vv.addEventListener('resize', () => this.kb()); vv.addEventListener('scroll', () => this.kb()); }
    document.addEventListener('focusout', () => setTimeout(() => this.kb(), 60));
  },
  /* the same rule as the CSS: a frame only where it fits at a usable scale (about 0.6 or more) */
  WIDE: '(min-width: 700px) and (min-height: 580px)',
  layout() {
    this.wide = matchMedia(this.WIDE).matches;
    $('#sim').classList.toggle('sim-mobile', !this.wide);
    if (this.wide) {
      const fs = clamp(Math.min((innerHeight - 40) / 904, (innerWidth - 48 - 44 - Math.min(420, innerWidth * 0.4)) / 410), 0.45, 1);
      document.documentElement.style.setProperty('--fs', fs.toFixed(4));
      this.scale = fs;
    } else { document.documentElement.style.setProperty('--fs', '1'); this.scale = 1; }
    if (this.wide) { Panel.open(false, true); Notes.clear(); }
    Notes.badge();
    fadeLabels();
  },
  /* on-screen keyboard: keep the focused row of a scrolling view above it */
  forcedKb: null, fullH: 0, fullW: 0,
  kbHeight() {
    if (this.forcedKb != null) return this.forcedKb;
    const vv = window.visualViewport;
    return vv ? Math.max(0, Math.round(innerHeight - vv.height - vv.offsetTop)) : 0;
  },
  typing() { const a = document.activeElement; return !!(a && a.matches && a.matches('input:not([type="radio"]):not([type="file"]), textarea') && this.screen.contains(a)); },
  /* how much the layout viewport shrank while a field has the focus (a resizing keyboard) */
  shrunk() {
    if (innerWidth !== this.fullW) { this.fullW = innerWidth; this.fullH = innerHeight; return 0; }
    if (!this.typing()) { this.fullH = innerHeight; return 0; }
    this.fullH = Math.max(this.fullH, innerHeight);
    return this.fullH - innerHeight;
  },
  kb(forced) {
    if (forced !== undefined) this.forcedKb = forced || null;
    const kb = this.kbHeight() > 80 ? this.kbHeight() : 0;
    const open = kb > 0 || (this.forcedKb == null && this.shrunk() > 80);
    document.documentElement.style.setProperty('--kb', kb + 'px');
    const w = $('.w-root');
    if (w) w.classList.toggle('kb', open);
    const a = document.activeElement;
    if (open && this.typing()) setTimeout(() => ensureVisible(a), 30);
    else if (!open && (window.scrollY || window.scrollX)) window.scrollTo(0, 0);
  },
  mount(name, el) {
    if (this.cur) this.cur.remove();
    this.cur = el; el.dataset.scr = name; el.classList.add('scr');
    this.screen.insertBefore(el, this.screen.firstChild);
    S.scr = name;
    document.documentElement.dataset.scr = name;
    if (name !== 'session') this.screen.classList.remove('qs-open', 'ov-open');
    closePopover(); closeSheet();
    Notes.sync(); Notes.renderPanel();
    Panel.update();
  },
  /* coordinates inside the (possibly scaled) phone screen */
  rel(rect) {
    const s = this.screen.getBoundingClientRect();
    return { left: (rect.left - s.left) / this.scale, top: (rect.top - s.top) / this.scale, right: (rect.right - s.left) / this.scale,
      bottom: (rect.bottom - s.top) / this.scale, width: rect.width / this.scale, height: rect.height / this.scale, sw: s.width / this.scale, sh: s.height / this.scale };
  },
};

/* keep a focused field (and its row) between the header and the on-screen keyboard */
function ensureVisible(el) {
  const row = el.closest('.w-row, .term-in, .lock-page, .dialog .dfield, .form label, .radio') || el;
  const sc = el.closest('.w-scroll, .win-body, .qs-scroll, .ov-scroll');
  const vv = window.visualViewport;
  const top = (vv && UI.forcedKb == null ? vv.offsetTop : 0) + 72;
  const bottom = UI.forcedKb != null ? innerHeight - UI.forcedKb : (vv ? vv.offsetTop + vv.height : innerHeight);
  const r = row.getBoundingClientRect();
  if (!sc) { if (r.bottom > bottom) row.scrollIntoView({ block: 'center' }); return; }
  if (r.bottom > bottom - 12) sc.scrollTop += r.bottom - (bottom - 12);
  else if (r.top < top) sc.scrollTop -= top - r.top;
}
function fadeLabels(root = document) {
  requestAnimationFrame(() => $$('.appbtn .lbl', root).forEach(l => l.classList.toggle('fade', l.scrollWidth > l.clientWidth + 1)));
}

/* Simulator notes: explanations that are not part of the OS. They never cover the OS's controls:
   - in the panel's Notes list, always (on a wide screen the panel sits beside the phone);
   - on the phone itself only where nothing can be touched: the bare home screen (above the home
     bar) or the Welcome screen's title strip; a dismissible card there, never over an app;
   - otherwise the Simulator chip counts them until the panel is opened. */
const Notes = {
  shown: new Set(), items: [], unread: 0, seq: 0,
  add(text, { key, action, act, ms = 5500, force, quiet } = {}) {
    if (!Prefs.notes && !force) return;
    if (key && this.shown.has(key)) return;
    if (key) this.shown.add(key);
    const it = { id: ++this.seq, text, action, act, t: new Date(), boot: S.boot, scr: S.scr };
    this.items.unshift(it);
    if (this.items.length > 40) this.items.pop();
    // quiet: already shown on the phone some other way (a sheet): the panel's list only, not counted
    const onPhone = !quiet && !UI.wide && !Panel.isOpen && this.overlay(it, ms);
    if (!quiet && !onPhone && !UI.wide && !Panel.isOpen) this.unread++;
    this.renderPanel(it, !onPhone && !quiet);
    this.badge();
  },
  /* the free area of the current phone screen, or null */
  zone() {
    if (UI.wide || Panel.isOpen || popState || Modal.cur || $('.sheet-wrap, .intro', UI.screen)) return null;
    if (S.scr === 'welcome') return $('.w-head', UI.screen) ? 'welcome' : null;
    if (S.scr !== 'session' || !S.sess) return null;
    const s = S.sess;
    if (s.overview || s.drawer || s.locked || s.blank || s.front || UI.screen.classList.contains('qs-open') || $('.splash, .overview.dragging, .drawer.dragging', UI.screen)) return null;
    return 'home';
  },
  overlay(it, ms) {
    const z = this.zone();
    if (!z) return false;
    let box = $('.simnotes', UI.screen);
    if (!box) { box = frag('<div class="simnotes" role="status" aria-live="polite"></div>'); UI.screen.append(box); }
    if (!box.classList.contains('z-' + z)) { box.innerHTML = ''; box.className = 'simnotes z-' + z; }
    const n = frag(`<div class="simnote"><div class="txt"><span class="tag">Simulator</span>${it.text}</div>${it.action ? `<button class="act" type="button">${esc(it.act)}</button>` : ''}<button class="x" type="button" aria-label="Dismiss this note">${ic('app-close-symbolic')}</button></div>`);
    const kill = () => { n.remove(); if (!box.firstChild) UI.screen.classList.remove('note-head'); };
    n.addEventListener('click', e => { if (e.target.closest('.act')) this.run(it); kill(); });
    box.append(n);
    while (box.childElementCount > (z === 'home' ? 2 : 1)) box.firstElementChild.remove();
    // the Welcome screen's free strip is its 64-pixel title: a longer note goes to the chip instead
    if (z === 'welcome') {
      const head = $('.w-head', UI.screen);
      if (n.offsetHeight > (head ? head.offsetHeight : 64) - 6) { kill(); return false; }
      UI.screen.classList.add('note-head');
    }
    setTimeout(kill, ms);
    return true;
  },
  /* drop a card whose free area has just been covered (an app opened, a drag started…) */
  sync(force) {
    const box = $('.simnotes', UI.screen);
    if (!box || !box.firstChild) return;
    const z = force ? null : this.zone();
    if (!z || !box.classList.contains('z-' + z)) { box.innerHTML = ''; UI.screen.classList.remove('note-head'); }
  },
  run(it) {
    if (!it.action || it.boot !== S.boot || it.scr !== S.scr) return;
    if (Panel.isOpen && !UI.wide) Panel.open(false, true);
    it.action();
  },
  renderPanel(fresh, announce) {
    const list = $('#pnotesList'); if (!list) return;
    list.innerHTML = '';
    for (const it of this.items) {
      const live = it.action && it.boot === S.boot && it.scr === S.scr;
      const li = frag(`<li class="pnote${fresh && it === fresh ? ' new' : ''}"><time>${esc(Clock.hms(it.t))}</time><div class="pn-txt">${it.text}</div>${live ? `<button class="pbtn accent" type="button">${esc(it.act)}</button>` : ''}</li>`);
      if (live) $('button', li).addEventListener('click', () => { this.run(it); this.renderPanel(); });
      list.append(li);
    }
    $('#pnotesEmpty').hidden = this.items.length > 0;
    $('#pnotesClear').hidden = !this.items.length;
    if (fresh) list.parentElement.scrollTop = 0;
    if (fresh && announce) { const lv = $('#pnotesLive'); if (lv) { const d = document.createElement('div'); d.innerHTML = fresh.text; lv.textContent = 'Simulator note: ' + d.textContent; } }
  },
  badge() {
    const c = $('#simChip'); if (!c) return;
    const n = UI.wide ? 0 : this.unread;
    c.classList.toggle('has-notes', n > 0);
    $('.nb', c).textContent = n > 9 ? '9+' : String(n);
    c.setAttribute('aria-label', n ? `Open the simulator panel: ${n} new ${n === 1 ? 'note' : 'notes'}` : 'Open the simulator panel');
  },
  read() { this.unread = 0; this.badge(); },
  clearAll() { this.items = []; this.unread = 0; this.clear(); this.renderPanel(); this.badge(); },
  clear() { const b = $('.simnotes', UI.screen); if (b) b.innerHTML = ''; UI.screen.classList.remove('note-head'); },
};

/* bottom sheet of simulator information: modal (the screen under it is inert until it closes);
   Close, a tap on the dimmed screen above it or Escape dismisses it, and focus goes back to `ret` */
function sheet(html, { label = 'Simulator information', close = 'Close', ret, cls = '' } = {}) {
  closeSheet();
  const w = frag(`<div class="sheet-wrap${cls ? ' ' + cls : ''}" role="dialog" aria-modal="true" aria-label="${esc(label)}"><div class="sheet"><span class="badge-sim">Simulator</span>${html}<button class="pbtn accent" type="button" data-close>${esc(close)}</button></div></div>`);
  const done = () => { closeSheet(); if (ret && ret.isConnected) ret.focus({ preventScroll: true }); };
  w.addEventListener('click', e => { if (e.target === w || e.target.closest('[data-close]')) done(); });
  w.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); done(); } });
  UI.screen.append(w);
  if (UI.cur) UI.cur.inert = true;
  Notes.sync();
  $('[data-close]', w).focus({ preventScroll: true });
}
function closeSheet() {
  const open = $$('.sheet-wrap', UI.screen);
  open.forEach(e => e.remove());
  if (open.length && UI.cur) UI.cur.inert = false;
}

/* libadwaita-like popover: listbox (combo rows) or menu */
let popState = null;
function popover(anchor, items, { role = 'menu', onPick, cls = '', label = '' } = {}) {
  closePopover();
  const r = UI.rel(anchor.getBoundingClientRect());
  const back = frag('<div class="pop-back"></div>');
  const p = frag(`<div class="pop ${cls}" role="${role === 'listbox' ? 'listbox' : 'menu'}" aria-label="${esc(label)}"></div>`);
  items.forEach((it, i) => {
    const b = frag(`<button type="button" role="${role === 'listbox' ? 'option' : 'menuitem'}" ${role === 'listbox' ? `aria-selected="${!!it.selected}"` : ''} ${it.disabled ? 'disabled' : ''}>${it.icon ? ic(it.icon) : ''}<span>${esc(it.label)}</span>${role === 'listbox' ? ic('object-select-symbolic') : ''}</button>`);
    b.addEventListener('click', () => { closePopover(); anchor.focus({ preventScroll: true }); onPick && onPick(it, i); });
    p.append(b);
  });
  back.addEventListener('pointerdown', e => { e.preventDefault(); closePopover(); });
  UI.screen.append(back, p);
  const pw = p.offsetWidth, ph = p.offsetHeight;
  let left = clamp(r.right - pw - 8, 8, r.sw - pw - 8);
  let top = r.bottom + 4;
  if (top + ph > r.sh - 20) top = Math.max(8, r.top - ph - 4);
  p.style.left = left + 'px'; p.style.top = top + 'px';
  popState = { back, p, anchor };
  Notes.sync();
  anchor.setAttribute('aria-expanded', 'true');
  const sel = $('[aria-selected="true"]', p) || $('button:not(:disabled)', p);
  if (sel) sel.focus({ preventScroll: true });
  p.addEventListener('keydown', e => {
    const bs = $$('button:not(:disabled)', p); const i = bs.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); bs[(i + 1) % bs.length].focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); bs[(i - 1 + bs.length) % bs.length].focus(); }
    if (e.key === 'Escape') { e.preventDefault(); closePopover(); anchor.focus(); }
  });
}
function closePopover() {
  if (!popState) return;
  popState.back.remove(); popState.p.remove();
  popState.anchor.setAttribute('aria-expanded', 'false');
  popState = null;
}

/* vertical drag with pointer events; deltas in phone px */
function dragY(el, { onStart, onMove, onEnd, accept } = {}) {
  el.addEventListener('pointerdown', e => {
    if (e.button !== 0 || (accept && !accept(e))) return;
    const sx = e.clientX, sy = e.clientY, id = e.pointerId;
    let active = false, ly = sy, lt = performance.now(), vy = 0;
    const move = ev => {
      if (ev.pointerId !== id) return;
      const dy = (ev.clientY - sy) / UI.scale, dx = (ev.clientX - sx) / UI.scale;
      if (!active) {
        if (Math.abs(dy) < 8 || Math.abs(dy) < Math.abs(dx)) return;
        active = true; el.dataset.dragged = '1';
        try { el.setPointerCapture(id); } catch (err) { /* not capturable */ }
        onStart && onStart();
      }
      const now = performance.now();
      vy = ((ev.clientY - ly) / UI.scale) / Math.max(1, now - lt); ly = ev.clientY; lt = now;
      onMove && onMove(dy);
    };
    const up = ev => {
      if (ev.pointerId !== id) return;
      removeEventListener('pointermove', move); removeEventListener('pointerup', up); removeEventListener('pointercancel', up);
      if (active) { onEnd && onEnd((ev.clientY - sy) / UI.scale, vy); setTimeout(() => { delete el.dataset.dragged; }, 50); }
    };
    addEventListener('pointermove', move); addEventListener('pointerup', up); addEventListener('pointercancel', up);
  });
}

/* ================================================================== panel */
const Panel = {
  isOpen: false,
  open(on, silent) {
    const p = $('#panel');
    if (UI.wide) { p.classList.remove('open'); p.removeAttribute('aria-modal'); p.removeAttribute('aria-hidden'); p.removeAttribute('role'); this.isOpen = false; $('#simChip').setAttribute('aria-expanded', 'false'); return; }
    this.isOpen = on;
    p.classList.toggle('open', on);
    p.setAttribute('aria-hidden', on ? 'false' : 'true');
    if (on) { p.setAttribute('aria-modal', 'true'); p.setAttribute('role', 'dialog'); } else { p.removeAttribute('aria-modal'); p.removeAttribute('role'); }
    $('#simChip').setAttribute('aria-expanded', String(on));
    if (on) { Notes.read(); this.update(); $('#panelClose').focus(); } else if (!silent) $('#simChip').focus({ preventScroll: true });
  },
  raf: 0,
  update() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => { this.raf = 0; this.render(); });
  },
  render() {
    const dl = $('#liveState'); if (!dl) return;
    const scr = { boot: 'Booting', welcome: 'Welcome screen', session: S.sess && S.sess.locked ? 'Session, locked' : 'Phosh session', shutdown: 'Shutting down', off: 'Powered off' }[S.scr] || S.scr;
    const t = S.tor;
    const mode = S.applied ? { direct: 'Automatically', bridges: 'Through bridges', offline: 'Offline mode' }[S.applied.network] : 'not chosen yet';
    let torTxt;
    if (!S.applied) torTxt = `network off until Start (DisableNetwork 1) · ${t.pct}% (${t.tag})`;
    else if (S.applied.network === 'offline') torTxt = `network off: offline mode (DisableNetwork 1) · ${t.pct}% (${t.tag})`;
    else if (!t.running && !t.done) torTxt = `waiting for a network connection · ${t.pct}% (${t.tag})`;
    else torTxt = `${t.pct}% (${t.tag}): ${t.summary}${t.stuck ? ' · stuck' : ''}${t.pct > 14 ? ' · acted out: Antumbra\'s Tor has not got past 14 % yet' : ''}`;
    const net = !S.net.present ? (S.applied && S.applied.network === 'offline' ? 'no interface (drivers blocked)' : 'no interface yet') :
      (S.net.ssid ? `wlan0 on “${S.net.ssid}”, ${S.net.ip}` : (S.net.enabled ? 'wlan0, not connected' : 'Wi-Fi off'));
    const own = `${S.net.cur}${S.net.cur !== S.net.hw ? ` (anonymised; before: ${S.net.hw})` : ' (not anonymised)'}`;
    const mac = !S.net.present ? '–' : Wlan.scanning() ? `${Wlan.addr()} (NetworkManager's scan address while not connected) · when connected: ${own}` : own;
    const ps = (Store.exists() ? (S.ram && S.ram.persistent ? 'unlocked' : 'exists, locked') : 'none') +
      (Store.exists() ? ' · simulated, NOT encrypted' : '') + (Store.blocked ? ' · this browser blocks storage: lost at reload' : '');
    const adr = !S.image.android ? 'not in this image' : ({ off: 'off', preparing: 'preparing (antumbra-waydroid)', booting: 'starting', ready: 'running', stopped: 'stopped' }[S.adr.state] + (S.adr.fdroid ? ', F-Droid installed' : ''));
    const cam = { down: 'down', rising: 'rising', up: 'raised (streaming)', lowering: 'lowering' }[S.cam.pos];
    const lock = S.applied ? (S.applied.pwHash ? 'passphrase set' : 'no passphrase (not protective)') : '–';
    dl.innerHTML = `
      <dt>Screen</dt><dd>${esc(scr)}</dd>
      <dt>Tor</dt><dd>${esc(mode)}<div class="torbar" role="progressbar" aria-label="Tor bootstrap" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${t.pct}"><i style="width:${t.pct}%"></i></div><span class="mono">${esc(torTxt)}</span></dd>
      <dt>Network</dt><dd>${esc(net)}</dd>
      <dt>MAC</dt><dd class="mono">${esc(mac)}</dd>
      <dt>Persistent</dt><dd>${esc(ps)}</dd>
      <dt>Android</dt><dd>${esc(adr)}</dd>
      <dt>Pop-up cam</dt><dd>${esc(cam)}</dd>
      <dt>Screen lock</dt><dd>${esc(lock)}</dd>`;
  },
};

/* =================================================================== settings */
/* Port of config/rootfs/usr/lib/python3/dist-packages/antumbra/settings.py */
class SettingsError extends Error {}
const BRIDGE_TRANSPORTS = ['obfs2', 'obfs3', 'obfs4', 'webtunnel', 'meek_lite'];
const ADDRESSED_TRANSPORTS = ['obfs2', 'obfs3', 'obfs4'];
const SNOWFLAKE_REFUSED = 'Snowflake bridges do not work in Antumbra: snowflake reaches its proxies through WebRTC over UDP, and the firewall lets Tor make only TCP connections and DNS queries. Use obfs4 or webtunnel bridges.';
const IPV6_REFUSED = '{address} is an IPv6 address. IPv6 bridges do not work in Antumbra: IPv6 is off, and the firewall lets Tor connect only over IPv4. Use bridges with IPv4 addresses.';
const PYWS = '\\t\\n\\x0b\\x0c\\r\\x1c-\\x1f \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000';   // str.isspace()
const RE_STRIP = new RegExp(`^[${PYWS}]+|[${PYWS}]+$`, 'g');
const RE_WS = new RegExp(`[${PYWS}]+`);
const RE_SPLIT1 = new RegExp(`^([^${PYWS}]+)(?:[${PYWS}]+([\\s\\S]*))?$`);
const pyStrip = s => s.replace(RE_STRIP, '');
const pySplit = s => { const t = pyStrip(s); return t ? t.split(RE_WS) : []; };
const pySplit1 = s => { const t = pyStrip(s); if (!t) return []; const m = t.match(RE_SPLIT1); return m[2] !== undefined ? [m[1], m[2]] : [m[1]]; };
function normaliseBridges(text) {
  return text.split(/[\r\n;]/).map(pyStrip).filter(Boolean).join(';');
}
function bridgeLines(lines) {
  const out = [];
  for (let line of lines) {
    line = pyStrip(line);
    let words = pySplit1(line);
    if (words.length && words[0].toLowerCase() === 'bridge') line = words.length > 1 ? words[1] : '';
    if (!line || line.startsWith('#')) continue;
    words = pySplit(line);
    const kind = words[0];
    if (kind.toLowerCase() === 'snowflake') throw new SettingsError(SNOWFLAKE_REFUSED);
    if (!BRIDGE_TRANSPORTS.includes(kind) && !kind.includes('.') && !kind.includes(':'))
      throw new SettingsError(`Unsupported bridge type: ${kind}. Antumbra takes obfs4, webtunnel, meek_lite, obfs2, obfs3 and plain bridges.`);
    let address;
    if (!BRIDGE_TRANSPORTS.includes(kind)) address = kind;
    else if (ADDRESSED_TRANSPORTS.includes(kind) && words.length > 1) address = words[1];
    else address = '';
    if (address.startsWith('[') || address.split(':').length - 1 > 1) throw new SettingsError(IPV6_REFUSED.replace('{address}', address));
    out.push(line);
  }
  return out;
}
SIM.settings = { normaliseBridges, bridgeLines, SNOWFLAKE_REFUSED, IPV6_REFUSED };

/* ==================================================================== welcome */
const PERS_OPTS = luks => luks
  ? [['none', 'Do not use (amnesic session)'], ['unlock', 'Unlock']]
  : [['none', 'Do not use (amnesic session)'], ['create', 'Create (erases the data partition)']];
const TOR_OPTS = [['direct', 'Automatically'], ['bridges', 'Through bridges (enter below)'], ['offline', 'Offline mode (no network at all)']];
/* the panel's "failed self-check" is a Tor-enforcement ruleset that is not loaded: the self-check
   then fails the firewall and the Android rules, which live in the same nft tables */
const SELFCHECK_FAIL_LINES = ['firewall FAIL: Tor-enforcement ruleset is not loaded or incomplete',
  'firewall-android FAIL: the rules for the Android bridge are not loaded or incomplete'];
/* antumbra-selfcheck: the early run at boot writes /run/antumbra/selfcheck.status; the late run
   (antumbra-selfcheck-late.timer: 4 min after boot, then every 15 min) appends to it */
const Selfcheck = {
  lines(late) {
    const fail = S.image.selfcheckFail;
    const L = fail ? SELFCHECK_FAIL_LINES.slice() : ['firewall OK', 'firewall-android OK'];
    if (S.image.android) L.push('android-bridge OK');
    L.push('lxc-net OK');
    if (!(S.applied && S.applied.android)) L.push('binder OK', 'android-off OK');
    L.push('resolver OK', 'ipv6-disabled OK', 'sysctl OK', 'overlay-root OK', 'swap OK', 'flash-writes OK', 'init-on-free OK', 'pstore OK',
      'radios OK', 'usb-gadget OK', 'usbguard OK', 'modemmanager OK', 'qrtr-access OK');
    if (late) {
      L.push('modem-radio OK', 'modem-registration OK');
      if (S.net.present) L.push(S.applied && !S.applied.mac ? 'mac-wlan0 (anonymization off by choice) OK'
        : Wlan.addr() === S.net.cur ? 'mac-wlan0 OK' : 'mac-wlan0 (scan address) OK');
    }
    return L;
  },
  run(late) {
    const L = this.lines(late);
    S.selfStatus.push(...L);
    J('antumbra-selfcheck', L.join(';') + ';');
    if (late) { S.selfLate++; T.after(900000, () => this.run(true)); }
  },
  boot() { S.selfStatus = []; S.selfLate = 0; this.run(false); T.after(240000, () => this.run(true)); },
};

const Welcome = {
  el: null, persIdx: 0, torIdx: 0, logoutMode: false,
  show() {
    this.logoutMode = S.welcomeApplied;
    this.persIdx = 0; this.torIdx = 0;
    const luks = S.persistState === 'luks';
    const failures = S.image.selfcheckFail ? SELFCHECK_FAIL_LINES : [];
    const entry = (id, title, opts = '') => `
      <div class="w-row entry dis" data-for="${id}">
        <div class="field"><label for="${id}">${esc(title)}</label><input id="${id}" type="${opts.text ? 'text' : 'password'}" autocomplete="off" autocapitalize="off" spellcheck="false" ${opts.text ? 'enterkeyhint="next"' : ''} disabled></div>
        <span class="edit" aria-hidden="true">${ic('document-edit-symbolic')}</span>
        ${opts.text ? '' : `<button class="peek" type="button" aria-label="Show text" aria-pressed="false" disabled>${ic('view-reveal-symbolic')}</button>`}
      </div>`;
    const sw = (id, title, sub, on) => `<div class="w-row switch sub" id="${id}" role="switch" tabindex="0" aria-checked="${on}"><div class="ttl"><span>${title}</span><small>${esc(sub)}</small></div><span class="sw" aria-hidden="true"></span></div>`;
    const el = frag(`<div class="w-root${failures.length ? ' has-banner' : ''}">
      <div class="w-head"><h1>Welcome to Antumbra</h1></div>
      ${failures.length ? `<div class="w-banner" role="alert">${esc('Privacy self-check failed: ' + failures.map(l => l.trim()).join('; ').slice(0, 200))}</div>` : ''}
      <div class="w-mid"><div class="w-scroll" id="wScroll"><div class="w-page">
        <section class="w-group" aria-labelledby="wg1"><div class="w-ghead"><h2 id="wg1">Persistent Storage</h2><p>Encrypted storage that survives shutdown. Everything else is forgotten.</p></div>
          <div class="w-card">
            <button class="w-row combo" type="button" id="wPers" aria-haspopup="listbox" aria-expanded="false"><span class="t">Persistent Storage</span><span class="v" id="wPersV"></span>${ic('pan-down-symbolic')}</button>
            ${entry('wPP', 'Persistent Storage passphrase')}
            ${luks ? '' : entry('wPP2', 'Repeat passphrase')}
          </div></section>
        <section class="w-group" aria-labelledby="wg2"><div class="w-ghead"><h2 id="wg2">Network and Tor</h2></div>
          <div class="w-card">
            ${sw('wMac', 'MAC address anonymization', 'Random Wi-Fi hardware address for this session', true)}
            <button class="w-row combo" type="button" id="wTor" aria-haspopup="listbox" aria-expanded="false"><span class="t">Connect to Tor</span><span class="v" id="wTorV"></span>${ic('pan-down-symbolic')}</button>
            ${entry('wBridges', 'Bridges: obfs4, webtunnel or meek_lite, separated by ;', { text: true })}
          </div></section>
        <section class="w-group" aria-labelledby="wg3"><div class="w-ghead"><h2 id="wg3">Security</h2><p>A passphrase locks the screen. Without one, anyone who picks up the phone can use the session.</p></div>
          <div class="w-card">
            ${entry('wLock', 'Screen-lock passphrase (recommended)')}
            ${entry('wLock2', 'Repeat passphrase')}
            ${sw('wAdmin', 'Administration (sudo) with that passphrase', 'Off by default, as in Tails', false)}
          </div></section>
        ${S.image.android ? `<section class="w-group" aria-labelledby="wg4"><div class="w-ghead"><h2 id="wg4">Android apps</h2><p>Android 13 (LineageOS) in a container, with F-Droid and no Google apps. Its traffic goes only through Tor. Off by default.</p></div>
          <div class="w-card">
            ${sw('wAndroid', '<u class="mn">A</u>ndroid apps (experimental)', 'A weaker sandbox than the rest of Antumbra: use only apps you trust.', false)}
            ${sw('wKeep', 'Keep Android apps and data', "In Persistent Storage, with Android's own usage history", false)}
          </div></section>` : ''}
        <section class="w-group" aria-labelledby="wg5"><div class="w-ghead"><h2 id="wg5">Before you start</h2></div>
          <div class="w-card">
            <div class="w-row text"><span>Tor Browser for arm64 Linux exists only in Tor Project's alpha channel. Tor Project advises people at risk not to rely on alpha releases.</span></div>
            <div class="w-row text"><span>The bootloader is unlocked: an attacker with the phone in hand can replace the system. The orange warning at boot is expected.</span></div>
            <div class="w-row text"><span>The cellular radio stays off. Only Wi-Fi is used, through Tor.</span></div>
          </div></section>
        <section class="w-group"><div class="w-error" id="wError" role="alert"></div></section>
      </div></div></div>
      <div class="w-bottom"><button class="pill-btn" type="button" id="wStart">Start Antumbra</button></div>
    </div>`);
    this.el = el;
    UI.mount('welcome', el);
    $('#wPersV').textContent = PERS_OPTS(luks)[0][1];
    $('#wTorV').textContent = TOR_OPTS[0][1];
    // style: the mnemonic underline shows only while Alt is held (GTK 4)
    $$('u.mn', el).forEach(u => { u.style.textDecoration = 'none'; });
    this.bind(luks);
    this.sens();
    if (this.logoutMode) {
      $$('.w-row', el).forEach(r => { r.classList.add('dis'); r.setAttribute('aria-disabled', 'true'); r.tabIndex = -1; });
      $$('input, .peek, .combo', el).forEach(i => { i.disabled = true; });
      $('#wStart').textContent = 'Start a new session';
    }
    this.shadows();
    Panel.update();
  },
  bind(luks) {
    const el = this.el;
    $('#wPers').addEventListener('click', e => {
      if (this.logoutMode) return;
      popover(e.currentTarget, PERS_OPTS(luks).map(([v, l], i) => ({ value: v, label: l, selected: i === this.persIdx })), {
        role: 'listbox', label: 'Persistent Storage',
        onPick: (it, i) => { this.persIdx = i; $('#wPersV').textContent = it.label; this.sens(); if (it.value === 'create') Persist.sheet($('#wPers')); },
      });
    });
    $('#wTor').addEventListener('click', e => {
      if (this.logoutMode) return;
      popover(e.currentTarget, TOR_OPTS.map(([v, l], i) => ({ value: v, label: l, selected: i === this.torIdx })), {
        role: 'listbox', label: 'Connect to Tor',
        onPick: (it, i) => { this.torIdx = i; $('#wTorV').textContent = it.label; this.sens(); },
      });
    });
    $$('.w-row.switch', el).forEach(r => {
      const toggle = () => {
        if (r.getAttribute('aria-disabled') === 'true') return;
        r.setAttribute('aria-checked', String(r.getAttribute('aria-checked') !== 'true'));
        if (r.id === 'wAndroid') this.sens();
      };
      r.addEventListener('click', toggle);
      r.addEventListener('keydown', e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); toggle(); } });
    });
    $$('.w-row.entry', el).forEach(r => {
      const inp = $('input', r);
      const upd = () => r.classList.toggle('float', document.activeElement === inp || inp.value !== '');
      inp.addEventListener('focus', () => { upd(); setTimeout(() => UI.kb(), 350); setTimeout(() => UI.kb(), 700); });
      inp.addEventListener('blur', upd);
      inp.addEventListener('input', upd);
      // Enter in a text row does not press Start (nothing is connected to entry-activated)
      inp.addEventListener('keydown', e => { if (e.key === 'Enter') e.preventDefault(); });
      r.addEventListener('click', e => { if (!inp.disabled && !e.target.closest('.peek')) inp.focus(); });
      const pk = $('.peek', r);
      if (pk) pk.addEventListener('click', () => {
        const show = inp.type === 'password';
        inp.type = show ? 'text' : 'password';
        pk.setAttribute('aria-pressed', String(show));
        pk.setAttribute('aria-label', show ? 'Hide text' : 'Show text');
        pk.innerHTML = ic(show ? 'view-conceal-symbolic' : 'view-reveal-symbolic');
      });
    });
    // GTK's entry keeps pasted line breaks; an HTML input drops them, so turn them into ';'
    $('#wBridges').addEventListener('paste', e => {
      const t = e.clipboardData && e.clipboardData.getData('text');
      if (!t || !/[\r\n]/.test(t)) return;
      e.preventDefault();
      const inp = e.currentTarget;
      inp.setRangeText(t.replace(/[\r\n]/g, ';'), inp.selectionStart, inp.selectionEnd, 'end');
      inp.dispatchEvent(new Event('input'));
    });
    $('#wScroll').addEventListener('scroll', () => this.shadows(), { passive: true });
    $('#wStart').addEventListener('click', () => this.start());
  },
  shadows() {
    const sc = $('#wScroll'); if (!sc || !this.el) return;
    this.el.classList.toggle('sh-top', sc.scrollTop > 0);
    this.el.classList.toggle('sh-bot', sc.scrollTop + sc.clientHeight < sc.scrollHeight - 1);
  },
  persChoice() { return PERS_OPTS(S.persistState === 'luks')[this.persIdx][0]; },
  setRow(id, on) {
    const inp = $('#' + id); if (!inp) return;
    const row = inp.closest('.w-row');
    inp.disabled = !on;
    const pk = $('.peek', row); if (pk) pk.disabled = !on;
    row.classList.toggle('dis', !on);
    row.setAttribute('aria-disabled', String(!on));
  },
  sens() {
    if (this.logoutMode) return;
    const choice = this.persChoice();
    this.setRow('wPP', choice !== 'none');
    this.setRow('wPP2', choice === 'create');
    this.setRow('wLock', true); this.setRow('wLock2', true);
    this.setRow('wBridges', this.torIdx === 1);
    const keep = $('#wKeep');
    if (keep) {
      const on = choice !== 'none' && $('#wAndroid').getAttribute('aria-checked') === 'true';
      keep.setAttribute('aria-disabled', String(!on));
      keep.classList.toggle('dis', !on);
      keep.tabIndex = on ? 0 : -1;
    }
  },
  /* collect(): the exact order and messages of antumbra-welcome */
  collect() {
    const on = id => { const e = $('#' + id); return !!e && e.getAttribute('aria-checked') === 'true'; };
    const val = id => { const e = $('#' + id); return e ? e.value : ''; };
    const persistence = this.persChoice();
    const pp = val('wPP');
    if (persistence === 'create') {
      if (cpLen(pp) < 12) throw new SettingsError('The Persistent Storage passphrase needs at least 12 characters.');
      if (pp !== val('wPP2')) throw new SettingsError('The Persistent Storage passphrases differ.');
    }
    if (persistence === 'unlock' && pp === '') throw new SettingsError('Enter the Persistent Storage passphrase, or choose not to use it.');
    const mac = on('wMac');
    const network = TOR_OPTS[this.torIdx][0];
    const bridges = normaliseBridges(val('wBridges'));
    let lines = [];
    if (network === 'bridges') {
      lines = bridgeLines(bridges.split(';'));
      if (!lines.length) throw new SettingsError('Enter at least one bridge line, or connect automatically.');
    }
    const pw = val('wLock');
    if (pw !== val('wLock2')) throw new SettingsError('The screen-lock passphrases differ.');
    if (pw !== '' && cpLen(pw) < 6) throw new SettingsError('The screen-lock passphrase needs at least 6 characters.');
    const admin = on('wAdmin');
    if (admin && pw === '') throw new SettingsError('Administration needs a passphrase.');
    let android = false, androidPersistent = false;
    if ($('#wAndroid')) { android = on('wAndroid'); androidPersistent = android && on('wKeep') && persistence !== 'none'; }
    return { persistence, pp, mac, network, bridges, lines, pwHash: pw ? hashPass(pw, S.ram.salt) : '', admin, android, androidPersistent };
  },
  error(msg) {
    const e = $('#wError'); if (!e) return;
    e.textContent = msg;
    this.shadows();
    if (msg) {
      const sc = $('#wScroll');
      const visible = e.getBoundingClientRect().top < sc.getBoundingClientRect().bottom;
      if (!visible) Notes.add('The error is at the end of the page: the Welcome screen does not scroll to it.', {
        action: () => e.scrollIntoView({ block: 'center', behavior: 'smooth' }), act: 'Show it', ms: 9000, force: true });
    }
  },
  async start() {
    const btn = $('#wStart');
    this.error('');
    let s;
    try { s = this.collect(); } catch (err) { if (err instanceof SettingsError) { this.error(err.message); return; } throw err; }
    if (s.persistence === 'create' && Persist.sheet(btn)) return;   // not seen yet: read it first, then Start again
    btn.disabled = true; btn.textContent = 'Applying settings…';
    try {
      if (!S.welcomeApplied) {
        const r = await Applier.run(s);
        if (!r.ok) { this.error(r.message); btn.disabled = false; btn.textContent = 'Start Antumbra'; return; }
      } else await wait(500);
      J('greetd', 'starting the session for amnesia: /usr/libexec/antumbra-session');
      Session.start();
    } catch (err) { if (!(err instanceof Aborted)) throw err; }
  },
};

/* ==================================================================== applier */
const FEATURES = [
  ['persistent-folder', '/home/amnesia/Persistent'], ['welcome-settings', '/var/lib/antumbra/settings/persistent'],
  ['network-connections', '/etc/NetworkManager/system-connections'], ['gnupg', '/home/amnesia/.gnupg'], ['ssh-client', '/home/amnesia/.ssh'],
];
const Applier = {
  async run(s) {
    const A = 'antumbra-apply-welcome-settings', b = S.boot;
    J('systemd', 'antumbra-apply-welcome-settings.path: welcome-done appeared; applying the settings');
    if (s.persistence === 'create') {
      Notes.add('Creating Persistent Storage: on the phone LUKS2, argon2id (1 GiB, 4 iterations), ext4; about 84 s in the VM, 5 s here.', { key: 'create' + S.boot, ms: 7000 });
      if (!Persist.sheetShown) Persist.warn();
      await wait(3200);
      await Store.create(s.pp);
      if (b !== S.boot) throw new Aborted();
      J('antumbra-persistence', 'Persistent Storage created');
      await wait(900);
      J('antumbra-persistence', 'Persistent Storage unlocked');
      await this.activate(s);
    } else if (s.persistence === 'unlock') {
      Notes.add('Unlocking Persistent Storage (argon2id): about 17 s in the VM, 2.5 s here.', { key: 'unlock' + S.boot + J.lines.length, ms: 4000 });
      await wait(2500);
      const good = await Store.check(s.pp);
      if (b !== S.boot) throw new Aborted();
      if (!good) {
        J('antumbra-persistence', 'No key available with this passphrase.');
        J(A, 'wrong passphrase, or Persistent Storage is damaged');
        return { ok: false, message: 'wrong passphrase, or Persistent Storage is damaged' };
      }
      J('antumbra-persistence', 'Persistent Storage unlocked');
      await this.activate(s);
    } else {
      await wait(900);
    }
    if (s.pwHash) { J(A, 'screen-lock passphrase set for amnesia'); if (s.admin) J(A, 'administration enabled'); }
    else J(A, 'no passphrase: screen lock is not protective, administration disabled');
    if (s.android) J(A, 'Android apps enabled for this session');
    if (S.ram.persistent) {
      Store.vol.settings = { macspoof: s.mac, network: s.network, bridges: s.bridges, admin: s.admin, android: s.android, androidPersistent: s.androidPersistent, saved: new Date().toISOString() };
      Store.save();
      J(A, "this boot's settings saved with Persistent Storage (welcome-settings; never the screen-lock hash)");
    }
    await wait(500);
    S.welcomeApplied = true; S.applied = s;
    J(A, 'welcome settings applied');
    return { ok: true };
  },
  async activate(s) {
    await wait(400);
    for (const [f, p] of FEATURES) J('antumbra-persistence', `feature ${f}: ${p}`);
    if (s.android && s.androidPersistent) {
      if (!Store.vol.android) { Store.vol.android = true; Store.save(); J('antumbra-persistence', 'feature android: created'); }
      J('antumbra-persistence', 'feature android: /home/amnesia/.local/share/waydroid');
    }
    S.ram.persistent = true;
  },
};

/* ======================================================================= boot */
const Boot = {
  async run() {
    S.boot++; T.clearAll(); Notes.clear(); closePopover(); closeSheet();
    UI.screen.classList.remove('qs-open');
    freshBootState();
    S.image = { android: Prefs.androidImage, selfcheckFail: Prefs.selfcheckFail };
    S.persistState = Store.exists() ? 'luks' : 'none';
    setPopcam('down', true);
    J('kernel', 'Booting Linux on physical CPU 0x0000000000 [0x51df805e] (simulated)');
    try {
      UI.mount('boot', frag(`<div class="boot"><div class="orange" role="alert"><span class="big">Orange state</span>Your device has been unlocked and can't be trusted.</div>
        <div class="boot-cap"><b>Simulator.</b> The phone's bootloader shows an orange warning at every boot. Only the words "Orange state" and "device has been unlocked and can't be trusted" come from Antumbra's docs; the rest of the screen is left out. Antumbra's Welcome screen says it is expected.</div></div>`));
      await wait(2600);
      UI.mount('boot', frag(`<div class="boot"><div class="boot-cap"><b>Simulator.</b> Booting. A release build boots with "quiet" and no splash: the display stays dark until the panel driver binds. Real: "the first boot can take a minute"; the VM drew the Welcome screen at 302 s.</div></div>`));
      await wait(1800);
      J('tor', 'DisableNetwork is set. Tor will not make or accept non-control network connections. Shutting down all existing connections.');
      J('tor', 'Bootstrapped 0% (starting): Starting');
      J('tor', 'Delaying directory fetches: DisableNetwork is set.');
      J('antumbra-persistence', `status: ${S.persistState === 'luks' ? 'luks' : 'none'}`);
      Selfcheck.boot();
      Welcome.show();
    } catch (err) { if (!(err instanceof Aborted)) throw err; }
  },
};

/* ===================================================================== apps */
const APPS = {
  'tor-browser': { name: 'Tor Browser' },
  'org.gnome.Nautilus': { name: 'Files' },
  'org.gnome.Snapshot': { name: 'Camera' },
  'org.gnome.Console': { name: 'Console' },
  'antumbra-android': { name: 'Android', icon: 'antumbra-android-192', launcher: true },
  'org.gnome.Calculator': { name: 'Calculator' },
  'org.gnome.clocks': { name: 'Clocks' },
  'electrum': { name: 'Electrum Bitcoin Wallet', note: 'Electrum (Qt) is not designed for a 480-pixel-wide screen. Wallets in ~/.electrum are forgotten at every restart.' },
  'org.gnome.Loupe': { name: 'Image Viewer' },
  'fr.romainvigier.MetadataCleaner': { name: 'Metadata Cleaner', note: 'Removes metadata from files before you share them.' },
  'mobi.phosh.MobileSettings': { name: 'Mobile Settings' },
  'org.onionshare.OnionShare': { name: 'OnionShare', note: 'OnionShare (Qt) is not designed for a 480-pixel-wide screen.' },
  'org.gnome.Papers': { name: 'Papers' },
  'org.gnome.World.Secrets': { name: 'Secrets', note: 'A password manager (KeePass format). Keep its database in ~/Persistent to keep it.' },
  'org.gnome.TextEditor': { name: 'Text Editor' },
  'waydroid.org.fdroid.fdroid': { name: 'F-Droid', android: true },
  'waydroid-ui': { name: 'Android', icon: 'antumbra-android-192', hidden: true },
};
const FAVORITES = ['tor-browser', 'org.gnome.Nautilus', 'org.gnome.Snapshot', 'org.gnome.Console'];
const GRID = ['antumbra-android', 'org.gnome.Calculator', 'org.gnome.clocks', 'electrum', 'org.gnome.Loupe', 'fr.romainvigier.MetadataCleaner',
  'mobi.phosh.MobileSettings', 'org.onionshare.OnionShare', 'org.gnome.Papers', 'org.gnome.World.Secrets', 'org.gnome.TextEditor'];
const appIcon = id => icon((APPS[id] && APPS[id].icon) || id);

/* ================================================================== session */
const Session = {
  el: null,
  start() {
    const first = !S.sess || S.sess.boot !== S.boot;
    S.sess = { boot: S.boot, overview: false, drawer: false, locked: false, blank: false, notifs: [], wins: new Map(), front: null,
      dark: true, rot: 'Portrait', feedback: 'On', showAll: false, folderName: 'Android', inFolder: false, lastActive: Date.now() };
    this.build();
    UI.mount('session', this.el);
    J('phosh', 'Phosh 0.46.0 session started for amnesia');
    this.refresh();
    Idle.reset();
    if (S.applied && !S.net.nm && first && !S.ram.sessionStarted) { S.ram.sessionStarted = true; Net.unblock(); }
    if (S.applied && S.applied.android) Android.sessionStart();
    T.after(900, () => Notes.add('Swipe up from the bottom edge (or tap the pill) for the apps; × on an app\'s card there closes it. Pull down the top bar (or tap it) for quick settings.', { key: 'howto', ms: 12000 }));
  },
  build() {
    const el = frag(`<div class="session">
      <div class="wall"></div>
      <div class="applayer" id="apps"></div>
      <div class="overview" id="ov" aria-hidden="true">
        <div class="ov-main">
          <div class="carousel" id="ovCards" aria-label="Running apps"></div>
          <label class="ov-search">${ic('edit-find-symbolic')}<input id="ovSearch" type="text" inputmode="search" enterkeyhint="go" placeholder="Search apps…" aria-label="Search apps" autocomplete="off" autocapitalize="off" spellcheck="false"></label>
          <div class="ov-scroll" id="ovScroll">
            <div class="grid fav" id="ovFav" aria-label="Favorites"></div>
            <div class="sep" id="ovSep"></div>
            <div class="grid apps" id="ovGrid"></div>
            <button class="showall" type="button" id="ovShowAll">${ic('eye-open-negative-filled-symbolic')}<span>Show All Apps</span></button>
          </div>
        </div>
        <div class="folder-page" id="ovFolder">
          <div class="fp-head"><button class="rb" type="button" id="fpBack" aria-label="Back">${ic('go-previous-symbolic')}</button><h3 id="fpName">Android</h3>
            <button class="rb" type="button" id="fpRename" aria-label="Rename folder" aria-pressed="false">${ic('document-edit-symbolic')}</button></div>
          <div class="ov-scroll"><div class="grid apps" id="fpGrid"></div></div>
        </div>
      </div>
      <div class="lock" id="lock" hidden></div>
      <div class="topbar" id="topbar">
        <div class="tb-left" id="tbLeft"></div>
        <div class="clock" id="tbClock"></div>
        <div class="tb-right" id="tbRight"></div>
      </div>
      <div class="homebar" id="homebar"><div class="pill" id="pill"></div><button class="pill-hit" type="button" id="pillHit" aria-label="Open or close the app overview"></button></div>
      <div class="drawer" id="qs" aria-hidden="true" aria-label="Quick settings"></div>
      <div class="banners" id="banners" role="status" aria-live="polite"></div>
      <div class="brightness" id="dim"></div>
    </div>`);
    this.el = el;
    Overview.bind(el); Drawer.build(el); Lock.build(el);
    $('#ov', el).inert = true;
    // top bar: pull down, or tap
    const tb = $('#topbar', el);
    dragY(tb, {
      accept: () => !S.sess.blank,
      onStart: () => Drawer.dragStart(),
      onMove: dy => Drawer.dragMove(dy),
      onEnd: (dy, vy) => Drawer.dragEnd(dy, vy),
    });
    tb.addEventListener('click', e => { if (tb.dataset.dragged || e.target.closest('.sim-chip')) return; Drawer.toggle(); });
    // home bar: swipe up, or tap the pill
    const hb = $('#homebar', el);
    dragY(hb, {
      accept: () => !S.sess.locked && !S.sess.blank,
      onStart: () => Overview.dragStart(), onMove: dy => Overview.dragMove(dy), onEnd: (dy, vy) => Overview.dragEnd(dy, vy),
    });
    $('#pillHit', el).addEventListener('click', () => { if (hb.dataset.dragged) return; if (S.sess.locked) return; Overview.toggle(); });
    $('#dim', el).style.opacity = ((1 - S.brightness) * 0.6).toFixed(2);
  },
  refresh() {
    if (!S.sess || !this.el || S.scr !== 'session') return;
    const now = new Date();
    $('#tbClock').textContent = Clock.top(now);
    // left: Wi-Fi only when a Wi-Fi device exists (cellular and Bluetooth absent on this image)
    let wifi = '';
    if (S.net.present) {
      const nm = !S.net.enabled ? 'network-wireless-disabled-symbolic' : S.net.connecting ? 'network-wireless-acquiring-symbolic'
        : S.net.ssid ? `network-wireless-signal-${Net.find(S.net.ssid).signal}-symbolic` : 'network-wireless-signal-none-symbolic';
      wifi = `<span role="img" aria-label="${esc(S.net.ssid ? 'Wi-Fi connected to ' + S.net.ssid : 'Wi-Fi')}">${ic(nm)}</span>`;
    }
    $('#tbLeft').innerHTML = wifi;
    const lvl = Math.floor(S.battery / 10) * 10;
    $('#tbRight').innerHTML = `<span role="img" aria-label="Battery ${S.battery} percent">${ic(`battery-level-${lvl}-symbolic`)}</span><span class="ind">${S.battery}%</span>`;
    const ovOpen = S.sess.overview;
    $('#apps').classList.toggle('under-ov', ovOpen);
    UI.screen.classList.toggle('ov-open', ovOpen);
    $('#topbar').classList.toggle('clear', ovOpen || S.sess.locked);
    const hb = $('#homebar');
    hb.classList.toggle('clear', ovOpen);
    hb.classList.toggle('nopill', ovOpen);
    hb.hidden = S.sess.locked;
    this.el.classList.toggle('bare', !ovOpen && !S.sess.front && !S.sess.drawer && !S.sess.locked);
    this.el.classList.toggle('light', !S.sess.dark);
    Drawer.refreshClock(now);
    Lock.refreshClock(now);
    Notes.sync();
    Panel.update();
  },
};

const Overview = {
  bind(el) {
    const ov = $('#ov', el);
    $('#ovSearch', el).addEventListener('input', () => this.render());
    $('#ovSearch', el).addEventListener('keydown', e => {
      if (e.key === 'Enter') { const f = $('.appbtn.search-active', ov); if (f) f.click(); }
      if (e.key === 'Escape') this.close();
    });
    $('#ovShowAll', el).addEventListener('click', () => {
      S.sess.showAll = !S.sess.showAll;
      // every visible entry of the image is adaptive or forced: the list does not change
      $('#ovShowAll span').textContent = S.sess.showAll ? 'Show Only Mobile Friendly Apps' : 'Show All Apps';
      $('#ovShowAll').innerHTML = ic(S.sess.showAll ? 'eye-not-looking-symbolic' : 'eye-open-negative-filled-symbolic') + `<span>${S.sess.showAll ? 'Show Only Mobile Friendly Apps' : 'Show All Apps'}</span>`;
      Notes.add('With the image\'s apps, "Show All Apps" adds none: every visible entry is mobile-friendly or forced adaptive.', { key: 'showall' });
    });
    $('#fpBack', el).addEventListener('click', () => this.folder(false));
    $('#fpRename', el).addEventListener('click', e => {
      const b = e.currentTarget, h = $('#fpName');
      if (b.getAttribute('aria-pressed') === 'true') {
        const inp = $('#fpNameInp'); S.sess.folderName = (inp && inp.value.trim()) || S.sess.folderName;
        inp && inp.replaceWith(h); h.textContent = S.sess.folderName; b.setAttribute('aria-pressed', 'false'); this.render();
      } else {
        const inp = frag(`<input id="fpNameInp" type="text" aria-label="Folder name" value="${esc(S.sess.folderName)}">`);
        h.replaceWith(inp); inp.focus(); inp.select(); b.setAttribute('aria-pressed', 'true');
        inp.addEventListener('keydown', ev => { if (ev.key === 'Enter') b.click(); });
      }
    });
    // drag down folds the overview: from the area above the grid, the search pill, or the grid
    // itself while it is scrolled to the top (its touch-action then leaves downward drags to us)
    const sc = $('#ovScroll', el);
    const atTop = () => sc.classList.toggle('at-top', sc.scrollTop <= 0);
    sc.addEventListener('scroll', atTop, { passive: true });
    this.atTop = atTop;
    dragY(ov, {
      accept: e => {
        if (!S.sess.overview || e.target.closest('#fpNameInp')) return false;
        const g = e.target.closest('.ov-scroll');
        return !g || g.scrollTop <= 0;
      },
      onStart: () => ov.classList.add('dragging'),
      onMove: dy => { ov.style.transform = `translateY(${Math.max(0, dy)}px)`; },
      onEnd: (dy, vy) => { ov.classList.remove('dragging'); ov.style.transform = ''; if (dy > 120 || vy > 0.6) this.close(); },
    });
  },
  appButton(id, { search } = {}) {
    const a = APPS[id];
    const b = frag(`<button class="appbtn" type="button" data-app="${id}" aria-label="${esc(a.name)}"><img alt="" src="${appIcon(id)}" draggable="false"><span class="lbl">${esc(a.name)}</span></button>`);
    b.addEventListener('click', () => WM.launch(id));
    attachLongPress(b, () => appMenu(b, id));
    return b;
  },
  folderMembers() {
    const m = ['antumbra-android'];
    if (S.adr.fdroid) m.push('waydroid.org.fdroid.fdroid');
    return m;
  },
  render() {
    if (!S.sess || S.scr !== 'session' || !$('#ovFav')) return;
    const q = ($('#ovSearch') || {}).value ? $('#ovSearch').value.trim().toLowerCase() : '';
    const fav = $('#ovFav'), grid = $('#ovGrid');
    fav.innerHTML = ''; grid.innerHTML = '';
    const androidOn = !!(S.applied && S.applied.android);
    $('#ovSep').hidden = !!q; fav.hidden = !!q; $('#ovShowAll').hidden = !!q;
    if (q) {
      const all = [...FAVORITES, ...GRID, ...(androidOn ? this.folderMembers().slice(1) : [])];
      const hits = all.filter(id => APPS[id].name.toLowerCase().includes(q));
      hits.forEach((id, i) => { const b = this.appButton(id); if (i === 0) b.classList.add('search-active'); grid.append(b); });
    } else {
      FAVORITES.forEach(id => fav.append(this.appButton(id)));
      GRID.forEach(id => {
        if (id === 'antumbra-android' && androidOn) {
          const members = this.folderMembers();
          const f = frag(`<button class="appbtn" type="button" data-folder="android" aria-label="Folder ${esc(S.sess.folderName)}, ${members.length} apps"><span class="fold">${members.map(m => `<img alt="" src="${appIcon(m)}">`).join('')}</span><span class="lbl">${esc(S.sess.folderName)}</span></button>`);
          f.addEventListener('click', () => this.folder(true));
          grid.append(f);
        } else if (id !== 'antumbra-android' || S.image.android) grid.append(this.appButton(id));
      });
    }
    const fp = $('#fpGrid'); fp.innerHTML = '';
    if (androidOn) this.folderMembers().forEach(id => fp.append(this.appButton(id)));
    $('#fpName') && ($('#fpName').textContent = S.sess.folderName);
    this.cards();
    fadeLabels($('#ov'));
  },
  cards() {
    const box = $('#ovCards'); if (!box) return;
    box.innerHTML = '';
    for (const [id] of S.sess.wins) {
      const a = APPS[id];
      const c = frag(`<div class="card-app"><button class="prev" type="button" aria-label="Show ${esc(a.name)}">${esc(a.name)}</button><img alt="" src="${appIcon(id)}"><button class="x" type="button" aria-label="Close ${esc(a.name)}">${ic('app-close-symbolic')}</button></div>`);
      $('.prev', c).addEventListener('click', () => { this.close(); WM.focus(id); });
      $('.x', c).addEventListener('click', () => { WM.close(id); this.cards(); });
      box.append(c);
    }
  },
  folder(on) {
    S.sess.inFolder = on;
    $('#ov').classList.toggle('in-folder', on);
    if (on) { this.render(); const b = $('#fpBack'); b && b.focus({ preventScroll: true }); }
  },
  set(open) {
    if (!S.sess) return;
    S.sess.overview = open;
    const ov = $('#ov');
    ov.classList.toggle('open', open);
    ov.setAttribute('aria-hidden', String(!open));
    ov.inert = !open;
    if (open) {
      const s = $('#ovSearch'); s.value = '';
      this.folder(false); this.render();
      $('#ovScroll').scrollTop = 0; this.atTop && this.atTop();
      Drawer.set(false);
    } else { const a = document.activeElement; if (a && ov.contains(a)) a.blur(); }
    Session.refresh();
  },
  open() { this.set(true); }, close() { if (S.sess && S.sess.overview) this.set(false); },
  toggle() { this.set(!S.sess.overview); },
  dragStart() { const ov = $('#ov'); Notes.sync(true); if (!S.sess.overview) { this.render(); ov.classList.add('dragging'); } },
  dragMove(dy) { if (S.sess.overview) return; const ov = $('#ov'); const h = ov.offsetHeight; ov.style.transform = `translateY(${clamp(h + dy, 0, h)}px)`; },
  dragEnd(dy, vy) {
    const ov = $('#ov'); ov.classList.remove('dragging'); ov.style.transform = '';
    // the home bar is the screen's last 15 px: a short downward swipe there folds the overview
    if (S.sess.overview) { if (dy > 20 || vy > 0.3) this.close(); return; }
    if (-dy > ov.offsetHeight * 0.25 || vy < -0.5) this.open();
    else { const p = $('#pill'); p.classList.remove('shake'); void p.offsetWidth; p.classList.add('shake'); }
  },
};

function attachLongPress(el, fn) {
  let t = 0;
  el.addEventListener('pointerdown', () => { t = setTimeout(() => { t = 0; el.dataset.long = '1'; fn(); }, 550); });
  const cancel = () => { if (t) clearTimeout(t); t = 0; };
  el.addEventListener('pointerup', cancel); el.addEventListener('pointercancel', cancel); el.addEventListener('pointerleave', cancel);
  el.addEventListener('click', e => { if (el.dataset.long) { e.stopImmediatePropagation(); e.preventDefault(); delete el.dataset.long; } }, true);
  el.addEventListener('contextmenu', e => { e.preventDefault(); fn(); });
}
/* long press on an app: its desktop actions, then the favourites entry */
const DESKTOP_ACTIONS = { 'org.gnome.Nautilus': ['New Window'], 'org.gnome.Console': ['New Window', 'New Tab'], electrum: ['Testnet mode'],
  'org.gnome.Papers': ['New Window'], 'org.gnome.TextEditor': ['New Window'], 'waydroid.org.fdroid.fdroid': ['App Settings'] };
function appMenu(anchor, id) {
  const items = (DESKTOP_ACTIONS[id] || []).map(l => ({ label: l, act: 'open' }));
  items.push({ label: FAVORITES.includes(id) ? 'Remove from Favorites' : 'Add to Favorites', act: 'fav' });
  items.push({ label: 'View Details', act: 'details' });
  popover(anchor, items, { label: APPS[id].name, onPick: it => {
    if (it.act === 'open') WM.launch(id);
    else Notes.add(it.act === 'fav' ? 'Favourites are fixed by Antumbra\'s defaults in this simulator; the real list is a GSettings key.' : '"View Details" runs gnome-software, which the image does not have.', { force: true });
  } });
}

/* ------------------------------------------------------------ quick settings */
const Drawer = {
  build(root) {
    const d = $('#qs', root);
    d.innerHTML = `<div class="qs-scroll" id="qsScroll">
      <div class="qs-hdr"><button class="rbtn" type="button" id="qsLock" aria-label="Lock the screen">${ic('padlock-symbolic')}</button>
        <div class="qs-time"><b id="qsTime"></b><span id="qsDate"></span></div>
        <button class="rbtn" type="button" id="qsPower" aria-label="Power menu" aria-haspopup="menu" aria-expanded="false">${ic('system-shutdown-symbolic')}</button></div>
      <div class="slider-row">${ic('display-brightness-symbolic')}${slider('slBright', 'Brightness', S.brightness)}</div>
      <div class="slider-row">${ic('audio-speakers-symbolic')}${slider('slVol', 'Volume', S.volume)}<button class="hbtn" type="button" id="qsAudio" aria-label="Audio devices">${ic('go-next-symbolic')}</button></div>
      <div class="tiles" id="qsTiles"></div>
      <div class="qs-notifs" id="qsNotifs"></div>
    </div>
    <button class="qs-fold" type="button" id="qsFold" aria-label="Close quick settings">${ic('go-down-symbolic', 'up')}</button>`;
    $('.qs-fold .ic', d).style.transform = 'rotate(180deg)';
    $('#qsLock', d).addEventListener('click', () => { this.set(false); Lock.lock(); });
    $('#qsPower', d).addEventListener('click', e => popover(e.currentTarget, [
      { label: 'Power Off…', icon: 'system-shutdown-symbolic', k: 'poweroff' },
      { label: 'Restart…', icon: 'system-reboot-symbolic', k: 'restart' },
      { label: 'Log Out…', icon: 'system-log-out-symbolic', k: 'logout' },
    ], { cls: 'sys', label: 'Power menu', onPick: it => { this.set(false); Power.dialog(it.k); } }));
    bindSlider($('#slBright', d), v => { S.brightness = v; $('#dim').style.opacity = ((1 - v) * 0.6).toFixed(2); });
    bindSlider($('#slVol', d), v => { S.volume = v; });
    $('#qsAudio', d).addEventListener('click', () => this.sub('audio'));
    $('#qsFold', d).addEventListener('click', () => { if (d.querySelector('#qsFold').dataset.dragged) return; this.set(false); });
    dragY($('#qsFold', d), { onStart: () => this.dragStart(), onMove: dy => this.dragMove(dy), onEnd: (dy, vy) => this.dragEnd(dy, vy) });
    dragY(d, { accept: e => S.sess.drawer && !!e.target.closest('.qs-hdr') && !e.target.closest('button'),
      onStart: () => this.dragStart(), onMove: dy => this.dragMove(dy), onEnd: (dy, vy) => this.dragEnd(dy, vy) });
    d.inert = true;
  },
  refreshClock(now) { const t = $('#qsTime'); if (t) { t.textContent = Clock.time(now); $('#qsDate').textContent = Clock.date(now); } },
  tiles() {
    const box = $('#qsTiles'); if (!box) return;
    const n = S.net, ss = S.sess;
    const wifiPresent = n.present;
    const wifiIcon = !wifiPresent || !n.enabled ? 'network-wireless-disabled-symbolic' : n.connecting ? 'network-wireless-acquiring-symbolic'
      : n.ssid ? `network-wireless-signal-${Net.find(n.ssid).signal}-symbolic` : 'network-wireless-signal-none-symbolic';
    const lvl = Math.floor(S.battery / 10) * 10;
    const fbIcon = { On: 'preferences-system-notifications-symbolic', Quiet: 'feedback-quiet-symbolic', Silent: 'notifications-disabled-symbolic' }[ss.feedback];
    const T_ = [
      { id: 'cell', label: 'Cellular', icon: 'network-cellular-disabled-symbolic', dis: true },
      { id: 'wifi', label: n.ssid || 'Wi-Fi', icon: wifiIcon, dis: !wifiPresent, on: wifiPresent && n.enabled, arrow: true },
      { id: 'bt', label: 'Bluetooth', icon: 'bluetooth-disabled-symbolic', dis: true, arrow: true },
      { id: 'bat', label: `${S.battery}%`, icon: `battery-level-${lvl}-symbolic`, static: true },
      { id: 'rot', label: ss.rot, icon: ss.rot === 'Portrait' ? 'screen-rotation-portrait-symbolic' : 'screen-rotation-landscape-symbolic' },
      { id: 'fb', label: ss.feedback, icon: fbIcon, on: ss.feedback === 'On' },
      { id: 'dark', label: ss.dark ? 'Dark mode' : 'Light mode', icon: ss.dark ? 'dark-mode-symbolic' : 'dark-mode-disabled-symbolic', on: ss.dark },
      { id: 'night', label: 'Night Light Off', icon: 'night-light-disabled-symbolic', dis: true },
    ];
    box.innerHTML = T_.map(t => `<div class="tile${t.on ? ' on' : ''}${t.dis ? ' dis' : ''}" data-tile="${t.id}">${t.static
      ? `<div class="main" style="display:flex;align-items:center;gap:6px;padding-left:18px;height:64px;font:500 14px/1.2 var(--font)" role="img" aria-label="Battery ${S.battery} percent">${ic(t.icon)}<span>${esc(t.label)}</span></div>`
      : `<button class="main" type="button" ${t.dis ? 'disabled' : ''} aria-pressed="${!!t.on}">${ic(t.icon)}<span>${esc(t.label)}</span></button>`}${t.arrow ? `<button class="arrow" type="button" ${t.dis ? 'disabled' : ''} aria-label="${esc(t.id === 'wifi' ? 'Wi-Fi networks' : 'Bluetooth devices')}">${ic('go-next-symbolic')}</button>` : ''}</div>`).join('');
    $$('.tile', box).forEach(tile => {
      const id = tile.dataset.tile;
      const main = $('button.main', tile);
      main && main.addEventListener('click', () => this.tap(id));
      const ar = $('.arrow', tile); ar && ar.addEventListener('click', () => this.sub(id));
    });
  },
  tap(id) {
    const ss = S.sess;
    if (id === 'wifi') { Net.setEnabled(!S.net.enabled); }
    if (id === 'rot') { ss.rot = ss.rot === 'Portrait' ? 'Landscape' : 'Portrait'; Notes.add('Without an accelerometer the tile switches the orientation by hand; the simulator keeps the screen upright.', { key: 'rot' }); }
    if (id === 'fb') ss.feedback = { On: 'Quiet', Quiet: 'Silent', Silent: 'On' }[ss.feedback];
    if (id === 'dark') { ss.dark = !ss.dark; if (!ss.dark) Notes.add('Dark mode off: apps and the wallpaper turn light; Phosh itself stays dark. Whether the tile then reads "Light mode" or "Default style" is not in the repository.', { key: 'dark' }); Session.refresh(); }
    this.tiles();
  },
  notifs() {
    const box = $('#qsNotifs'); if (!box) return;
    const list = S.sess.notifs;
    if (!list.length) { box.innerHTML = `<div class="qs-empty">${ic('no-notifications-symbolic')}<b>No notifications</b></div>`; return; }
    box.innerHTML = `<div class="qs-nhead"><b>Notifications</b><button class="clearall" type="button">Clear all</button></div>`;
    $('.clearall', box).addEventListener('click', () => { S.sess.notifs = []; this.notifs(); });
    list.slice().reverse().forEach(n => box.append(notifCard(n)));
  },
  sub(kind) {
    const d = $('#qs');
    const old = $('.qs-sub', d); if (old) old.remove();
    const page = frag(`<div class="qs-sub" role="region"><div class="hb"><button class="hbtn" type="button" aria-label="Back">${ic('go-previous-symbolic')}</button><h3></h3><span class="hend" style="width:38px"></span></div><div class="list"></div><div class="foot"></div></div>`);
    $('.hbtn', page).addEventListener('click', () => page.remove());
    const list = $('.list', page), foot = $('.foot', page);
    if (kind === 'wifi') {
      $('h3', page).textContent = 'Wi-Fi';
      const draw = () => {
        list.innerHTML = '';
        const sc = $('.hend.scan', page); if (sc) sc.style.visibility = S.net.present && S.net.enabled ? '' : 'hidden';
        if (!S.net.present) { list.innerHTML = `<div class="status-empty">${ic('network-wireless-disabled-symbolic')}<p>No Wi-Fi Device Found</p></div>`; return; }
        if (!S.net.enabled) {
          list.innerHTML = `<div class="status-empty"><p>Wi-Fi Disabled</p><button class="pbtn" type="button">Enable Wi-Fi</button></div>`;
          $('button', list).addEventListener('click', () => { Net.setEnabled(true); draw(); });
          return;
        }
        // Phosh's row: the signal icon (acquiring while connecting) with an 8 px padlock badge when
        // secured, the SSID, and a check mark on the active network
        Net.networks.forEach(nw => {
          const cur = S.net.ssid === nw.ssid, conn = S.net.connecting === nw.ssid;
          const sig = conn ? 'network-wireless-acquiring-symbolic' : `network-wireless-signal-${nw.signal}-symbolic`;
          const state = conn ? ', connecting' : cur ? ', connected' : '';
          const r = frag(`<button class="net-row" type="button" aria-label="${esc(nw.ssid + (nw.secure ? ', secured' : '') + state)}"><span class="sig">${ic(sig)}${nw.secure ? ic('network-wireless-encrypted-symbolic', 'badge') : ''}</span><span class="nm">${esc(nw.ssid)}</span>${cur ? ic('object-select-symbolic') : ''}</button>`);
          r.addEventListener('click', () => { if (cur) return Net.disconnect(); Net.ask(nw, draw); });
          list.append(r);
        });
        list.append(frag('<p class="simline">Simulator: these three networks are invented; any password of 8 characters or more joins a secured one.</p>'));
      };
      page._draw = draw;
      // the page header's scan button: a spinner while NetworkManager scans
      const scan = frag('<span class="hend scan" style="width:38px"></span>');
      $('.hend', page).replaceWith(scan);
      const scanBtn = () => {
        scan.innerHTML = `<button class="hbtn" type="button" aria-label="Scan for networks">${ic('view-refresh-symbolic')}</button>`;
        $('button', scan).addEventListener('click', () => {
          if (!S.net.present || !S.net.enabled) return;
          scan.innerHTML = '<span class="spin" role="img" aria-label="Scanning"></span>';
          J('NetworkManager', 'wlan0: Wi-Fi scan requested (scanning with a random MAC address)');
          setTimeout(() => { if (scan.isConnected) { scanBtn(); draw(); } }, 1500);
        });
      };
      scanBtn(); draw();
      const ws = frag('<button class="pbtn" type="button">Wi-Fi Settings</button>');
      ws.addEventListener('click', () => Notes.add('"Wi-Fi Settings" opens GNOME Settings, which the image does not include; Wi-Fi is joined from this list.', { force: true }));
      foot.append(ws);
    } else if (kind === 'bt') {
      $('h3', page).textContent = 'Bluetooth';
      list.innerHTML = '<div class="status-empty"><p>Bluetooth disabled</p></div>';
    } else {
      $('h3', page).textContent = 'Sound';
      list.innerHTML = `<div class="gtk-list"><div><b>Output Devices</b></div><div>Speaker (simulated)</div></div><div class="gtk-list"><div><b>Input Devices</b></div><div>Microphone (simulated)</div></div>`;
      const b = frag('<button class="pbtn" type="button">Sound Settings</button>');
      b.addEventListener('click', () => Notes.add('"Sound Settings" opens GNOME Settings, which the image does not include.', { force: true }));
      foot.append(b);
    }
    d.append(page);
    $('.hbtn', page).focus({ preventScroll: true });
  },
  redrawWifi() { const p = $('#qs .qs-sub'); if (p && p._draw) p._draw(); },
  set(open) {
    if (!S.sess) return;
    S.sess.drawer = open;
    UI.screen.classList.toggle('qs-open', open);
    const d = $('#qs');
    d.classList.toggle('open', open);
    d.classList.toggle('lockmode', S.sess.locked);
    d.setAttribute('aria-hidden', String(!open));
    d.inert = !open;
    if (open) {
      Overview.set(false);
      this.tiles(); this.notifs(); this.refreshClock(new Date());
      const sub = $('.qs-sub', d); if (sub) sub.remove();
      $('#qsScroll').scrollTop = 0;
    } else { closePopover(); const a = document.activeElement; if (a && d.contains(a)) a.blur(); }
    Session.refresh();
  },
  toggle() { this.set(!S.sess.drawer); },
  dragStart() {
    Notes.sync(true);
    const d = $('#qs'); d.classList.add('dragging');
    UI.screen.classList.add('qs-open');
    if (!S.sess.drawer) { d.classList.toggle('lockmode', S.sess.locked); this.tiles(); this.notifs(); this.refreshClock(new Date()); }
  },
  dragMove(dy) {
    const d = $('#qs'), h = d.offsetHeight;
    const y = S.sess.drawer ? clamp(dy, -h, 0) : clamp(-h + dy, -h, 0);
    d.style.transform = `translateY(${y}px)`;
  },
  dragEnd(dy, vy) {
    const d = $('#qs'); d.classList.remove('dragging'); d.style.transform = '';
    const h = d.offsetHeight;
    if (S.sess.drawer) this.set(!(-dy > h * 0.2 || vy < -0.5));
    else this.set(dy > h * 0.25 || vy > 0.5);
  },
};

function slider(id, label, v) {
  return `<div class="slider" id="${id}" role="slider" tabindex="0" aria-label="${label}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(v * 100)}" style="--v:${v}"><div class="fill" style="width:calc(28px + (100% - 28px) * var(--v))"></div><div class="knob" style="left:calc(28px + (100% - 28px) * var(--v))"></div></div>`;
}
function bindSlider(el, onChange) {
  const set = v => { v = clamp(v, 0, 1); el.style.setProperty('--v', v); el.setAttribute('aria-valuenow', Math.round(v * 100)); onChange(v); };
  const at = e => { const r = el.getBoundingClientRect(); return (e.clientX - r.left - 14 * UI.scale) / (r.width - 28 * UI.scale); };
  el.addEventListener('pointerdown', e => {
    e.stopPropagation(); set(at(e));
    try { el.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    const mv = ev => set(at(ev));
    const up = () => { el.removeEventListener('pointermove', mv); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', up); };
    el.addEventListener('pointermove', mv); el.addEventListener('pointerup', up); el.addEventListener('pointercancel', up);
  });
  el.addEventListener('keydown', e => {
    const v = +el.style.getPropertyValue('--v') || 0;
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { e.preventDefault(); set(v + 0.05); }
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { e.preventDefault(); set(v - 0.05); }
  });
}

/* --------------------------------------------------------- notifications */
function notifCard(n) {
  const c = frag(`<div class="ncard" role="group" aria-label="${esc(n.app + ': ' + n.summary)}"><div class="nh"><img alt="" src="${icon(n.icon)}"><b>${esc(n.app)}</b><time>${esc(Clock.time(n.time))}</time></div><div class="nb"><strong>${esc(n.summary)}</strong><p>${esc(n.body)}</p></div></div>`);
  return c;
}
function notify(n) {
  if (!S.sess) return;
  n.time = new Date();
  S.sess.notifs.push(n);
  J('notification', `${n.app}: ${n.summary}`);
  if (S.sess.drawer) Drawer.notifs();
  if (S.sess.locked) return;           // show-in-lock-screen=false
  const box = $('#banners'); if (!box) return;
  const c = notifCard(n);
  c.addEventListener('click', () => c.remove());
  box.innerHTML = ''; box.append(c);
  setTimeout(() => c.remove(), n.timeout || 8000);
}

/* ---------------------------------------------------------------- lock */
const Lock = {
  build(root) {
    const l = $('#lock', root);
    l.innerHTML = `<div class="lock-pages" id="lockPages">
      <div class="lock-page p1" id="lockP1"><div class="lk-clock" id="lkClock"></div><div class="lk-date" id="lkDate"></div>
        <button class="lk-hint" type="button" id="lkHint">${ic('swipe-arrow-symbolic')}<span>Slide up to unlock</span></button></div>
      <div class="lock-page p2" id="lockP2">
        <div class="lk-title" id="lkTitle">Enter Passcode</div>
        <input class="lk-entry" id="lkEntry" type="password" aria-label="Passcode" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="done">
        <div class="keypad" id="keypad"></div>
        <button class="lk-unlock" type="button" id="lkUnlock" disabled>Unlock</button>
      </div></div>`;
    const kp = $('#keypad', l);
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'kb', '0', 'del'].forEach(k => {
      const b = frag(k === 'kb' ? `<button type="button" class="flat" aria-label="Keyboard">${ic('input-keyboard-symbolic')}</button>`
        : k === 'del' ? `<button type="button" class="flat" aria-label="Delete">${ic('edit-clear-symbolic')}</button>` : `<button type="button">${k}</button>`);
      b.addEventListener('click', () => {
        const e = $('#lkEntry');
        if (k === 'kb') { e.focus(); return; }
        if (k === 'del') e.value = e.value.slice(0, -1); else e.value += k;
        this.entryChanged();
      });
      if (k === 'del') attachLongPress(b, () => { $('#lkEntry').value = ''; this.entryChanged(); });
      kp.append(b);
    });
    $('#lkEntry', l).addEventListener('input', () => this.entryChanged());
    $('#lkEntry', l).addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); this.check(); } });
    $('#lkUnlock', l).addEventListener('click', () => this.check());
    $('#lkHint', l).addEventListener('click', e => { e.stopPropagation(); this.page(2); });
    $('#lockP1', l).addEventListener('click', () => { if ($('#lockP1').dataset.dragged) return; this.page(2); });
    dragY($('#lockP1', l), { onMove: dy => { $('#lockPages').style.transform = `translateY(${Math.min(0, dy)}px)`; }, onStart: () => { $('#lockPages').style.transition = 'none'; },
      onEnd: (dy, vy) => { $('#lockPages').style.transition = ''; $('#lockPages').style.transform = ''; if (-dy > 90 || vy < -0.5) this.page(2); } });
    dragY($('#lockP2', l), { accept: e => !e.target.closest('button, input'), onEnd: dy => { if (dy > 90) this.page(1); } });
  },
  refreshClock(now) { const c = $('#lkClock'); if (c) { c.textContent = Clock.time(now); $('#lkDate').textContent = Clock.date(now); } },
  page(n) {
    const l = $('#lock');
    l.classList.toggle('unlocking', n === 2);
    if (n === 2) {
      $('#lkTitle').textContent = 'Enter Passcode';
      if (S.applied && !S.applied.pwHash && !S.ram.lockNoteShown) {
        S.ram.lockNoteShown = true;
        Notes.add('No screen-lock passphrase was set at the Welcome screen, so this lock protects nothing ("the lock is not protective").', { force: true, ms: 8000 });
      }
    }
  },
  entryChanged() { const e = $('#lkEntry'), u = $('#lkUnlock'); if (e && u) u.disabled = e.value === ''; },
  lock() {
    if (!S.sess || S.sess.locked) return;
    S.sess.locked = true;
    Overview.set(false); Drawer.set(false); closePopover(); closeSheet();
    Modal.underLock(true);       // an open system dialog waits under the lock screen, out of reach
    const l = $('#lock'); l.hidden = false; l.classList.remove('unlocking');
    const a = document.activeElement; if (a && Session.el.contains(a)) a.blur();
    $('#lkEntry').value = ''; this.entryChanged();
    $('#apps').inert = true;
    J('phosh', 'screen locked');
    J('systemd', 'Started antumbra-auto-shutdown.timer - Power off after being locked for too long.');
    Session.refresh();
  },
  async check() {
    const e = $('#lkEntry'), v = e ? e.value : '';
    if (!v) return;
    const b = S.boot, sess = S.sess;
    $('#lkTitle').textContent = 'Checking…';
    $('#lkUnlock').disabled = true;
    await new Promise(r => setTimeout(r, 650));
    // the session may have ended meanwhile (power-off, restart, log-out)
    if (b !== S.boot || S.scr !== 'session' || !S.sess || S.sess !== sess || !S.sess.locked || !$('#lkEntry')) return;
    const ok = !S.applied.pwHash || hashPass(v, S.ram.salt) === S.applied.pwHash;
    if (ok) this.unlock();
    else {
      e.classList.remove('shake'); void e.offsetWidth; e.classList.add('shake');
      e.value = ''; this.entryChanged();
      $('#lkTitle').textContent = 'Enter Passcode';
      J('phosh', 'authentication failed');
    }
  },
  unlock() {
    const l = $('#lock');
    if (!S.sess || !l) return;
    S.sess.locked = false;
    l.hidden = true; l.classList.remove('unlocking');
    $('#apps').inert = false;
    Modal.underLock(false);
    const a = document.activeElement; if (a && l.contains(a)) a.blur();
    J('systemd', 'Stopped antumbra-auto-shutdown.timer - Power off after being locked for too long.');
    Idle.reset();
    Session.refresh();
  },
};

const Idle = {
  last: Date.now(),
  reset() { this.last = Date.now(); },
  tick() {
    if (!Prefs.idle || !S.sess || S.scr !== 'session' || S.sess.blank || Panel.isOpen) return;
    if (Date.now() - this.last > 120000) { J('phosh', 'idle for 120 s: blanking the screen'); Power.blank(); }
  },
};

/* ======================================================================= net */
const Net = {
  networks: [
    { ssid: 'Home', secure: true, signal: 'excellent' },
    { ssid: 'Café guest', secure: false, signal: 'good' },
    { ssid: 'Library', secure: true, signal: 'weak' },
  ],
  find(ssid) { return this.networks.find(n => n.ssid === ssid) || { signal: 'ok' }; },
  async unblock() {
    const U = 'antumbra-unblock-network';
    try {
      if (S.applied.network === 'offline') { J(U, 'network disabled by the user (offline mode); leaving drivers blocked'); return; }
      if (S.image.selfcheckFail) {
        J(U, 'refusing to unblock the network: firewall self-check did not pass');
        J('antumbra-apply-welcome-settings', 'network unblock reported an error (see journal)');
        return;
      }
      await wait(700);
      J('kernel', 'ath10k_snoc 18800000.wifi: wlan0: interface added (simulated)');
      if (S.applied.mac) {
        J('spoof-mac', 'Trying to spoof MAC address of NIC wlan0...');
        const hw = S.net.hw.split(':');
        // macchanger -e: bytes 2-3 kept, the last three random; the first byte loses its
        // locally-administered bit (observed in the VM: 52:54:00:a1:7b:01 became 50:54:00:b4:4d:48)
        S.net.cur = [hex2(parseInt(hw[0], 16) & ~2), hw[1], hw[2], hex2(rnd(256)), hex2(rnd(256)), hex2(rnd(256))].join(':');
        await wait(300);
        J('spoof-mac', 'Successfully spoofed MAC address of NIC wlan0');
      } else { S.net.cur = S.net.hw; J('spoof-mac', 'MAC spoofing disabled by the user for wlan0'); }
      S.net.present = true;
      Session.refresh(); Drawer.tiles(); Drawer.redrawWifi();
      await wait(1500);
      S.net.nm = true; Panel.update();
      J('NetworkManager', 'NetworkManager (version 1.52) is starting… (simulated)');
      const saved = S.ram.persistent && Store.vol && Store.vol.wifi && Store.vol.wifi.find(s => this.networks.some(n => n.ssid === s));
      if (saved) { J('NetworkManager', `auto-connecting to the saved network “${saved}” (network-connections feature)`); this.connect(this.find(saved)); }
      else Notes.add('To let Tor connect, join a Wi-Fi network: pull down the top bar (or tap it), then the arrow on the Wi-Fi tile.', {
        key: 'wifi' + S.boot, ms: 10000, action: () => { Drawer.set(true); setTimeout(() => Drawer.sub('wifi'), 260); }, act: 'Wi-Fi' });
    } catch (err) { if (!(err instanceof Aborted)) throw err; }
  },
  ask(nw, redraw) {
    if (!nw.secure) return this.connect(nw, redraw);
    Modal.open(`<h3>Authentication required</h3><p>Enter password for the Wi-Fi network “${esc(nw.ssid)}”</p>
      <div class="dfield"><label for="wifiPw">Password:</label><input id="wifiPw" type="password" autocomplete="off" enterkeyhint="go"></div>
      <p class="simline" style="margin:10px 20px 0">Simulated network: any password of 8 characters or more is accepted.</p>`,
    [{ label: 'Cancel' }, { label: 'Connect', sugg: true, go: () => {
      const v = $('#wifiPw').value;
      if (cpLen(v) < 8) { $('#wifiPw').focus(); Notes.add('A WPA password has at least 8 characters.', { force: true }); return false; }
      this.connect(nw, redraw); return true;
    } }], { label: 'Wi-Fi password', focus: '#wifiPw', overLock: true });
  },
  async connect(nw, redraw) {
    if (!S.net.present || !S.net.enabled) return;
    S.net.connecting = nw.ssid; S.net.ssid = null;
    Session.refresh(); Drawer.tiles(); (redraw || Drawer.redrawWifi.bind(Drawer))();
    J('NetworkManager', `wlan0: connecting to “${nw.ssid}” (scan with a random MAC, no hostname sent, per-boot DHCP client id)`);
    try { await wait(1400); } catch (e) { return; }
    if (S.net.connecting !== nw.ssid) return;
    S.net.connecting = null; S.net.ssid = nw.ssid; S.net.ip = `192.168.${nw.ssid === 'Home' ? 1 : 43}.${20 + rnd(200)}`;
    J('NetworkManager', `wlan0: connected to “${nw.ssid}”, ${S.net.ip}/24`);
    J('nm-dispatcher', '00-firewall.sh: firewall re-applied');
    if (S.ram.persistent && Store.vol && !Store.vol.wifi.includes(nw.ssid)) { Store.vol.wifi.push(nw.ssid); Store.save(); J('NetworkManager', 'connection profile saved in /etc/NetworkManager/system-connections (Persistent Storage)'); }
    Session.refresh(); Drawer.tiles(); Drawer.redrawWifi();
    Tor.dispatch();
  },
  disconnect() {
    if (!S.net.ssid && !S.net.connecting) return;
    J('NetworkManager', `wlan0: disconnected from “${S.net.ssid || S.net.connecting}”`);
    S.net.ssid = null; S.net.connecting = null; S.net.ip = null;
    J('nm-dispatcher', 'last connection down: stopping tails-tor-has-bootstrapped.target');
    Session.refresh(); Drawer.tiles(); Drawer.redrawWifi();
  },
  setEnabled(on) {
    if (!S.net.present) return;
    if (!on) this.disconnect();
    S.net.enabled = on;
    J('NetworkManager', `Wi-Fi ${on ? 'enabled' : 'disabled'}`);
    Session.refresh(); Drawer.tiles(); Drawer.redrawWifi();
  },
};

/* ======================================================================= tor */
const PHASES = { 0: ['starting', 'Starting'], 1: ['conn_pt', 'Connecting to pluggable transport'], 2: ['conn_done_pt', 'Connected to pluggable transport'],
  5: ['conn', 'Connecting to a relay'], 10: ['conn_done', 'Connected to a relay'], 14: ['handshake', 'Handshaking with a relay'],
  15: ['handshake_done', 'Handshake with a relay done'], 20: ['onehop_create', 'Establishing an encrypted directory connection'],
  25: ['requesting_status', 'Asking for networkstatus consensus'], 30: ['loading_status', 'Loading networkstatus consensus'],
  40: ['loading_keys', 'Loading authority key certs'], 45: ['requesting_descriptors', 'Asking for relay descriptors'],
  50: ['loading_descriptors', 'Loading relay descriptors'], 75: ['enough_dirinfo', 'Loaded enough directory info to build circuits'],
  76: ['ap_conn_pt', 'Connecting to pluggable transport to build circuits'], 77: ['ap_conn_done_pt', 'Connected to pluggable transport to build circuits'],
  80: ['ap_conn', 'Connecting to a relay to build circuits'], 85: ['ap_conn_done', 'Connected to a relay to build circuits'],
  89: ['ap_handshake', 'Finishing handshake with a relay to build circuits'], 90: ['ap_handshake_done', 'Handshake finished with a relay to build circuits'],
  95: ['circuit_create', 'Establishing a Tor circuit'], 100: ['done', 'Done'] };
const Tor = {
  dispatch() {   // NetworkManager dispatcher, 10-antumbra-tor.sh, on connection up
    const mode = S.applied.network;
    if (mode === 'offline') return;
    if (mode === 'direct') J('antumbra-tor-connect', 'connecting directly');
    else J('antumbra-tor-connect', `connecting through ${S.applied.lines.length} bridge(s)`);
    S.tor.mode = mode; S.tor.dn = 0;
    if (S.tor.done) { T.after(600, () => { J('systemd', 'Reached target tails-tor-has-bootstrapped.target - Tor has Bootstrapped.'); Panel.update(); }); return; }
    if (S.tor.running) return;
    S.tor.running = true;
    const pt = mode === 'bridges' && S.applied.lines.some(l => BRIDGE_TRANSPORTS.includes(pySplit(l)[0]));
    if (pt) J('tor-pt-configuration-helper', 'Sandbox 0; ClientTransportPlugin obfs2,obfs3,obfs4,webtunnel,meek_lite exec /usr/bin/obfs4proxy');
    J('tor', 'Opened Socks listener connection (ready) on 127.0.0.1:9050');
    J('tor', 'Opened Transparent pf/netfilter listener connection (ready) on 127.0.0.1:9040');
    J('tor', 'Opened DNS listener connection (ready) on 127.0.0.1:5353');
    const seq = pt ? [1, 2, 10, 14, 15, 20, 25, 30, 40, 45, 50, 75, 76, 77, 89, 90, 95, 100] : [5, 10, 14, 15, 20, 25, 30, 40, 45, 50, 75, 80, 85, 89, 90, 95, 100];
    const delays = { 1: 900, 2: 900, 5: 1200, 10: 1500, 14: 500, 15: 600, 20: 600, 25: 600, 30: 800, 40: 700, 45: 700, 50: 900, 75: 1400, 76: 500, 77: 500, 80: 500, 85: 500, 89: 400, 90: 400, 95: 600, 100: 800 };
    let i = 0;
    const step = () => {
      if (!S.net.ssid) { S.tor.running = false; T.after(2000, () => { if (S.net.ssid && !S.tor.done) Tor.dispatch(); }); return; }
      const pct = seq[i++];
      this.phase(pct);
      if (pct === 14 && Prefs.torOutcome === 'stuck') {
        T.after(8000, () => {
          S.tor.stuck = true;
          J('tor', 'Problem bootstrapping. Stuck at 14% (handshake): Handshaking with a relay. (Connection refused; CONNECTREFUSED; count 10; recommendation warn; host A208C66E3BAF32B70920EB6AF8081F7CFA5DB1D1 at 136.243.176.179:9002)');
          J('tor', '9 connections have failed:');
          J('tor', ' 5 connections died in state connect()ing with SSL state (No SSL object)');
          J('tor', ' 4 connections died in state handshaking (Tor, v3 handshake) with SSL state SSL negotiation finished successfully in CLOSED');
          Notes.add('Tor stays at 14 %, as it did in the VM. Nothing on screen says so: the real OS has no Tor indicator.', { key: 'stuck' + S.boot });
          Panel.update();
        });
        return;
      }
      if (pct === 100) {
        S.tor.done = true; S.tor.running = false;
        J('systemd', 'Reached target tails-tor-has-bootstrapped.target - Tor has Bootstrapped.');
        Notes.add(`Tor has bootstrapped (100 %), acted out: Antumbra's Tor has not yet bootstrapped past 14 % anywhere${S.tor.mode === 'bridges' ? ', and no bridge has connected through it yet' : ''}. The real OS shows no notification for this; the Simulator panel and "sudo antumbra-tor-connect status" show it.`, { key: 'tor' + S.boot, ms: 9000 });
        T.after(2200, () => J('htpdate', 'clock set from the median of three pools of HTTPS servers, through Tor (simulated)'));
        Panel.update();
        return;
      }
      T.after(delays[seq[i]] || 600, step);
    };
    T.after(delays[seq[0]], step);
  },
  phase(pct) {
    const [tag, summary] = PHASES[pct];
    Object.assign(S.tor, { pct, tag, summary });
    J('tor', `Bootstrapped ${pct}% (${tag}): ${summary}`);
    Panel.update();
    Browser.refresh();
  },
  statusLines() {
    const t = S.tor;
    return [`NOTICE BOOTSTRAP PROGRESS=${t.pct} TAG=${t.tag} SUMMARY="${t.summary}"`, `enough-dir-info ${t.pct >= 75 ? 1 : 0}`, `DisableNetwork ${t.dn}`];
  },
};

/* =================================================================== android */
const ADR_NOTE = 'Android traffic: TCP to the Internet only, through Tor. UDP (calls, WebRTC, QUIC), VPN apps, IPv6 and .onion addresses do not work. All Android apps share one Tor identity.';
const Android = {
  sessionStart() {
    const a = S.adr;
    if (a.state === 'off') {
      a.state = 'preparing';
      J('systemd', 'Starting antumbra-waydroid.service - Prepare Android apps (Waydroid) for this session...');
      Notes.add('Preparing Android in the background (antumbra-waydroid; the VM took about 63 s). Its folder is in the app grid.', { key: 'adrprep' + S.boot });
      T.after(6000, () => {
        J('antumbra-waydroid', 'waydroid init and upgrade from the images in the read-only system (offline)');
        J('antumbra-waydroid', '7 hardware identifiers masked in the container');
        J('antumbra-waydroid', 'Android apps ready for the session');
        this.boot();
      });
    } else if (a.state === 'stopped') this.boot();
    else if (a.state === 'ready' || a.state === 'booting') { /* new session after logout: container runs again */ this.boot(); }
    Overview.render();
  },
  boot() {
    const a = S.adr;
    J('waydroid', 'Starting up container for a new session');
    if (S.image.selfcheckFail) {
      // the LXC start-host hook (antumbra-waydroid-start-host) fails closed without the Android rules
      a.state = 'stopped';
      J('antumbra-waydroid', "Android container start refused: the firewall's Android nat chain is missing");
      Notes.add('Android does not start: its start hook refuses to start the container without the firewall\'s Android rules, which the failed self-check found missing. The launcher waits for Android forever.', { key: 'adrrefused' + S.boot, force: true, ms: 9000 });
      Panel.update();
      return;
    }
    a.state = 'booting';
    if (S.netIfs) { delete S.netIfs.lxcName; delete S.netIfs.lxcMac; }   // every container start makes a new veth pair
    J('lxc-start', 'Android container checked: Tor only, 7 hardware identifiers hidden in its view');
    Panel.update();
    T.after(16000, () => {
      if (a.state !== 'booting') return;
      a.state = 'ready';
      J('waydroid', 'Android boot completed (sys.boot_completed=1)');
      J('antumbra-waydroid-provision', 'Android setting captive_portal_mode = 0');
      J('antumbra-waydroid-provision', 'Android setting private_dns_mode = off');
      J('antumbra-waydroid-provision', 'Android setting auto_time = 0');
      J('antumbra-waydroid-provision', 'Android setting auto_time_zone = 0');
      const kept = S.applied.androidPersistent && Store.vol && Store.vol.fdroid;
      if (kept) { J('antumbra-fdroid-install', 'F-Droid is already installed'); a.fdroid = true; Overview.render(); }
      else if (!a.fdroid) T.after(5000, () => {
        a.fdroid = true;
        J('antumbra-fdroid-install', 'F-Droid installed');
        if (S.applied.androidPersistent && Store.vol) { Store.vol.fdroid = true; Store.save(); }
        Overview.render(); Panel.update();
        Notes.add('F-Droid installed: it is now in the Android folder. (The real OS logs this; it shows no notification.)', { key: 'fdroid' + S.boot });
      });
      Panel.update();
      if (a.openWhenReady) { a.openWhenReady = false; WM.open('waydroid-ui'); }
    });
  },
  launch() {
    if (!S.applied || !S.applied.android) {
      notify({ app: 'Android', icon: 'antumbra-android-192', summary: 'Android apps are off', body: 'Turn on Android apps on the Welcome screen when you next start Antumbra.' });
      return;
    }
    if (S.adr.state !== 'ready') {
      // antumbra-android-launch notifies only until antumbra-waydroid has written android-ready;
      // after that it runs "waydroid show-full-ui" silently, which starts Android if needed and waits
      if (S.adr.state === 'preparing') notify({ app: 'Android', icon: 'antumbra-android-192', summary: 'Android is starting', body: 'Android opens when it is ready. The first start of a session takes a minute or two.' });
      else Notes.add('Android is prepared, so the launcher shows no notification: "waydroid show-full-ui" starts Android if it is stopped and opens its interface once it has booted.', { key: 'showfull' + S.boot, force: true, ms: 8000 });
      S.adr.openWhenReady = true;
      if (S.adr.state === 'stopped') this.boot();
      return;
    }
    WM.open('waydroid-ui');
  },
  stop() {
    if (!['ready', 'booting'].includes(S.adr.state)) return false;
    S.adr.state = 'stopped';
    WM.close('waydroid-ui'); WM.close('waydroid.org.fdroid.fdroid');
    J('antumbra-waydroid-stopped', "Android stopped: Waydroid's container service stopped, its devices closed");
    Panel.update();
    return true;
  },
};

/* ==================================================================== camera */
function setPopcam(pos, instant) {
  S.cam.pos = pos;
  const p = $('#popcam');
  if (p) {
    p.classList.remove('rising', 'lowering', 'up');
    if (instant) { if (pos === 'up') p.classList.add('up'); }
    else { void p.offsetWidth; if (pos === 'rising') p.classList.add('rising'); if (pos === 'lowering') p.classList.add('lowering'); if (pos === 'up') p.classList.add('up'); }
  }
  const il = $('.cam-illus');
  if (il) {
    il.classList.remove('rising', 'lowering', 'up');
    if (pos !== 'down') il.classList.add(pos);
    $('.cam-illus-t', il) && ($('.cam-illus-t', il).textContent = { rising: 'Front camera rising · 668 ms course', up: 'Front camera raised', lowering: 'Front camera lowering · 668 ms', down: 'Front camera down' }[pos]);
  }
  Panel.update();
}
const MOTOR_MS = 668;
const Camera = {
  create(w) {
    w.el.classList.add('snap');
    w.el.innerHTML = `<div class="hb" style="background:#1d1b20"><span style="width:38px"></span><h3>Camera</h3><span style="width:38px"></span></div><div class="snap-view" style="background:#1d1b20"></div>`;
    w.onClose = () => this.stop();
    if (S.ram.camPerm === null) {
      Modal.open(`<h3>Allow app to Use the Camera?</h3>${ic('camera-photo-symbolic', 'dicon')}<p>An app wants to access camera devices.</p>`,
        [{ label: 'Cancel', go: () => { S.ram.camPerm = false; J('xdg-desktop-portal', 'camera access denied; remembered for this session'); this.ui(w); return true; } },
          { label: 'Ok', sugg: true, go: () => { S.ram.camPerm = true; J('xdg-desktop-portal', 'camera access allowed (one decision for every program, stored as yes)'); this.ui(w); return true; } }],
        { label: 'Allow app to Use the Camera?', focusFirst: true, onDismiss: () => { S.ram.camPerm = false; this.ui(w); } });
    } else this.ui(w);
  },
  /* Snapshot's main menu (camera.ui primary_menu), then the simulator's own items */
  menu(anchor) {
    popover(anchor, [
      { label: 'Preferences', k: 'real' }, { label: 'Keyboard Shortcuts', k: 'real' }, { label: 'About Camera', k: 'real' },
      ...(S.ram.camPerm ? [{ label: 'Simulator: show one of your own pictures', k: 'own' }, { label: 'Simulator: show the test pattern', k: 'bars' }] : []),
      { label: 'Simulator: about the pop-up camera', k: 'info' },
    ], { label: 'Main menu', onPick: it => {
      if (it.k === 'real') Notes.add(`Snapshot's "${esc(it.label)}" is not simulated.`, { force: true });
      if (it.k === 'own') $('#camFile').click();
      if (it.k === 'bars') { S.cam.source = 'bars'; this.view(); }
      if (it.k === 'info') this.info();
    } });
  },
  /* the "permission-denied" page of Snapshot 48 (camera.ui): a header with the menu button, and a status page.
     The AdwHeaderBar there has no title widget, so it shows the window's title, "Camera" (window.ui). */
  denied(w) {
    w.el.classList.remove('snap'); w.el.classList.add('gtk');
    w.el.innerHTML = `<div class="hb snap-hb"><span style="width:38px"></span><h3>Camera</h3><button class="hbtn" type="button" data-k="menu" aria-label="Main Menu" aria-haspopup="menu" aria-expanded="false">${ic('open-menu-symbolic')}</button></div>
      <div class="snap-denied"><div class="status-page">${ic('camera-disabled-symbolic')}<h4>Missing Camera Permission</h4><p>Allow camera usage in Settings</p></div>
      <p class="simline">Simulator: the image has no Settings app; the answer to the portal's prompt lasts until the phone restarts. The front camera stays down.</p></div>`;
    $('[data-k="menu"]', w.el).addEventListener('click', e => this.menu(e.currentTarget));
  },
  ui(w) {
    if (!w.el.isConnected) return;
    if (!S.ram.camPerm) { this.denied(w); return; }
    w.el.innerHTML = `<div class="snap-top"><button class="snap-ib" type="button" data-k="timer" aria-label="Countdown: None" aria-haspopup="menu" aria-expanded="false">${svgTimer()}<small></small></button>
      <div class="snap-modes" role="group" aria-label="Mode"><button type="button" data-m="photo" aria-pressed="true" aria-label="Picture">${svgCam()}</button><button type="button" data-m="video" aria-pressed="false" aria-label="Video">${svgVid()}</button><i></i><button type="button" data-m="qr" aria-pressed="false" aria-label="Scan code">${svgQr()}</button></div>
      <button class="snap-ib" type="button" data-k="menu" aria-label="Main menu" aria-haspopup="menu" aria-expanded="false">${svgMenu()}</button></div>
      <div class="snap-view" id="snapView"></div>
      <div class="snap-bottom"><button class="thumb" type="button" data-k="gallery" aria-label="Open the last picture" hidden></button><button class="shutter" type="button" data-k="shot" aria-label="Take a picture"></button><span></span></div>
      <div class="flash"></div>`;
    w.timer = 0;
    // the countdown is a menu (camera.ui countdown_menu): None, 3s, 5s, 10s
    $('[data-k="timer"]', w.el).addEventListener('click', e => {
      const b = e.currentTarget;
      popover(b, [0, 3, 5, 10].map(n => ({ label: n ? n + 's' : 'None', n, selected: n === w.timer })), { role: 'listbox', label: 'Countdown', onPick: it => {
        w.timer = it.n;
        $('small', b).textContent = w.timer ? w.timer + 's' : '';
        b.setAttribute('aria-label', 'Countdown: ' + (w.timer ? w.timer + 's' : 'None'));
      } });
    });
    $$('.snap-modes button', w.el).forEach(b => b.addEventListener('click', () => {
      $$('.snap-modes button', w.el).forEach(x => x.setAttribute('aria-pressed', String(x === b)));
      if (b.dataset.m !== 'photo') Notes.add(b.dataset.m === 'video' ? 'Video recording is untested on the phone; the simulator takes pictures only.' : 'Snapshot can scan QR codes; the simulator does not.', { force: true });
    }));
    $('[data-k="menu"]', w.el).addEventListener('click', e => this.menu(e.currentTarget));
    $('[data-k="shot"]', w.el).addEventListener('click', () => this.shoot(w));
    $('[data-k="gallery"]', w.el).addEventListener('click', () => WM.open('org.gnome.Loupe'));
    this.view();
    this.startStream();
  },
  view() {
    const v = $('#snapView'); if (!v) return;
    const shutter = $('.snap .shutter');
    const illus = `<div class="cam-illus ${S.cam.pos === 'down' ? '' : S.cam.pos}" role="button" tabindex="0" aria-label="About the pop-up camera"><svg viewBox="0 0 132 52" aria-hidden="true">
        <g class="mod"><rect x="34" y="6" width="16" height="30" rx="4" fill="#3b3742" stroke="#6b6474"/><circle cx="42" cy="14" r="4.5" fill="#12131c" stroke="#7a84b6"/></g>
        <rect x="4" y="30" width="124" height="22" rx="8" fill="#2a2730" stroke="#4a4552"/><rect x="10" y="36" width="112" height="16" rx="3" fill="#141218"/></svg>
        <span class="cam-illus-t">${S.cam.pos === 'up' ? 'Front camera raised' : 'Front camera rising · 668 ms course'}</span></div>`;
    const chip = '<button class="cam-chip" type="button" aria-label="Simulator: the pop-up camera is raised and has no drop protection. More information">Simulator · no drop protection · info</button>';
    if (S.cam.pos !== 'up') {
      v.innerHTML = illus;
    } else if (S.cam.source === 'photo' && S.cam.photo) {
      v.innerHTML = `${chip}<img class="still" alt="Your picture, shown as the front camera's square picture" src="${S.cam.photo}"><div class="cam-cap">Your own still picture: no live video. It stays on this page; nothing is uploaded or stored.</div>`;
    } else {
      v.innerHTML = `${chip}<canvas id="bars" width="640" height="360" aria-label="Colour bars from the VM's virtual camera (vimc)"></canvas><div class="cam-cap">VM test pattern (vimc). On the phone the front camera gives a square 1748×1748 picture.</div>`;
      drawBars($('#bars'));
    }
    const cc = $('.cam-chip', v); if (cc) cc.addEventListener('click', () => this.info());
    const il = $('.cam-illus', v);
    if (il) { il.addEventListener('click', () => this.info()); il.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.info(); } }); }
    if (shutter) shutter.disabled = S.cam.pos !== 'up';
  },
  startStream() {
    if (S.cam.streaming) return;
    S.cam.streaming = true;
    J('pipewire', 'libcamera: starting the stream of the front camera (imx471)');
    J('kernel', 'hotdog-popup-motor: raising the camera before the first frame');
    setPopcam('rising');
    Notes.add('From the project\'s docs (the OS shows no such warning): the pop-up camera has no drop protection. Do not walk with it raised, and do not push it down by hand.', { key: 'drop' + S.boot, force: true, ms: 9000 });
    this.view();
    T.after(MOTOR_MS, () => {
      if (!S.cam.streaming) return;
      J('kernel', `hotdog-popup-motor: open stopped: steps=44160 elapsed_us=${MOTOR_MS * 1000 + rnd(900)} endpoint=1 error=0 (simulated)`);
      setPopcam('up');
      T.after(300, () => this.view());
    });
  },
  stop() {
    if (!S.cam.streaming) return;
    S.cam.streaming = false;
    J('pipewire', 'libcamera: stream stopped');
    if (S.cam.pos === 'down') return;
    setPopcam('lowering');
    Notes.add('Snapshot quit: the stream stopped, so the pop-up camera retracts (one full course, about 668 ms).', { key: 'camlow' + S.boot + J.lines.length, ms: 3500 });
    T.after(MOTOR_MS, () => { J('kernel', `hotdog-popup-motor: close stopped: steps=44160 elapsed_us=${MOTOR_MS * 1000 + rnd(900)} endpoint=1 error=0 (simulated)`); if (!S.cam.streaming) setPopcam('down'); });
  },
  async shoot(w) {
    const sh = $('.snap .shutter'); if (!sh || S.cam.pos !== 'up') return;
    if (w.timer) { sh.disabled = true; for (let t = w.timer; t > 0; t--) { sh.setAttribute('aria-label', `Taking a picture in ${t}`); await new Promise(r => setTimeout(r, 1000)); } sh.disabled = false; sh.setAttribute('aria-label', 'Take a picture'); }
    if (!w.el.isConnected) return;
    const f = $('.flash', w.el); f.classList.remove('go'); void f.offsetWidth; f.classList.add('go');
    const d = new Date();
    const us = String(d.getMilliseconds()).padStart(3, '0') + String(rnd(1000)).padStart(3, '0');
    const name = `Photo from ${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}-${pad2(d.getMinutes())}-${pad2(d.getSeconds())}.${us}.jpeg`;
    const img = await snapshotImage();
    FS.write('Pictures/Camera', { name, img, mtime: Date.now(), own: S.cam.source === 'photo' && !!S.cam.photo });
    J('snapshot', `saved ~/Pictures/Camera/${name}`);
    const th = $('.thumb', w.el); th.hidden = false; th.innerHTML = `<img alt="" src="${img}">`;
    Notes.add(`Saved “${name}” in ~/Pictures/Camera: in RAM, forgotten at shutdown unless moved to ~/Persistent.`, { key: 'shot' + S.boot, ms: 7000 });
  },
  info() {
    sheet(`<h3>The pop-up front camera</h3>
      <p>Snapshot shows the front preview, so the kernel raises the camera first; when the stream stops (Snapshot quits, is killed or switches to a rear camera) the camera retracts. Every start and stop is a full course of the motor.</p>
      <ul><li>Course: nominal about 668 ms (960 microsteps at 105 µs, then 43200 at 13.1 µs), hard cap about 718 ms; stock OxygenOS stops on a timer at about 620 ms. Never measured on hardware.</li>
      <li>The raised camera shows that the front camera is in use, whichever program uses it. It is an indicator, not a security boundary against root. The rear cameras have no indicator at all.</li>
      <li>Asked once per session, but it is not a protection: any program in the session, Tor Browser included, can use the cameras without a prompt (directly, through PipeWire, or by approving itself in the portal), even after Cancel.</li>
      <li>Front camera: one mode, 1748×1748 RAW10, software ISP with untuned parameters, no flash, no touch focus; video recording untested.</li></ul>
      <h3>From the project's docs (the OS shows no such warning)</h3>
      <p>The pop-up front camera has no drop protection: OxygenOS retracts it when the phone falls, on a signal from the sensor DSP, which Antumbra disables. Do not keep the selfie camera open while walking, and do not push a raised camera down by hand.</p>
      <p>Pictures go to ~/Pictures/Camera, which is not a Persistent Storage feature: they are forgotten at shutdown unless moved to ~/Persistent.</p>`);
  },
};
function drawBars(c) {
  if (!c) return;
  const g = c.getContext('2d');
  const cols = ['#c0c0c0', '#c0c000', '#00c0c0', '#00c000', '#c000c0', '#c00000', '#0000c0', '#000000'];
  const w = c.width / cols.length;
  cols.forEach((col, i) => { g.fillStyle = col; g.fillRect(Math.round(i * w), 0, Math.ceil(w), c.height); });
}
async function snapshotImage() {
  const c = document.createElement('canvas'); c.width = 240; c.height = 240;
  const g = c.getContext('2d');
  const still = $('.snap-view img.still');
  if (S.cam.source === 'photo' && still && still.complete && still.naturalWidth) {
    const s = Math.min(still.naturalWidth, still.naturalHeight);
    g.drawImage(still, (still.naturalWidth - s) / 2, (still.naturalHeight - s) / 2, s, s, 0, 0, 240, 240);
  } else {
    g.fillStyle = '#000'; g.fillRect(0, 0, 240, 240);
    const b = $('#bars');
    if (b) { g.save(); g.translate(240, 0); g.scale(-1, 1); g.drawImage(b, 0, 52, 240, 135); g.restore(); }
  }
  try { return c.toDataURL('image/jpeg', 0.7); } catch (e) { return ''; }
}
const svgTimer = () => '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" aria-hidden="true"><circle cx="12" cy="13" r="8"/><path d="M12 13V9M9 2h6M12 13l3 2"/></svg>';
const svgCam = () => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="#fff" stroke-width="2" aria-hidden="true"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>';
const svgVid = () => '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="#fff" stroke-width="2" aria-hidden="true"><rect x="7" y="6" width="13" height="12" rx="2"/><path d="M7 12l-4-3v6z" fill="#fff"/></svg>';
const svgQr = () => '<svg viewBox="0 0 24 24" width="20" height="20" fill="#fff" aria-hidden="true"><path d="M3 3h8v8H3zm2 2v4h4V5zm8-2h8v8h-8zm2 2v4h4V5zM3 13h8v8H3zm2 2v4h4v-4zm8-2h3v3h-3zm5 0h3v3h-3zm-5 5h3v3h-3zm5 0h3v3h-3z"/></svg>';
const svgMenu = () => '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>';

/* ====================================================== system modal dialogs */
const Modal = {
  /* overLock: a dialog opened from the lock screen's own quick settings stays reachable there */
  open(html, buttons, { label = '', focus, focusFirst, onDismiss, overLock } = {}) {
    this.close();
    const m = frag(`<div class="modal-back" role="alertdialog" aria-modal="true" aria-label="${esc(label)}"><div class="dialog">${html}<div class="dbtns"></div></div></div>`);
    buttons.forEach(b => {
      const el = frag(`<button type="button" class="${b.sugg ? 'sugg' : ''}">${esc(b.label)}</button>`);
      el.addEventListener('click', () => { const keep = b.go ? b.go() === false : false; if (!keep) this.close(); });
      $('.dbtns', m).append(el);
    });
    m.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); this.close(); onDismiss && onDismiss(); } });
    (S.sess && Session.el ? Session.el : UI.screen).append(m);
    this.cur = m;
    if (S.sess && S.sess.locked && !overLock) this.underLock(true);
    Notes.sync();
    const f = focus ? $(focus, m) : $('.dbtns button', m);
    if (f) f.focus({ preventScroll: true });
    return m;
  },
  close() { if (this.cur) { this.cur.remove(); this.cur = null; } },
  underLock(on) {
    const m = this.cur; if (!m) return;
    m.classList.toggle('under-lock', on); m.inert = on;
    if (on) { const a = document.activeElement; if (a && m.contains(a)) a.blur(); }
    else { const f = $('input', m) || $('.dbtns button', m); if (f) f.focus({ preventScroll: true }); }
  },
};

/* ===================================================================== files */
const FS = {
  persistentOpen() { return !!(S.ram && S.ram.persistent && Store.vol); },
  dirs(path) {
    if (path === '') {
      const d = ['Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Public', 'Templates', 'Videos'];
      if (this.persistentOpen()) d.splice(4, 0, 'Persistent');
      return d;
    }
    if (path === 'Pictures' && S.ram.fs['Pictures/Camera']) return ['Camera'];
    return [];
  },
  files(path) {
    if (path === 'Persistent') return this.persistentOpen() ? Store.vol.files : [];
    return S.ram.fs[path] || [];
  },
  write(path, file) {
    if (path === 'Persistent') {
      if (!this.persistentOpen()) return false;
      // a picture made from the viewer's own photo never goes into the browser's storage
      if (file.own) file = { name: file.name, img: OWN_PLACEHOLDER, mtime: file.mtime, placeholder: true };
      const i = Store.vol.files.findIndex(f => f.name === file.name);
      if (i >= 0) Store.vol.files[i] = file; else Store.vol.files.push(file);
      Store.save(); return true;
    }
    const list = S.ram.fs[path] || (S.ram.fs[path] = []);
    const i = list.findIndex(f => f.name === file.name);
    if (i >= 0) list[i] = file; else list.push(file);
    return true;
  },
  remove(path, name) {
    if (path === 'Persistent') { Store.vol.files = Store.vol.files.filter(f => f.name !== name); Store.save(); return; }
    S.ram.fs[path] = (S.ram.fs[path] || []).filter(f => f.name !== name);
  },
};
const OWN_PLACEHOLDER = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240"><rect width="240" height="240" fill="#2b292f"/><path d="M60 80h30l12-18h36l12 18h30v96H60z" fill="none" stroke="#948f99" stroke-width="8"/><circle cx="120" cy="126" r="26" fill="none" stroke="#948f99" stroke-width="8"/><path d="M40 40l160 160" stroke="#ffcaa3" stroke-width="8"/></svg>');
const folderSvg = (accent = '#438de6') => `<svg class="fi" viewBox="0 0 36 36" aria-hidden="true"><path d="M3 9a3 3 0 0 1 3-3h8l3 3h13a3 3 0 0 1 3 3v15a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z" fill="${accent}"/><path d="M3 13h30v14a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3z" fill="#62a0ea"/></svg>`;
const fileSvg = () => '<svg class="fi" viewBox="0 0 36 36" aria-hidden="true"><path d="M8 3h14l7 7v21a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" fill="#f6f5f4"/><path d="M22 3v7h7" fill="#c0bfbc"/><path d="M10 16h14M10 20h14M10 24h10" stroke="#9a9996" stroke-width="1.6"/></svg>';
const Files = {
  create(w, path = '') {
    w.path = path; w.el.classList.add('gtk');
    this.draw(w);
  },
  draw(w) {
    const path = w.path;
    const name = path === '' ? 'Home' : path.split('/').pop();
    w.el.innerHTML = `<div class="hb">${path ? `<button class="hbtn" type="button" data-k="up" aria-label="Back">${ic('go-previous-symbolic')}</button>` : '<span style="width:38px"></span>'}<h3>${esc(name)}</h3><button class="hbtn sim-btn" type="button" data-k="new" aria-label="New note in this folder (simulator shortcut)">${ic('document-edit-symbolic')}</button></div>
      <nav class="pathbar" aria-label="Path"></nav><div class="win-body"><div class="flist" role="list"></div></div>`;
    const pb = $('.pathbar', w.el);
    const parts = ['', ...path.split('/').filter(Boolean)];
    parts.forEach((p, i) => {
      const full = parts.slice(1, i + 1).join('/');
      const b = frag(`<button type="button" ${i === parts.length - 1 ? 'aria-current="true"' : ''}>${esc(i === 0 ? 'Home' : p)}</button>`);
      b.addEventListener('click', () => { w.path = full; this.draw(w); });
      pb.append(b);
    });
    const up = $('[data-k="up"]', w.el);
    up && up.addEventListener('click', () => { w.path = path.split('/').slice(0, -1).join('/'); this.draw(w); });
    $('[data-k="new"]', w.el).addEventListener('click', () => Editor.newNote(path === '' ? 'Documents' : path));
    const list = $('.flist', w.el);
    FS.dirs(path).forEach(d => {
      const full = path ? `${path}/${d}` : d;
      const r = frag(`<button class="frow" type="button" role="listitem">${folderSvg(d === 'Persistent' ? '#8f6ee8' : '#438de6')}<span class="fn"><span>${esc(d)}</span>${d === 'Persistent' ? '<small>Persistent Storage</small>' : ''}</span></button>`);
      r.addEventListener('click', () => { w.path = full; this.draw(w); });
      list.append(r);
    });
    const files = FS.files(path);
    files.forEach(f => {
      const r = frag(`<div class="frow" role="listitem"><button type="button" class="frow" style="padding:0;min-height:44px" aria-label="Open ${esc(f.name)}">${f.img ? `<img class="fi" alt="" src="${f.img}" style="border-radius:4px;object-fit:cover">` : fileSvg()}<span class="fn"><span>${esc(f.name)}</span><small>${new Date(f.mtime).toLocaleString()}</small></span></button><button class="more" type="button" aria-label="More for ${esc(f.name)}" aria-haspopup="menu">⋮</button></div>`);
      $('button.frow', r).addEventListener('click', () => { if (f.img) Viewer.show(f); else Editor.open(path, f); });
      $('.more', r).addEventListener('click', e => {
        const items = [];
        if (path !== 'Persistent' && FS.persistentOpen()) items.push({ label: 'Move to Persistent', k: 'mv' });
        items.push({ label: 'Move to Trash', k: 'rm' });
        popover(e.currentTarget, items, { label: f.name, onPick: it => {
          if (it.k === 'mv') {
            FS.write('Persistent', f); FS.remove(path, f.name); J('nautilus', `moved “${f.name}” to ~/Persistent`);
            if (f.own) Notes.add('Simulator: your own picture is not copied into this browser\'s storage; a placeholder stands for it in Persistent.', { force: true, ms: 9000 });
            Persist.warn();
          }
          else { FS.remove(path, f.name); }
          this.draw(w);
        } });
      });
      list.append(r);
    });
    if (!FS.dirs(path).length && !files.length) list.append(frag('<p class="empty-folder">Folder is Empty</p>'));
    if (path === 'Persistent' && !files.length) {
      const h = frag(`<div class="hint-card"><b>Simulator</b><br>Files here are kept in the simulated Persistent Storage and survive a restart. Write one with Text Editor.<br><button class="pbtn accent" type="button">New note here</button></div>`);
      $('button', h).addEventListener('click', () => Editor.newNote('Persistent'));
      list.append(h);
    }
    if (path === '' && !FS.persistentOpen()) list.append(frag('<div class="hint-card"><b>Simulator</b><br>No Persistent folder: this session runs without Persistent Storage, so everything here is forgotten at shutdown.</div>'));
  },
  refreshAll() { for (const [id, w] of S.sess ? S.sess.wins : []) if (id === 'org.gnome.Nautilus') this.draw(w); },
};

const Editor = {
  target: null,
  newNote(folder) { this.target = { folder, file: null }; WM.close('org.gnome.TextEditor'); WM.open('org.gnome.TextEditor'); },
  open(folder, f) { this.target = { folder, file: f }; WM.close('org.gnome.TextEditor'); WM.open('org.gnome.TextEditor'); },
  create(w) {
    const t = this.target || { folder: 'Documents', file: null };
    this.target = null;
    w.folder = t.folder; w.file = t.file;
    const title = t.file ? t.file.name : 'New Document';   // gnome-text-editor 48's title for an unsaved document
    w.el.classList.add('gtk');
    w.el.innerHTML = `<div class="hb"><span style="width:38px"></span><h3>${esc(title)}</h3><button class="hbtn txt" type="button" data-k="save">Save</button></div>
      <textarea class="editor" aria-label="Document text" spellcheck="false">${esc(t.file ? t.file.text || '' : '')}</textarea>`;
    $('[data-k="save"]', w.el).addEventListener('click', () => this.saveDialog(w));
  },
  saveDialog(w) {
    const pOpen = FS.persistentOpen();
    const def = w.file ? w.file.name : 'New Document.txt';
    const folder = w.folder === 'Persistent' && !pOpen ? 'Documents' : w.folder;
    const page = frag(`<div class="win" style="z-index:2"><div class="hb"><button class="hbtn txt" type="button" data-k="cancel">Cancel</button><h3>Save File</h3><button class="hbtn txt" type="button" data-k="ok" style="color:var(--primary)">Save</button></div>
      <div class="win-body"><div class="form"><label for="saveName">Name</label><input id="saveName" type="text" value="${esc(def)}" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="done">
        <span style="font-size:13px;color:#a9a3b1">Folder</span>
        ${[['', 'Home'], ['Documents', 'Documents'], ['Persistent', 'Persistent']].map(([v, l]) => `<label class="radio"><input type="radio" name="saveDir" value="${v}" ${v === folder ? 'checked' : ''} ${v === 'Persistent' && !pOpen ? 'disabled' : ''}>${l}${v === 'Persistent' && !pOpen ? ' <small style="color:#8d8794">(Persistent Storage not unlocked)</small>' : ''}</label>`).join('')}
      </div></div></div>`);
    w.el.append(page);
    $('#saveName', page).focus({ preventScroll: true });
    $('[data-k="cancel"]', page).addEventListener('click', () => page.remove());
    const save = () => {
      const name = ($('#saveName', page).value || '').trim() || 'New Document.txt';
      const dir = ($('input[name="saveDir"]:checked', page) || {}).value || '';
      const file = { name, text: $('textarea', w.el).value, mtime: Date.now() };
      FS.write(dir, file);
      w.file = file; w.folder = dir;
      $('.hb h3', w.el).textContent = name;
      page.remove();
      J('gnome-text-editor', `saved ~/${dir ? dir + '/' : ''}${name}`);
      Notes.add(dir === 'Persistent' ? `Saved “${esc(name)}” in ~/Persistent: kept across restarts, in plain text in this browser's storage (the simulated volume is not encrypted).` : `Saved “${esc(name)}” in ~/${esc(dir || '')}: in RAM, forgotten at shutdown.`, { force: true, ms: 7000 });
      if (dir === 'Persistent') Persist.warn();
      Files.refreshAll();
    };
    $('[data-k="ok"]', page).addEventListener('click', save);
    $('#saveName', page).addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); save(); } });
  },
};

const Viewer = {
  pending: null,
  show(f) { this.pending = f; WM.close('org.gnome.Loupe'); WM.open('org.gnome.Loupe'); },
  create(w) {
    w.el.classList.add('gtk');
    const photos = FS.files('Pictures/Camera');
    const f = this.pending || photos[photos.length - 1];
    this.pending = null;
    if (!f) { gtkWin(w, 'Image Viewer', placeholder('org.gnome.Loupe', 'Image Viewer', 'Open an image from Files. Pictures taken with Camera are in ~/Pictures/Camera.')); return; }
    w.el.innerHTML = `<div class="hb"><span style="width:38px"></span><h3>${esc(f.name)}</h3><span style="width:38px"></span></div><div class="win-body" style="display:grid;place-items:center;background:#000"><img alt="${esc(f.name)}" src="${f.img}" style="max-width:100%;max-height:100%">${f.placeholder ? '<p class="simline" style="position:absolute;bottom:12px;left:12px;right:12px;max-width:none">Simulator: a picture made from your own photo is not kept in this browser\'s storage; this placeholder stands for it.</p>' : ''}</div>`;
  },
};

/* =================================================================== console */
const Term = {
  create(w) {
    w.el.classList.add('term');
    w.el.innerHTML = `<div class="hb"><span style="width:38px"></span><h3>amnesia@amnesia:~</h3><span style="width:38px"></span></div>
      <div class="term-out" role="log" aria-live="polite" aria-label="Console output"></div>
      <div class="term-keys">${['help', 'ip a', 'whoami', 'sudo antumbra-tor-connect status', 'torify curl example.org', 'clear'].map(c => `<button type="button" data-c="${esc(c)}">${esc(c)}</button>`).join('')}</div>
      <form class="term-in" autocomplete="off"><span class="ps">amnesia@amnesia:~$</span><input type="text" aria-label="Command" autocapitalize="off" autocomplete="off" spellcheck="false" enterkeyhint="send"></form>`;
    w.out = $('.term-out', w.el); w.inp = $('.term-in input', w.el); w.ps = $('.term-in .ps', w.el);
    w.hist = []; w.hi = 0; w.pending = null;
    $('.term-in', w.el).addEventListener('submit', e => { e.preventDefault(); this.enter(w); });
    w.inp.addEventListener('keydown', e => {
      if (e.key === 'ArrowUp' && !w.pending && w.hist.length) { e.preventDefault(); w.hi = Math.max(0, w.hi - 1); w.inp.value = w.hist[w.hi]; }
      if (e.key === 'ArrowDown' && !w.pending && w.hist.length) { e.preventDefault(); w.hi = Math.min(w.hist.length, w.hi + 1); w.inp.value = w.hist[w.hi] || ''; }
    });
    $$('.term-keys button', w.el).forEach(b => b.addEventListener('click', () => { if (w.pending) return; w.inp.value = b.dataset.c; this.enter(w); }));
    this.print(w, '<span class="simt">Simulated shell: a few commands answer as Antumbra would; type help.</span>', true);
  },
  print(w, s, html) { const d = document.createElement('div'); if (html) d.innerHTML = s; else d.textContent = s; w.out.append(d); w.out.scrollTop = w.out.scrollHeight; },
  enter(w) {
    const v = w.inp.value; w.inp.value = '';
    if (w.pending) { const p = w.pending; w.pending = null; w.inp.type = 'text'; w.ps.textContent = 'amnesia@amnesia:~$'; p(v); return; }
    this.print(w, `<span class="pr">amnesia@amnesia</span>:<span class="pth">~</span>$ ${esc(v)}`, true);
    const cmd = v.trim();
    if (cmd) { w.hist.push(cmd); w.hi = w.hist.length; }
    this.run(w, cmd);
  },
  /* amnesia always has one sudoers rule (sudoers.d/antumbra-tor-browser: the Tor Browser
     launcher only); "ALL" only with Administration on. Without a passphrase the password is deleted
     (passwd -d) and pam_unix's nullok lets sudo authenticate without a prompt. */
  sudoRefused(w, args) {
    const PATHS = { 'antumbra-tor-connect': '/usr/local/sbin/antumbra-tor-connect', 'antumbra-persistence': '/usr/local/sbin/antumbra-persistence',
      cat: '/usr/bin/cat', whoami: '/usr/bin/whoami', journalctl: '/usr/bin/journalctl', id: '/usr/bin/id', ip: '/usr/sbin/ip', waydroid: '/usr/bin/waydroid' };
    const cmd = [PATHS[args[0]] || args[0], ...args.slice(1)].join(' ');
    this.print(w, `Sorry, user amnesia is not allowed to execute '${cmd}' as root on amnesia.`);
    this.print(w, `<span class="simt">(${S.applied.pwHash ? 'Administration was off at the Welcome screen' : 'No screen-lock passphrase was set, so administration is off'}: amnesia's only sudo rule runs the Tor Browser launcher. The simulator's sudo texts follow sudo's usual wording.)</span>`, true);
  },
  sudo(w, args, then) {
    if (!S.applied.pwHash) { this.sudoRefused(w, args); return; }
    let tries = 0;
    const ask = () => {
      w.ps.textContent = '[sudo] password for amnesia:'; w.inp.type = 'password'; w.inp.focus({ preventScroll: true });
      w.pending = pw => {
        if (hashPass(pw, S.ram.salt) !== S.applied.pwHash) {
          tries++;
          if (tries >= 3) { this.print(w, 'sudo: 3 incorrect password attempts'); return; }
          this.print(w, 'Sorry, try again.'); ask(); return;
        }
        if (!S.applied.admin) { this.sudoRefused(w, args); return; }
        then();
      };
    };
    ask();
  },
  run(w, cmd) {
    const out = s => this.print(w, s);
    const args = cmd.split(/\s+/).filter(Boolean);
    if (!args.length) return;
    if (args[0] === 'sudo') {
      const rest = args.slice(1);
      if (!rest.length) { out('usage: sudo -h | -K | -k | -V'); return; }
      this.sudo(w, rest, () => this.root(w, rest));
      return;
    }
    switch (args[0]) {
      case 'help':
        this.print(w, `<span class="simt">Commands in this simulator: whoami, id, hostname, uname -a, ip a, cat /etc/resolv.conf, cat /run/antumbra/selfcheck.status, ls, pwd, date, curl, torify curl, sudo antumbra-tor-connect status|direct|disconnect, sudo antumbra-persistence status, waydroid session stop, clear, exit.</span>`, true); break;
      case 'whoami': out('amnesia'); break;
      case 'hostname': out('amnesia'); break;
      case 'id': out('uid=1000(amnesia) gid=1000(amnesia) groups=1000(amnesia),29(audio),30(dip),44(video),46(plugdev),100(users),102(netdev),992(render),996(input)'); break;
      case 'uname':
        if (args[1] === '-a') {
          out('Linux amnesia 6.17.0-sm8150-hotdog-clean-antumbra #6 SMP PREEMPT Tue Oct  6 17:18:24 UTC 2026 aarch64 GNU/Linux');
          this.print(w, '<span class="simt">(The release names the SoC and the phone\'s port; Android apps can read it too. Build number and date are those of the VM\'s kernel build.)</span>', true);
        } else if (args[1] === '-r') out('6.17.0-sm8150-hotdog-clean-antumbra');
        else out('Linux');
        break;
      case 'pwd': out('/home/amnesia'); break;
      case 'date': out(new Date().toString()); break;
      case 'ls': out(FS.dirs('').join('  ')); break;
      case 'clear': w.out.innerHTML = ''; break;
      case 'exit': WM.close('org.gnome.Console'); break;
      case 'ip': if (args[1] === 'a' || args[1] === 'addr' || args[1] === 'address') this.ipa(w); else out('Usage: ip a (the simulator knows only this one)'); break;
      case 'cat':
        if (args[1] === '/etc/resolv.conf') out('nameserver 127.0.0.1');
        else if (args[1] === '/run/antumbra/selfcheck.status') this.selfcheck(w);
        else if (args[1] === '/etc/hostname') out('amnesia');
        else out(`cat: ${args[1] || ''}: No such file or directory (simulated)`);
        break;
      case 'antumbra-tor-connect': case 'antumbra-persistence':
        out(`bash: ${args[0]}: command not found`);
        this.print(w, `<span class="simt">(It lives in /usr/local/sbin, outside amnesia's PATH, and needs root: use sudo.)</span>`, true); break;
      case 'ping':
        out('bash: ping: command not found');
        this.print(w, '<span class="simt">(The image has no ping. The firewall would reject ICMP from amnesia anyway: only TCP through Tor and DNS to Tor\'s DNSPort are allowed.)</span>', true); break;
      case 'torify': case 'torsocks': case 'curl': {
        const url = args.find(a => /\./.test(a) && !a.startsWith('-')) || 'example.org';
        if (!S.net.ssid) { out(`curl: (6) Could not resolve host: ${url}`); this.print(w, '<span class="simt">(No network connection: join a Wi-Fi network from quick settings.)</span>', true); break; }
        if (!S.tor.done) { out(`curl: (6) Could not resolve host: ${url}`); this.print(w, `<span class="simt">(Tor has not bootstrapped (${S.tor.pct} %): lookups through its DNSPort get no address yet.)</span>`, true); break; }
        this.print(w, `<span class="simt">${args[0] === 'curl' ? 'curl as amnesia: the firewall redirects its TCP to Tor\'s TransPort 9040 and its DNS to Tor\'s DNSPort, so the request goes through Tor.' : `${esc(args[0])} sends curl through Tor's SocksPort 9050.`} The simulator sends nothing and shows no page.</span>`, true);
        break;
      }
      case 'waydroid':
        if (args[1] === 'session' && args[2] === 'stop') { if (!Android.stop()) out('[waydroid] WayDroid session is not started'); }
        else out('usage: waydroid session stop (the simulator knows only this one)');
        break;
      default: out(`bash: ${args[0]}: command not found`);
    }
  },
  root(w, args) {
    const out = s => this.print(w, s);
    if (args[0] === 'antumbra-tor-connect') {
      const c = args[1];
      if (c === 'status') Tor.statusLines().forEach(out);
      else if (c === 'disconnect') { S.tor.dn = 1; out('network disabled for Tor'); Panel.update(); }
      else if (c === 'direct') { out('connecting directly'); S.tor.dn = 0; Panel.update(); }
      else out('usage: antumbra-tor-connect direct | bridges FILE|- | status | disconnect');
    } else if (args[0] === 'antumbra-persistence') {
      if (args[1] === 'status') out(Store.exists() ? 'luks' : 'none');
      else out('usage: antumbra-persistence status (the simulator knows only this one)');
    } else if (args[0] === 'cat' && args[1] === '/run/antumbra/selfcheck.status') this.selfcheck(w);
    else if (args[0] === 'whoami') out('root');
    else if (args[0] === 'journalctl') J.lines.slice(-15).forEach(out);
    else out(`sudo: ${args[0]}: command not found (simulated)`);
  },
  selfcheck(w) {
    S.selfStatus.forEach(l => this.print(w, l));
    this.print(w, `<span class="simt">(${S.selfLate ? `The early run at boot, then ${S.selfLate} late ${S.selfLate === 1 ? 'run' : 'runs'} appended.` : 'The early run at boot. The late run, 4 minutes after boot and then every 15 minutes, appends the same checks plus the modem\'s and the Wi-Fi MAC address\'s.'})</span>`, true);
  },
  ipa(w) {
    const out = s => this.print(w, s);
    out('1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000');
    out('    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00');
    out('    inet 127.0.0.1/8 scope host lo');
    out('       valid_lft forever preferred_lft forever');
    // antumbra-create-netns at boot: five namespaces, each with a /30 veth pair (the peer, veth0,
    // inside the namespace), then the Android bridge in every image with Android, Android on or off
    const nm = S.netIfs || (S.netIfs = { mac: () => [hex2((rnd(64) << 2) | 2), ...Array.from({ length: 5 }, () => hex2(rnd(256)))].join(':') });
    const mac = k => nm[k] || (nm[k] = nm.mac());
    let n = 2;
    [['tbb', 1], ['onioncircs', 5], ['tca', 9], ['onionshare', 13], ['clearnet', 17]].forEach(([ns, a]) => {
      const peer = n++, idx = n++;
      out(`${idx}: veth-${ns}@if${peer}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000`);
      out(`    link/ether ${mac(ns)} brd ff:ff:ff:ff:ff:ff link-netns ${ns}`);
      out(`    inet 10.200.1.${a}/30 scope global veth-${ns}`);
      out('       valid_lft forever preferred_lft forever');
    });
    const attached = S.image.android && ['booting', 'ready'].includes(S.adr.state);
    if (S.image.android) {
      out(`${n++}: waydroid-tor: <${attached ? 'BROADCAST,MULTICAST,UP,LOWER_UP' : 'NO-CARRIER,BROADCAST,MULTICAST,UP'}> mtu 1500 qdisc noqueue state ${attached ? 'UP' : 'DOWN'} group default qlen 1000`);
      out(`    link/ether ${mac('br')} brd ff:ff:ff:ff:ff:ff`);
      out('    inet 10.200.2.1/30 scope global waydroid-tor');
      out('       valid_lft forever preferred_lft forever');
    }
    if (S.net.present) {
      const up = !!S.net.ssid;
      out(`${n++}: wlan0: <${up ? 'BROADCAST,MULTICAST,UP,LOWER_UP' : 'NO-CARRIER,BROADCAST,MULTICAST,UP'}> mtu 1500 qdisc mq state ${up ? 'UP' : 'DOWN'} group default qlen 1000`);
      const addr = Wlan.addr();
      out(`    link/ether ${addr} brd ff:ff:ff:ff:ff:ff${addr !== S.net.hw ? ` permaddr ${S.net.hw}` : ''}`);
      if (up) { out(`    inet ${S.net.ip}/24 brd ${S.net.ip.split('.').slice(0, 3).join('.')}.255 scope global dynamic noprefixroute wlan0`); out('       valid_lft 86321sec preferred_lft 86321sec'); }
    }
    if (attached) {
      // the host end of the container's veth pair, enslaved to the bridge: LXC names it vethXXXXXX
      // at random and sets the first byte of its MAC to fe (so the bridge never takes its address)
      const name = nm.lxcName || (nm.lxcName = 'veth' + Array.from({ length: 6 }, () => '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'[rnd(62)]).join(''));
      const lxcMac = nm.lxcMac || (nm.lxcMac = ['fe', ...Array.from({ length: 5 }, () => hex2(rnd(256)))].join(':'));
      out(`${n++}: ${name}@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master waydroid-tor state UP group default qlen 1000`);
      out(`    link/ether ${lxcMac} brd ff:ff:ff:ff:ff:ff link-netnsid 5`);
    }
    const scan = Wlan.scanning() ? ` wlan0 is not connected, so NetworkManager's random scan address (wifi.scan-rand-mac-address=yes) is on it now; connecting puts back the ${S.net.cur !== S.net.hw ? 'anonymised address' : 'driver\'s address'}, ${S.net.cur}.` : '';
    const note = !S.net.present ? (S.applied.network === 'offline' ? 'Offline mode: the network drivers stay blocked, so no Wi-Fi interface exists.' : 'No Wi-Fi interface yet.')
      : S.net.cur !== S.net.hw ? `MAC address anonymization: macchanger -e kept bytes 2 and 3, randomised the last three and cleared the first byte's locally-administered bit, as in the VM; permaddr is the address the driver gave (random at every boot on this port).${scan} No inet6 lines: IPv6 is disabled.`
        : `MAC address anonymization was off: the driver's address is used.${scan} No inet6 lines: IPv6 is disabled.`;
    this.print(w, `<span class="simt">(${esc(note)})</span>`, true);
  },
};

/* =============================================================== tor browser */
const Browser = {
  create(w) {
    w.el.classList.add('tb');
    w.el.innerHTML = `<div class="tb-tabs"><div class="tb-tab"><span>New Tab</span><button class="hbtn" type="button" data-k="closetab" aria-label="Close tab" style="width:30px;height:30px">✕</button></div><button class="hbtn" type="button" data-k="newtab" aria-label="New tab" style="font-size:22px">+</button></div>
      <div class="tb-nav"><button class="hbtn" type="button" aria-label="Back" disabled>${ic('go-previous-symbolic')}</button><button class="hbtn" type="button" aria-label="Forward" disabled>${ic('go-next-symbolic')}</button><button class="hbtn" type="button" data-k="reload" aria-label="Reload">${ic('view-refresh-symbolic')}</button><input class="tb-url" type="text" inputmode="url" enterkeyhint="go" placeholder="Search or enter address" aria-label="Search or enter address" autocomplete="off" autocapitalize="off" spellcheck="false"></div>
      <div class="tb-imp"><span aria-hidden="true">⇲</span><button type="button" data-k="import">Import bookmarks…</button></div>
      <div class="tb-info" role="status"><span aria-hidden="true">ⓘ</span><div style="flex:1;min-width:0"><p>Tor Browser Alpha has set your display language based on your system’s language.</p><button class="ib" type="button" data-k="lang">Change Language…</button></div><button class="x" type="button" data-k="closeinfo" aria-label="Close">✕</button></div>
      <div class="tb-page" id="tbPage"></div>`;
    w.url = '';
    $('[data-k="closeinfo"]', w.el).addEventListener('click', e => e.currentTarget.closest('.tb-info').remove());
    $('[data-k="lang"]', w.el).addEventListener('click', () => Notes.add('Tor Browser\'s language settings are not simulated.', { force: true }));
    $('[data-k="import"]', w.el).addEventListener('click', () => Notes.add('Bookmarks live in RAM and are forgotten at every restart; importing is not simulated.', { force: true }));
    $('[data-k="newtab"]', w.el).addEventListener('click', () => { w.url = ''; $('.tb-url', w.el).value = ''; this.draw(w); });
    $('[data-k="closetab"]', w.el).addEventListener('click', () => WM.close('tor-browser'));
    $('[data-k="reload"]', w.el).addEventListener('click', () => this.draw(w));
    $('.tb-url', w.el).addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); w.url = e.currentTarget.value.trim(); e.currentTarget.blur(); this.draw(w); } });
    this.draw(w);
  },
  draw(w) {
    const p = $('#tbPage', w.el); if (!p) return;
    const t = S.tor;
    const torLine = !S.applied || S.applied.network === 'offline' ? 'Offline mode: Tor keeps DisableNetwork 1 and nothing can load.'
      : !S.net.ssid ? `No network connection yet. Tor: ${t.pct} % (${t.tag}).`
        : t.done ? 'Tor has bootstrapped (100 %), acted out: Antumbra\'s Tor has not yet got past 14 % anywhere.' : `Tor is connecting: ${t.pct} % (${t.tag}): ${t.summary}${t.stuck ? ', stuck' : ''}${t.pct > 14 ? ' (acted out past 14 %)' : ''}.`;
    p.innerHTML = w.url ? `<h4>No page was loaded</h4><p>You asked for <b>${esc(w.url)}</b>. This simulator makes no network requests. In Antumbra the request would leave Tor Browser's own network namespace (tbb) for the system Tor's SocksPort 9050 and go through Tor.</p><div class="tbox">${esc(torLine)}</div><p class="simline">What Tor Browser shows when a page is requested before Tor has bootstrapped is not recorded in the repository.</p>`
      : `<h4>The simulator's own page</h4><p>This is not Tor Browser's start page. In Antumbra, Tor Browser 16.0 alpha for arm64 runs in its own network namespace (tbb) and uses the system Tor (TOR_SKIP_LAUNCH=1), so its start page says the connection to Tor is not managed by Tor Browser.</p>
        <div class="tbox"><b>Connection</b><br>${esc(torLine)}</div>
        <p>Every connection goes through Tor at the firewall. There is no Unsafe Browser, so captive portals cannot be handled. Bookmarks and history are forgotten at every restart.</p>
        <p class="simline">Type an address above to see what would happen.</p>`;
  },
  refresh() { if (S.sess) { const w = S.sess.wins.get('tor-browser'); if (w) this.draw(w); } },
};

/* ======================================================== android windows */
const adrIcons = {
  internet: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12l3-3v2h4v2H5v2zm20 0l-3 3v-2h-4v-2h4V9zM10.5 12a1.5 1.5 0 1 0 3 0 1.5 1.5 0 0 0-3 0z"/></svg>',
  bt: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 2h1l5 5-4 4 4 4-5 5h-1v-7l-4 4-1.4-1.4L10.6 11 5.6 6.4 7 5l4 4zm2 3.8v3.4l1.7-1.7zm0 6.9v3.5l1.7-1.8z"/></svg>',
  torch: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 2h10v4l-2 3v13H9V9L7 6zm2 2v1.4L11 8v12h2V8l2-2.6V4z"/></svg>',
  dnd: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 2a8 8 0 1 1 0 16 8 8 0 0 1 0-16zM7 11h10v2H7z"/></svg>',
  back: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M17 4v16L5 12z"/></svg>',
  home: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8"/></svg>',
  recents: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="5" width="14" height="14" rx="1.5"/></svg>',
  bell: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 22a2 2 0 0 0 2-2h-4a2 2 0 0 0 2 2zm7-6V11a7 7 0 0 0-5-6.7V3.5a2 2 0 0 0-4 0v.8A7 7 0 0 0 5 11v5l-2 2v1h18v-1zM4.6 3.4l1.4 1.4A10 10 0 0 0 3 11H1a12 12 0 0 1 3.6-7.6zM19.4 3.4A12 12 0 0 1 23 11h-2a10 10 0 0 0-3-6.2z"/></svg>',
};
const AndroidUI = {
  create(w) {
    w.el.classList.add('adr');
    w.view = 'shade';
    this.draw(w);
    if (!S.adr.noted) { S.adr.noted = true; Notes.add(esc(ADR_NOTE), { force: true, ms: 9000 }); }
  },
  draw(w) {
    const d = new Date();
    const status = `<div class="adr-status"><span>${h12(d)}:${pad2(d.getMinutes())}&nbsp;&nbsp;${DAYS[d.getDay()].slice(0, 3)}, ${MON[d.getMonth()]} ${d.getDate()}</span><span>${adrIcons.internet.replace('<svg', '<svg width="16" height="16" fill="#fff"')} 85%</span></div>`;
    const nav = `<div class="adr-nav"><button type="button" data-n="back" aria-label="Back">${adrIcons.back}</button><button type="button" data-n="home" aria-label="Home">${adrIcons.home}</button><button type="button" data-n="recents" aria-label="Recent apps">${adrIcons.recents}</button></div>`;
    if (w.view === 'shade') {
      w.el.innerHTML = `${status}<div class="adr-shade"><div class="adr-tiles">
        <button class="adr-tile on" type="button" data-t="internet">${adrIcons.internet}<span>Internet</span><span style="flex:none">›</span></button>
        <button class="adr-tile" type="button" data-t="bt">${adrIcons.bt}<span>Bluetooth</span></button>
        <button class="adr-tile dim" type="button" data-t="torch">${adrIcons.torch}<span>Flashlight</span></button>
        <button class="adr-tile" type="button" data-t="dnd">${adrIcons.dnd}<span>Do Not Disturb</span></button></div>
        <div class="adr-panel">No notifications</div></div>${nav}`;
      $$('.adr-tile', w.el).forEach(b => b.addEventListener('click', () => {
        const t = b.dataset.t;
        if (t === 'internet') Notes.add('Android\'s network is a wired bridge (waydroid-tor, 10.200.2.2) whose traffic goes only through Tor.', { force: true });
        else if (t === 'torch') Notes.add('No flashlight inside Android: the container has no access to the phone\'s hardware like that.', { force: true });
        else { b.classList.toggle('on'); }
      }));
    } else {
      w.el.innerHTML = `${status}<div class="adr-home"><div class="clk">${h12(d)}:${pad2(d.getMinutes())}</div><div style="font-size:14px;opacity:.8">${DAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}</div>
        <div class="adr-icons">${S.adr.fdroid ? `<button type="button" data-a="fdroid"><img alt="" src="${icon('waydroid.org.fdroid.fdroid')}">F-Droid</button>` : '<span style="grid-column:1/-1;font-size:13px;opacity:.7;text-align:center">F-Droid is being installed…</span>'}</div></div>${nav}`;
      const fd = $('[data-a="fdroid"]', w.el); fd && fd.addEventListener('click', () => WM.launch('waydroid.org.fdroid.fdroid'));
    }
    $$('.adr-nav button', w.el).forEach(b => b.addEventListener('click', () => {
      if (b.dataset.n === 'recents') { w.view = 'shade'; } else w.view = 'home';
      this.draw(w);
    }));
  },
};
const FDroid = {
  create(w) {
    w.el.style.background = 'transparent';
    w.el.innerHTML = `<div class="awin-wrap"><div class="awin" role="region" aria-label="F-Droid">
      <div class="awin-cap"><button type="button" data-k="back" aria-label="Back"><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg></button><span class="sp"></span>
        <button type="button" data-k="min" aria-label="Minimise"><svg viewBox="0 0 24 24"><path d="M6 18h12"/></svg></button>
        <button type="button" data-k="max" aria-label="Maximise"><svg viewBox="0 0 24 24"><rect x="5" y="6" width="14" height="10"/><path d="M5 19h14"/></svg></button>
        <button type="button" data-k="close" aria-label="Close"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button></div>
      <div class="awin-body" id="fdBody"></div>
      <div class="awin-tabs" role="tablist">${['Discover', 'Search', 'My apps'].map((t, i) => `<button type="button" role="tab" aria-selected="${i === 0}" data-tab="${t}"><i></i>${t}</button>`).join('')}</div>
    </div></div>`;
    const win = $('.awin', w.el);
    $('[data-k="back"]', w.el).addEventListener('click', () => this.tab(w, 'Discover'));
    $('[data-k="min"]', w.el).addEventListener('click', () => { WM.hide('waydroid.org.fdroid.fdroid'); });
    $('[data-k="max"]', w.el).addEventListener('click', () => win.classList.toggle('max'));
    $('[data-k="close"]', w.el).addEventListener('click', () => WM.close('waydroid.org.fdroid.fdroid'));
    $$('.awin-tabs button', w.el).forEach(b => b.addEventListener('click', () => this.tab(w, b.dataset.tab)));
    this.tab(w, 'Discover');
    const answered = (S.applied.androidPersistent && Store.vol && Store.vol.fdroidNotif) || S.ram.fdroidNotif;
    if (!answered) {
      const p = frag(`<div class="aperm" role="alertdialog" aria-modal="true" aria-label="F-Droid notification permission"><div class="aperm-card">${adrIcons.bell}<p>Allow <b>F-Droid</b> to send you notifications?</p><button type="button" data-a="allow">Allow</button><button type="button" data-a="deny">Don’t allow</button></div></div>`);
      $$('button', p).forEach(b => b.addEventListener('click', () => {
        S.ram.fdroidNotif = b.dataset.a;
        if (S.applied.androidPersistent && Store.vol) { Store.vol.fdroidNotif = b.dataset.a; Store.save(); }
        J('android', `F-Droid notification permission: ${b.dataset.a === 'allow' ? 'allowed' : 'denied'}`);
        p.remove();
      }));
      win.append(p);
    }
  },
  tab(w, t) {
    $$('.awin-tabs button', w.el).forEach(b => b.setAttribute('aria-selected', String(b.dataset.tab === t)));
    const body = $('#fdBody', w.el);
    if (t === 'Discover') body.innerHTML = `<h4>F-Droid</h4><div style="font-size:13px;opacity:.8">${S.tor.done ? 'Updating repositories…' : 'Waiting for the network…'}</div><div class="progress-line"><i></i></div><p class="simline" style="font-size:11px">The catalogue would load through Tor. The simulator shows no apps from it.</p>`;
    else if (t === 'Search') body.innerHTML = '<h4>Search</h4><p class="simline" style="font-size:11px">Searching F-Droid is not simulated.</p>';
    else body.innerHTML = `<h4>My apps</h4><div style="font-size:13px;opacity:.85">F-Droid 2.0.1</div><p class="simline" style="font-size:11px">${S.applied.androidPersistent ? 'Kept in Persistent Storage (Keep Android apps and data).' : 'Android is set up again at every session: apps are forgotten.'}</p>`;
  },
};

/* ================================================================= other apps */
function gtkWin(w, title, body) {
  w.el.classList.add('gtk');
  w.el.innerHTML = `<div class="hb"><span style="width:38px"></span><h3>${esc(title)}</h3><span style="width:38px"></span></div><div class="win-body">${body}</div>`;
}
function placeholder(id, title, text) {
  return `<div class="placeholder"><img alt="" src="${appIcon(id)}"><h4>${esc(title)}</h4>${text ? `<p>${esc(text)}</p>` : ''}<p class="simline">Part of the image; its interface is not simulated here.</p></div>`;
}
const MS_PANELS = ['Welcome', 'Top Bar', 'Applications', 'Feedback', 'Compositor', 'Lockscreen', 'Convergence', 'On Screen Keyboard', 'Sensors', 'Experimental features'];
const MobileSettings = {
  create(w) {
    gtkWin(w, 'Mobile Settings', `<div class="ms-welcome"><img alt="" src="${appIcon('mobi.phosh.MobileSettings')}"><h4>Welcome to Mobile Settings</h4><p>Tweak advanced mobile settings</p></div>
      <div class="gtk-list">${MS_PANELS.slice(1).map(p => `<button type="button" data-p="${esc(p)}"><span style="flex:1">${esc(p)}</span>${ic('go-next-symbolic')}</button>`).join('')}</div>
      <p class="simline" style="margin:0 12px 20px">Mobile Settings shows no network details: the anonymised MAC address is visible with <b>ip a</b> in Console.</p>`);
    $$('.gtk-list button', w.el).forEach(b => b.addEventListener('click', () => {
      const page = frag(`<div class="win" style="z-index:2"><div class="hb"><button class="hbtn" type="button" aria-label="Back">${ic('go-previous-symbolic')}</button><h3>${esc(b.dataset.p)}</h3><span style="width:38px"></span></div><div class="win-body">${placeholder('mobi.phosh.MobileSettings', b.dataset.p, '')}</div></div>`);
      $('.hbtn', page).addEventListener('click', () => page.remove());
      w.el.append(page);
    }));
  },
};
const ClocksApp = {
  create(w) {
    gtkWin(w, 'Clocks', '<div class="placeholder"><div id="clkBig" style="font:300 64px/1 var(--font)"></div><p id="clkDate"></p><p class="simline">Your device\'s local time. Antumbra runs in UTC; htpdate sets the clock through Tor once Tor has bootstrapped.</p></div>');
    const tick = () => { if (!w.el.isConnected) return; const d = new Date(); $('#clkBig', w.el).textContent = Clock.time(d); $('#clkDate', w.el).textContent = Clock.date(d); setTimeout(tick, 1000); };
    tick();
  },
};

/* ================================================================= window manager */
const WM = {
  launch(id) {
    if (APPS[id].launcher) { Overview.close(); Android.launch(); return; }
    if (APPS[id].android && S.adr.state !== 'ready') { Notes.add('Android is not running. Android stopped in a session stays stopped until the "Android" launcher starts it again.', { force: true }); return; }
    this.open(id);
  },
  open(id) {
    if (!S.sess || S.sess.locked) return;
    Overview.close(); Drawer.set(false);
    if (S.sess.wins.has(id)) { this.focus(id); return; }
    const a = APPS[id];
    const sp = frag(`<div class="splash" aria-label="Starting ${esc(a.name)}"><img alt="" src="${appIcon(id)}"></div>`);
    Session.el.append(sp);
    Notes.sync();
    const b = S.boot;
    setTimeout(() => {
      sp.remove();
      if (b !== S.boot || !S.sess || S.scr !== 'session') return;
      const w = { id, el: frag(`<section class="win" aria-label="${esc(a.name)}"></section>`) };
      $('#apps').append(w.el);
      S.sess.wins.set(id, w);
      const C = { 'tor-browser': Browser, 'org.gnome.Nautilus': Files, 'org.gnome.Snapshot': Camera, 'org.gnome.Console': Term, 'org.gnome.TextEditor': Editor,
        'org.gnome.Loupe': Viewer, 'mobi.phosh.MobileSettings': MobileSettings, 'org.gnome.clocks': ClocksApp, 'waydroid-ui': AndroidUI, 'waydroid.org.fdroid.fdroid': FDroid }[id];
      if (C) C.create(w);
      else gtkWin(w, a.name, placeholder(id, a.name, a.note || ''));
      this.focus(id);
      J('phosh', `launched ${id}`);
      Notes.add('To close an app: swipe up from the bottom (or tap the pill), then × on its card.', { key: 'closehint', ms: 6000 });
    }, 450);
  },
  focus(id) {
    S.sess.front = id;
    for (const [wid, w] of S.sess.wins) w.el.hidden = wid !== id;
    Session.refresh();
  },
  hide(id) { const w = S.sess.wins.get(id); if (w) w.el.hidden = true; if (S.sess.front === id) S.sess.front = null; Session.refresh(); },
  close(id) {
    if (!S.sess) return;
    const w = S.sess.wins.get(id); if (!w) return;
    try { w.onClose && w.onClose(); } finally {
      w.el.remove(); S.sess.wins.delete(id);
      if (S.sess.front === id) { S.sess.front = null; const last = [...S.sess.wins.keys()].pop(); if (last && !S.sess.overview) this.focus(last); }
      if (id === 'org.gnome.Snapshot') Modal.close();
      Overview.cards(); Session.refresh();
    }
  },
  closeAll() { if (S.sess) [...S.sess.wins.keys()].forEach(id => this.close(id)); },
};

/* ===================================================================== power */
const Power = {
  dialog(kind) {
    if (!S.sess) return;
    const title = { poweroff: 'Power Off', restart: 'Restart', logout: 'Log Out' }[kind];
    let n = 60;
    const text = () => kind === 'logout' ? `amnesia will be logged out automatically in ${n} ${n === 1 ? 'second' : 'seconds'}.`
      : `The system will ${kind === 'poweroff' ? 'power off' : 'restart'} automatically in ${n} ${n === 1 ? 'second' : 'seconds'}.`;
    const m = Modal.open(`<h3>${title}</h3><p id="esdText">${text()}</p>`,
      [{ label: 'Cancel', go: () => { clearInterval(iv); return true; } }, { label: 'Ok', sugg: true, go: () => { clearInterval(iv); this.go(kind); return true; } }], { label: title });
    const iv = setInterval(() => {
      if (!m.isConnected) { clearInterval(iv); return; }
      n--; const t = $('#esdText', m); if (t) t.textContent = text();
      if (n <= 0) { clearInterval(iv); Modal.close(); this.go(kind); }
    }, 1000);
  },
  go(kind) { if (kind === 'logout') this.logout(); else this.shutdown(kind === 'restart'); },
  async teardown() {
    if (S.cam.streaming) { Camera.stop(); }
    WM.closeAll();
    if (['ready', 'booting', 'preparing'].includes(S.adr.state)) {
      J('waydroid', 'Stopping container'); S.adr.state = S.adr.state === 'preparing' ? 'preparing' : 'stopped';
      J('antumbra-waydroid-stopped', "Android stopped: Waydroid's container service stopped, its devices closed");
    }
  },
  async logout() {
    await this.teardown();
    J('phosh', 'session ended: amnesia logged out');
    S.sess = null;
    Welcome.show();
    Notes.add('Logged out. Settings cannot change in the same boot: the Welcome screen only starts a new session.', { force: true, ms: 7000 });
  },
  async shutdown(reboot) {
    const b = S.boot;
    Modal.close(); closePopover(); closeSheet();
    const camWasUp = S.cam.pos !== 'down';
    await this.teardown();
    if (camWasUp) await new Promise(r => setTimeout(r, MOTOR_MS + 120));
    if (b !== S.boot) return;
    if (camWasUp) J('kernel', `hotdog-popup-motor: camera not closed at ${reboot ? 'reboot' : 'power-off'}, retracting`);
    const con = frag('<div class="console" aria-live="polite" aria-label="Shutdown console"></div>');
    UI.mount('shutdown', con);
    // lines as the VM's serial console printed them (run-f1, run-f3a), a few of hundreds
    const lines = [
      ['Stopping session-5.scope - Session 5 of User amnesia...', 0],
      ['<span class="ok">[  OK  ]</span> Stopped tor@default.service - Anonymizing overlay network for TCP.', 300],
      ['<span class="ok">[  OK  ]</span> Stopped NetworkManager.service - Network Manager.', 250],
      ['<span class="ok">[  OK  ]</span> Stopped antumbra-remove-overlayfs-dirs.service - Remove the overlayfs directories.', 350],
      ...(S.ram.persistent ? [['<span class="ok">[  OK  ]</span> Unmounted home-amnesia-Persistent.mount - /home/amnesia/Persistent.', 300]] : []),
      ['antumbra-shutdown: oldroot unmounted', 400], ['antumbra-shutdown: medium unmounted', 250], ['antumbra-shutdown: verity removed', 250],
      ['antumbra-shutdown: loops detached', 250], ['antumbra-shutdown: caches dropped', 300],
      [reboot ? 'shutdown[1]: Rebooting.' : 'shutdown[1]: Powering off.', 300],
      [reboot ? 'reboot: Restarting system' : 'reboot: Power down', 300],
    ];
    const cap = frag(`<div class="boot-cap"><b>Simulator.</b> A debug build prints lines like these (a few of hundreds, as the VM printed them${reboot ? '; the last two are systemd\'s and the kernel\'s usual reboot lines' : ''}). The antumbra-shutdown lines come from the initramfs, where the system returns on the way down: there freed memory has been zeroed (init_on_free=1) and the caches are dropped before power-off. A release build boots with "quiet", and what its screen shows during shutdown is not recorded. Real duration: about 54 s in the VM.</div>`);
    con.append(cap);
    for (const [l, ms] of lines) {
      await new Promise(r => setTimeout(r, ms));
      if (b !== S.boot) return;
      const d = document.createElement('div'); d.innerHTML = l; con.insertBefore(d, cap);
    }
    await new Promise(r => setTimeout(r, 700));
    if (b !== S.boot) return;
    S.sess = null;
    if (reboot) Boot.run();
    else this.off();
  },
  off() {
    S.boot++; T.clearAll(); Notes.clear();
    freshBootState();
    setPopcam('down', true);
    const el = frag(`<div class="off"><div style="max-width:300px">Powered off (simulated). On the way down Antumbra returns to the initramfs; freed memory is zeroed (init_on_free=1). How well this clears the phone's RAM is not measured yet.</div><button class="pbtn" type="button" id="powerOn">Press the power button</button><div class="mono wide-only" style="max-width:280px">The button on the frame's right edge works too.</div></div>`);
    UI.mount('off', el);
    $('#powerOn').addEventListener('click', () => Boot.run());
  },
  blank() {
    if (!S.sess || S.sess.blank) return;
    S.sess.blank = true;
    Lock.lock();
    const bl = frag('<button class="blank" type="button" aria-label="Screen off. Tap to wake"></button>');
    bl.addEventListener('click', () => { bl.remove(); S.sess.blank = false; Idle.reset(); Panel.update(); });
    Session.el.append(bl);
    Panel.update();
  },
  pressShort() {
    J('systemd-logind', 'Power key pressed short.');
    if (S.scr === 'off') { Boot.run(); return; }
    if (S.scr !== 'session' || !S.sess) return;
    if (S.sess.blank) { const b = $('.blank'); b && b.click(); return; }
    this.blank();
  },
  holdLong() {
    J('systemd-logind', 'Power key pressed long: powering off.');
    if (S.scr === 'off' || S.scr === 'shutdown') return;
    this.shutdown(false);
  },
};

/* ===================================================================== controls */
function bindHardware() {
  const hw = $('#hwPower');
  let t = 0, long = false, pid = null;
  // the pointer is captured, so the release always arrives here; a pointer that slides off the
  // button (and its wider hit area) lets go of it: no press, and a hold is cancelled
  const inside = e => { const r = hw.getBoundingClientRect(), m = 16 * UI.scale; return e.clientX >= r.left - 8 * UI.scale && e.clientX <= r.right + m && e.clientY >= r.top - 6 && e.clientY <= r.bottom + 6; };
  const cancel = () => { hw.classList.remove('held'); if (t) clearTimeout(t); t = 0; pid = null; };
  hw.addEventListener('pointerdown', e => {
    e.preventDefault(); long = false; pid = e.pointerId; hw.classList.add('held');
    try { hw.setPointerCapture(e.pointerId); } catch (err) { /* not capturable */ }
    t = setTimeout(() => { long = true; t = 0; hw.classList.remove('held'); Power.holdLong(); }, 5000);
  });
  hw.addEventListener('pointermove', e => { if (e.pointerId === pid && t && !inside(e)) cancel(); });
  hw.addEventListener('pointerup', e => {
    if (e.pointerId !== pid) return;
    const short = t && !long && inside(e);
    cancel();
    if (short) Power.pressShort();
  });
  hw.addEventListener('pointercancel', cancel);
  hw.addEventListener('lostpointercapture', e => { if (e.pointerId === pid) setTimeout(() => { if (pid === e.pointerId) cancel(); }, 0); });
  hw.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); Power.pressShort(); } });
}
function bindPillExt() {
  const px = $('#pillExt'); if (!px) return;
  const live = () => S.scr === 'session' && S.sess && Session.el && Session.el.isConnected && !S.sess.locked && !S.sess.blank;
  px.addEventListener('click', () => { if (px.dataset.dragged || !live()) return; Overview.toggle(); });
  dragY(px, { accept: live, onStart: () => Overview.dragStart(), onMove: dy => Overview.dragMove(dy), onEnd: (dy, vy) => Overview.dragEnd(dy, vy) });
}
function bindPanel() {
  $('#simChip').addEventListener('click', () => Panel.open(true));
  $('#panelClose').addEventListener('click', () => Panel.open(false));
  $('#ctlPress').addEventListener('click', () => { Panel.open(false); Power.pressShort(); });
  $('#ctlHold').addEventListener('click', e => {
    const b = e.currentTarget; if (b.disabled) return;
    b.disabled = true; let n = 5;
    const tick = () => { if (n === 0) { b.disabled = false; b.textContent = 'Hold 5 s'; Panel.open(false); Power.holdLong(); return; } b.textContent = `Holding… ${n}`; n--; setTimeout(tick, 1000); };
    tick();
  });
  const sw = (id, key, after) => {
    const el = $('#' + id);
    el.setAttribute('aria-checked', String(!!Prefs[key]));
    const flip = () => { Prefs[key] = !Prefs[key]; el.setAttribute('aria-checked', String(Prefs[key])); savePrefs(); after && after(); };
    el.addEventListener('click', flip);
    el.addEventListener('keydown', e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); flip(); } });
  };
  const msg = t => { $('#ctlMsg').textContent = t; };
  sw('ctlAndroidImg', 'androidImage', () => msg(Prefs.androidImage ? 'At the next boot: the image with Android apps.' : 'At the next boot: the image without Android apps (no Android group, no Android launcher).'));
  sw('ctlSelfcheck', 'selfcheckFail', () => msg(Prefs.selfcheckFail ? 'At the next boot: the firewall self-check fails.' : 'At the next boot: every self-check passes.'));
  sw('ctlIdle', 'idle', () => Idle.reset());
  sw('ctlNotes', 'notes', () => { if (!Prefs.notes) { Notes.clear(); Notes.read(); } });
  $('#pnotesClear').addEventListener('click', () => Notes.clearAll());
  $('#ctlTor').value = Prefs.torOutcome;
  $('#ctlTor').addEventListener('change', e => { Prefs.torOutcome = e.target.value; savePrefs(); msg('Applies to the next Tor bootstrap.'); });
  let eraseArmed = 0;
  $('#ctlErase').addEventListener('click', e => {
    const b = e.currentTarget;
    if (!Store.exists()) { msg('There is no simulated Persistent Storage to erase.'); return; }
    if (!eraseArmed) { eraseArmed = setTimeout(() => { eraseArmed = 0; b.textContent = 'Erase simulated Persistent Storage'; }, 4000); b.textContent = 'Tap again to erase it'; return; }
    clearTimeout(eraseArmed); eraseArmed = 0; b.textContent = 'Erase simulated Persistent Storage';
    Store.erase(); if (S.ram) S.ram.persistent = false;
    msg('Simulated Persistent Storage erased. The next boot offers Create again.');
    J('simulator', 'Persistent Storage erased (localStorage)');
    Files.refreshAll(); Panel.update();
  });
  $('#ctlReset').addEventListener('click', () => { Panel.open(false); msg(''); Boot.run(); });
}

/* =================================================================== keyboard */
function bindKeys() {
  document.addEventListener('keydown', e => {
    Idle.reset();
    if (e.key === 'Escape') {
      if (popState) { closePopover(); return; }
      if ($('.sheet-wrap')) { closeSheet(); return; }
      if (Panel.isOpen) { Panel.open(false); return; }
      if (S.sess && S.sess.drawer) { Drawer.set(false); return; }
      if (S.sess && S.sess.overview) { Overview.close(); return; }
    }
    // Alt+A: the mnemonic of "Android apps (experimental)"
    if (S.scr === 'welcome' && e.altKey && (e.key === 'a' || e.key === 'A' || e.code === 'KeyA')) {
      const r = $('#wAndroid'); if (r && r.getAttribute('aria-disabled') !== 'true') { e.preventDefault(); r.click(); }
    }
    if (S.scr === 'welcome') $$('u.mn').forEach(u => { u.style.textDecoration = e.altKey ? 'underline' : 'none'; });
  });
  document.addEventListener('keyup', e => { if (S.scr === 'welcome' && !e.altKey) $$('u.mn').forEach(u => { u.style.textDecoration = 'none'; }); });
  UI.screen.addEventListener('pointerdown', () => Idle.reset(), true);
}

/* ======================================================================= intro */
function intro(then) {
  if (Prefs.introSeen) { then(); return; }
  const el = frag(`<div class="intro" role="dialog" aria-modal="true" aria-labelledby="introT"><div class="intro-card">
    <span class="badge-sim">Simulation</span>
    <h2 id="introT">Antumbra, simulated in your browser</h2>
    <p>This page acts out Antumbra, a Tails-based privacy OS for the OnePlus 7T Pro, with the system's screens as seen in a virtual machine, and its texts and rules. It does not run the real OS: ${UI.wide ? 'a web page cannot boot it' : 'an iPhone cannot boot it'}. Nothing here connects to the network: the page makes no request at all.</p>
    <p>Antumbra itself is an alpha that has not yet booted on a real OnePlus 7T Pro: these screens come from its code and from the image running in a virtual machine.</p>
    <p>Slow steps are shortened; the panel lists the real timings and keeps the simulator's notes. ${UI.wide ? 'On this screen the panel is on the right.' : 'Open it any time with the <b>Sim</b> chip at the top-left; a number on the chip means new notes.'}</p>
    <button class="pbtn accent" type="button" id="introGo">Power on</button></div></div>`);
  UI.screen.append(el);
  $('#introGo', el).focus();
  $('#introGo', el).addEventListener('click', () => { Prefs.introSeen = true; savePrefs(); el.remove(); then(); });
}

/* ======================================================================= init */
function init() {
  UI.init();
  Store.load();
  freshBootState();
  bindPanel(); bindPillExt(); bindHardware(); bindKeys();
  $('#camFile').addEventListener('change', e => {
    const f = e.target.files && e.target.files[0];
    if (!f) return;
    if (S.cam.photo) { try { URL.revokeObjectURL(S.cam.photo); } catch (err) { /* ignore */ } }
    S.cam.photo = URL.createObjectURL(f); S.cam.source = 'photo';
    e.target.value = '';
    Camera.view();
  });
  Panel.open(false, true);
  Panel.update();
  setInterval(() => {
    if (S.frozen) return;
    if (S.scr === 'session') Session.refresh();
    Idle.tick();
  }, 1000);
  setInterval(() => { S.battery = Math.max(5, S.battery - 1); }, 600000);
  intro(() => Boot.run());
}

/* test hooks (used by the automated check; harmless for viewers) */
SIM.state = S; SIM.store = Store; SIM.prefs = Prefs;
SIM.test = {
  kb: px => UI.kb(px),
  fastIntro() { Prefs.introSeen = true; },
  overview: o => Overview.set(o), drawer: o => Drawer.set(o), open: id => WM.open(id), close: id => WM.close(id),
  closeAll: () => WM.closeAll(), lock: () => Lock.lock(), journal: () => J.lines.slice(),
  freeze(on) { S.frozen = on; },
  reset() {
    closePopover(); closeSheet(); Modal.close(); Notes.clear();
    if (!S.sess || S.scr !== 'session') return;
    $$('.blank').forEach(b => b.remove()); S.sess.blank = false;
    if (S.sess.locked) Lock.unlock();
    Drawer.set(false); Overview.set(false);
  },
  unlock: () => Lock.unlock(),
  power: kind => Power.shutdown(kind === 'restart'),
  selfcheckLate: () => Selfcheck.run(true),
};
window.ANTUMBRA_SIM = SIM;
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
