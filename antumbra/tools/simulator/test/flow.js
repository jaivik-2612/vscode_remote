// Full click-through of the simulator.
//   iPhone  (390x844, DPR 3, touch):  NODE_PATH=/opt/node22/lib/node_modules node flow.js iphone
//   desktop (1280x900, mouse):        NODE_PATH=/opt/node22/lib/node_modules node flow.js desktop
// Screenshots go to ../shots (iPhone: NN-name.png, desktop: desktop-NN-name.png); results to ./results-<device>.json.
const fs = require('fs');
const path = require('path');
const { launch, newPage, IPHONE, DESKTOP, SHOTS } = require('./harness');

const DEV = (process.argv[2] || 'iphone').toLowerCase() === 'desktop' ? 'desktop' : 'iphone';
const MOBILE = DEV === 'iphone';
const results = [];
const ok = (name, cond, detail = '') => { results.push({ name, pass: !!cond, detail }); console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tap = (page, sel) => (MOBILE ? page.tap(sel) : page.click(sel));
const tapL = loc => (MOBILE ? loc.tap() : loc.click());

/* simulator notes and chips must never sit on an OS control or over an open app */
const coverFails = [];
let coverChecks = 0;
async function coverCheck(page, where) {
  coverChecks++;
  const bad = await page.evaluate(() => {
    // the part of an element that can be seen: clipped by every scrolling or clipping ancestor
    const vis = e => {
      const r = e.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return null;
      let L = r.left, T = r.top, R = r.right, B = r.bottom;
      for (let x = e; x && x.nodeType === 1; x = x.parentElement) {
        const s = getComputedStyle(x);
        if (s.display === 'none' || s.visibility === 'hidden' || +s.opacity === 0) return null;
        if (x !== e && (s.overflowX !== 'visible' || s.overflowY !== 'visible')) {
          const q = x.getBoundingClientRect(); L = Math.max(L, q.left); T = Math.max(T, q.top); R = Math.min(R, q.right); B = Math.min(B, q.bottom);
        }
      }
      return R - L < 2 || B - T < 2 ? null : { left: L, top: T, right: R, bottom: B };
    };
    const hit = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    const screen = document.querySelector('#screen');
    const SIM = '.simnotes, .sim-chip, .cam-chip, .intro, .sheet-wrap';
    const name = e => (e.id ? '#' + e.id : (e.getAttribute('aria-label') || String(e.className || e.tagName))).slice(0, 40);
    const controls = [...screen.querySelectorAll('button, input, textarea, select, a[href], [role="button"], [role="switch"], [role="slider"], [role="option"], [role="menuitem"], [role="tab"], [tabindex]:not([tabindex="-1"])')]
      .filter(e => !e.closest(SIM) && !e.closest('[inert]')).map(e => [e, vis(e)]).filter(x => x[1]);
    // surfaces that are touchable or belong to an open app as a whole
    const surfaces = [...screen.querySelectorAll('.topbar, .homebar, .win, .overview.open, .drawer.open, #lock, .modal-back, .pop, .w-mid, .w-bottom, .splash')]
      .map(e => [e, vis(e)]).filter(x => x[1]);
    const out = [];
    for (const n of screen.querySelectorAll('.simnotes .simnote')) {
      const r = vis(n); if (!r) continue;
      for (const [e, er] of [...controls, ...surfaces]) if (hit(r, er)) out.push('note over ' + name(e));
    }
    for (const c of screen.querySelectorAll('#simChip, .cam-chip')) {
      const r = vis(c); if (!r) continue;
      for (const [e, er] of controls) if (hit(r, er)) out.push(`${c.id ? 'chip' : 'cam-chip'} over ${name(e)}`);
    }
    return [...new Set(out)];
  });
  if (bad.length) coverFails.push(`${where}: ${bad.join(', ')}`);
}

let shotN = 0;
const shot = async (page, name) => {
  shotN++;
  await sleep(250);   // let a note finish its entrance animation
  await coverCheck(page, name);
  await page.screenshot({ path: path.join(SHOTS, `${MOBILE ? '' : 'desktop-'}${String(shotN).padStart(2, '0')}-${name}.png`) });
};

async function overflow(page, where) {
  const o = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth, bw: document.body.scrollWidth, sy: scrollY }));
  ok(`no horizontal overflow: ${where}`, o.sw <= o.iw && o.bw <= o.iw, JSON.stringify(o));
}
/* a drag in phone coordinates (390x844), by touch on the iPhone and by mouse on the desktop's scaled frame */
async function swipe(page, x1, y1, x2, y2, steps = 12) {
  const r = await page.evaluate(() => { const b = document.querySelector('#screen').getBoundingClientRect(); return { l: b.left, t: b.top, sx: b.width / 390, sy: b.height / 844 }; });
  const X = x => r.l + x * r.sx, Y = y => r.t + y * r.sy;
  if (MOBILE) {
    const c = await page.context().newCDPSession(page);
    await c.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: X(x1), y: Y(y1) }] });
    for (let i = 1; i <= steps; i++) {
      await c.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: X(x1 + (x2 - x1) * i / steps), y: Y(y1 + (y2 - y1) * i / steps) }] });
      await sleep(16);
    }
    await c.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await c.detach();
  } else {
    await page.mouse.move(X(x1), Y(y1));
    await page.mouse.down();
    for (let i = 1; i <= steps; i++) { await page.mouse.move(X(x1 + (x2 - x1) * i / steps), Y(y1 + (y2 - y1) * i / steps)); await sleep(16); }
    await page.mouse.up();
  }
}
const st = (page, expr) => page.evaluate(expr);
async function waitFor(page, fn, timeout = 30000, arg) {
  await page.waitForFunction(fn, arg, { timeout, polling: 200 });
}
async function pick(page, comboSel, label) {
  await tap(page, comboSel);
  await page.waitForSelector('.pop [role="option"]');
  await tapL(page.locator('.pop [role="option"]', { hasText: label }).first());
}
async function typeInto(page, sel, text) {
  await page.locator(sel).scrollIntoViewIfNeeded();
  await tap(page, sel);
  await page.fill(sel, text);
}
const overlayNotes = page => page.$$eval('.simnotes .simnote', n => n.filter(x => x.getBoundingClientRect().height > 0).length);

/* every visible, enabled button in the phone screen must change something when clicked */
async function checkButtons(page, view, restore) {
  await restore();
  await sleep(250);
  const count = await page.evaluate(() => {
    const vis = b => { const r = b.getBoundingClientRect(); const s = getComputedStyle(b); return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && !b.closest('[inert]') && !b.disabled; };
    window.__btns = [...document.querySelectorAll('#screen button')].filter(b => !b.closest('.sim-chip, .simnotes') && !b.classList.contains('sim-chip') && vis(b));
    return window.__btns.length;
  });
  const dead = [];
  for (let i = 0; i < count; i++) {
    await restore();
    await sleep(200);
    const label = await page.evaluate(i => {
      const vis = b => { const r = b.getBoundingClientRect(); const s = getComputedStyle(b); return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && !b.closest('[inert]') && !b.disabled; };
      const list = [...document.querySelectorAll('#screen button')].filter(b => !b.closest('.sim-chip, .simnotes') && !b.classList.contains('sim-chip') && vis(b));
      const b = list[i]; if (!b) return null;
      window.__mut = 0;
      if (window.__mo) window.__mo.disconnect();
      window.__mo = new MutationObserver(m => { window.__mut += m.length; });
      window.__mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      window.__target = b;
      return (b.getAttribute('aria-label') || b.textContent || b.className).trim().slice(0, 50);
    }, i);
    if (label === null) continue;
    await page.evaluate(() => { const b = window.__target; b.scrollIntoView({ block: 'nearest' }); b.click(); });
    await sleep(700);
    const m = await page.evaluate(() => { window.__mo.disconnect(); return window.__mut; });
    if (!m) dead.push(label);
  }
  ok(`every button does something: ${view} (${count} buttons)`, dead.length === 0, dead.length ? 'no effect: ' + dead.join(' | ') : '');
}

(async () => {
  const browser = await launch();
  const errors = [];
  const { page } = await newPage(browser, MOBILE ? IPHONE : DESKTOP, { errors });
  console.log(`device: ${DEV}`);

  /* ---------------- boot and Welcome screen ---------------- */
  await shot(page, 'intro');
  ok('intro card says it is a simulation', (await page.textContent('.intro-card')).includes('does not run the real OS'));
  if (!MOBILE) {
    ok('desktop: no stray label beside the frame\'s power button', !(await page.$('.bezel-label')) && (await page.textContent('#hwPower')).trim() === '' && await page.isVisible('#hwPower'));
    ok('desktop: the panel sits beside the phone', await page.evaluate(() => { const p = document.querySelector('#panel').getBoundingClientRect(), s = document.querySelector('#screen').getBoundingClientRect(); return p.width > 200 && p.left >= s.right; }));
  }
  await tap(page, '#introGo');
  await sleep(700);
  await shot(page, 'boot-orange');
  await page.waitForSelector('.w-root', { timeout: 15000 });
  await sleep(400);
  await shot(page, 'welcome');
  await overflow(page, 'welcome');
  ok('welcome title', (await page.textContent('.w-head h1')) === 'Welcome to Antumbra');
  ok('persistent storage default', (await page.textContent('#wPersV')) === 'Do not use (amnesic session)');
  ok('PS passphrase insensitive by default', await page.isDisabled('#wPP'));
  ok('bridges insensitive by default', await page.isDisabled('#wBridges'));
  ok('MAC switch on by default', (await page.getAttribute('#wMac', 'aria-checked')) === 'true');
  ok('admin off by default', (await page.getAttribute('#wAdmin', 'aria-checked')) === 'false');
  ok('Android off by default, Keep insensitive', (await page.getAttribute('#wAndroid', 'aria-checked')) === 'false' && (await page.getAttribute('#wKeep', 'aria-disabled')) === 'true');

  await tap(page, '#wPers');
  await page.waitForSelector('.pop [role="option"]');
  await shot(page, 'welcome-ps-popover');
  const opts = await page.$$eval('.pop [role="option"]', o => o.map(x => x.textContent.trim()));
  ok('PS options without a volume', JSON.stringify(opts) === JSON.stringify(['Do not use (amnesic session)', 'Create (erases the data partition)']), JSON.stringify(opts));
  await tapL(page.locator('.pop [role="option"]', { hasText: 'Create' }));
  // the simulator's own sheet: the simulated volume is not encrypted, read before any passphrase is typed
  await page.waitForSelector('.sheet-wrap.enc-sheet', { timeout: 3000 }).catch(() => {});
  const enc = await page.evaluate(() => { const w = document.querySelector('.sheet-wrap.enc-sheet'); if (!w) return null; const s = document.querySelector('#screen').getBoundingClientRect(), b = w.querySelector('[data-close]').getBoundingClientRect(); return { text: w.textContent, badge: !!w.querySelector('.badge-sim'), inert: document.querySelector('.w-root').inert, focus: document.activeElement === w.querySelector('[data-close]'), inside: b.top >= s.top && b.bottom <= s.bottom }; });
  ok('Create: the simulator\'s sheet says the simulated Persistent Storage is NOT encrypted, on the phone itself', !!enc && enc.text.includes('not encrypted') && enc.text.includes('Do not type a passphrase you really use') && enc.badge && enc.inert && enc.focus && enc.inside, JSON.stringify(enc && { ...enc, text: enc.text.slice(0, 60) }));
  await coverCheck(page, 'welcome-encryption-sheet');
  await page.screenshot({ path: path.join(SHOTS, `${MOBILE ? '' : 'desktop-'}welcome-encryption-sheet.png`) });
  await tap(page, '.sheet-wrap [data-close]');
  ok('…"I understand" closes it and gives the Welcome screen back', !(await page.$('.sheet-wrap')) && !(await page.evaluate(() => document.querySelector('.w-root').inert)));
  ok('Create makes both PS rows sensitive', !(await page.isDisabled('#wPP')) && !(await page.isDisabled('#wPP2')));

  // validation: short passphrase
  await typeInto(page, '#wPP', 'short');
  await tap(page, '#wStart');
  ok('error: PS passphrase too short', (await page.textContent('#wError')) === 'The Persistent Storage passphrase needs at least 12 characters.');
  if (MOBILE) {
    // the error is off-screen: the note goes to the title strip, never over the form
    await sleep(300);
    ok('error off-screen: note in the Welcome title strip', await page.evaluate(() => { const n = document.querySelector('.simnotes.z-welcome .simnote'), h = document.querySelector('.w-head'); if (!n) return false; const a = n.getBoundingClientRect(), b = h.getBoundingClientRect(); return a.top >= b.top && a.bottom <= b.bottom; }));
    await shot(page, 'welcome-error-note');
    await tap(page, '.simnotes .simnote .act');
    await sleep(700);
    ok('"Show it" scrolls the error into view and closes the note', await page.evaluate(() => { const r = document.querySelector('#wError').getBoundingClientRect(), s = document.querySelector('#wScroll').getBoundingClientRect(); return r.top >= s.top && r.bottom <= s.bottom; }) && (await overlayNotes(page)) === 0);
  } else {
    ok('desktop: the error note is in the panel, not on the phone', (await overlayNotes(page)) === 0 && (await page.textContent('#pnotesList')).includes('The error is at the end of the page'));
  }
  await typeInto(page, '#wPP', 'correct horse battery');
  await typeInto(page, '#wPP2', 'correct horse batterx');
  await tap(page, '#wStart');
  ok('error: PS passphrases differ', (await page.textContent('#wError')) === 'The Persistent Storage passphrases differ.');
  await typeInto(page, '#wPP2', 'correct horse battery');

  if (MOBILE) {
    // keyboard case: emulate an open on-screen keyboard and focus the last entry
    await page.evaluate(() => ANTUMBRA_SIM.test.kb(300));
    await page.locator('#wLock2').scrollIntoViewIfNeeded();
    await tap(page, '#wLock2');
    await sleep(500);
    const kbVis = await page.evaluate(() => { const r = document.querySelector('#wLock2').getBoundingClientRect(); return { top: r.top, bottom: r.bottom, limit: innerHeight - 300, pad: getComputedStyle(document.querySelector('.w-page')).paddingBottom }; });
    ok('keyboard open: focused row stays above the keyboard', kbVis.bottom <= kbVis.limit + 1 && kbVis.top >= 0, JSON.stringify(kbVis));
    await shot(page, 'welcome-keyboard');
    await page.evaluate(() => ANTUMBRA_SIM.test.kb(0));
  }

  // Android on, keep on
  await page.locator('#wAndroid').scrollIntoViewIfNeeded();
  await tap(page, '#wAndroid');
  ok('Keep becomes sensitive with Android on and Create', (await page.getAttribute('#wKeep', 'aria-disabled')) === 'false');
  await tap(page, '#wKeep');
  ok('Keep switched on', (await page.getAttribute('#wKeep', 'aria-checked')) === 'true');

  // bridges
  await page.locator('#wTor').scrollIntoViewIfNeeded();
  await pick(page, '#wTor', 'Through bridges');
  ok('bridges row sensitive with Through bridges', !(await page.isDisabled('#wBridges')));
  await tap(page, '#wStart');
  ok('error: no bridge lines', (await page.textContent('#wError')) === 'Enter at least one bridge line, or connect automatically.');
  await typeInto(page, '#wBridges', 'snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72');
  await tap(page, '#wStart');
  const SNOW = 'Snowflake bridges do not work in Antumbra: snowflake reaches its proxies through WebRTC over UDP, and the firewall lets Tor make only TCP connections and DNS queries. Use obfs4 or webtunnel bridges.';
  ok('error: snowflake refused with the real message', (await page.textContent('#wError')) === SNOW);
  await page.locator('#wError').scrollIntoViewIfNeeded();
  await shot(page, 'welcome-snowflake-error');
  await typeInto(page, '#wBridges', 'obfs4 [2001:db8::5]:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0');
  await tap(page, '#wStart');
  ok('error: IPv6 bridge', (await page.textContent('#wError')).startsWith('[2001:db8::5]:443 is an IPv6 address.'));
  await typeInto(page, '#wBridges', 'obfs4 192.0.2.1:443 A cert=x iat-mode=0');

  // screen lock + admin
  await typeInto(page, '#wLock', 'lockpass1');
  await typeInto(page, '#wLock2', 'lockpass2');
  await tap(page, '#wStart');
  ok('error: screen-lock passphrases differ', (await page.textContent('#wError')) === 'The screen-lock passphrases differ.');
  await typeInto(page, '#wLock2', 'lockpass1');
  await page.locator('#wAdmin').scrollIntoViewIfNeeded();
  await tap(page, '#wAdmin');

  // unit vectors of the bridge port (tests/unit/test_settings.py)
  const unit = await page.evaluate(() => {
    const { normaliseBridges: n, bridgeLines: b, SNOWFLAKE_REFUSED, IPV6_REFUSED } = ANTUMBRA_SIM.settings;
    const OBFS4 = 'obfs4 192.0.2.1:443 A cert=x iat-mode=0', WEB = 'webtunnel [2001:db8::1]:443 B url=https://example.org/b', MEEK = 'meek_lite 192.0.2.18:80 C url=https://example.org front=example.com';
    const r = [];
    r.push(n(` ${OBFS4}\r\n\r\n${WEB}\n;; ${MEEK} ;\n`) === `${OBFS4};${WEB};${MEEK}`);
    r.push(n(' \r\n ; \n') === '');
    r.push(JSON.stringify(b(['# a comment', `Bridge ${OBFS4}`, '', `  bridge\t${MEEK} `, '192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567', 'Bridge'])) === JSON.stringify([OBFS4, MEEK, '192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567']));
    const err = f => { try { f(); return null; } catch (e) { return e.message; } };
    r.push(err(() => b([OBFS4, 'Bridge Snowflake 192.0.2.3:80'])) === SNOWFLAKE_REFUSED);
    r.push((err(() => b(['conjure 192.0.2.9:80 0123'])) || '').startsWith('Unsupported bridge type: conjure.'));
    r.push((err(() => b(['OBFS4 192.0.2.1:443 A'])) || '').startsWith('Unsupported bridge type: OBFS4.'));
    for (const [line, addr] of [['[2001:db8::5]:443 F', '[2001:db8::5]:443'], ['2001:db8::5 F', '2001:db8::5'], ['Bridge obfs4 [2001:db8::5]:443 F cert=x', '[2001:db8::5]:443'], ['obfs3 [2001:db8::6]:80 F', '[2001:db8::6]:80'], ['obfs2 [::ffff:192.0.2.4]:443 F', '[::ffff:192.0.2.4]:443']])
      r.push(err(() => b([OBFS4, line])) === IPV6_REFUSED.replace('{address}', addr));
    r.push(b([WEB, MEEK.replace('192.0.2.18:80', '[2001:db8::2]:80'), '192.0.2.8 F']).length === 3);
    r.push(n('obfs4 192.0.2.1:443 A cert=x iat-mode=0\r\n\nwebtunnel 192.0.2.2:443 B url=https://example.org/b\n') === 'obfs4 192.0.2.1:443 A cert=x iat-mode=0;webtunnel 192.0.2.2:443 B url=https://example.org/b');
    return r;
  });
  ok('bridge port matches the Python unit-test vectors', unit.every(Boolean), JSON.stringify(unit));

  /* ---------------- Start: create Persistent Storage ---------------- */
  await tap(page, '#wStart');
  await sleep(300);
  ok('Start shows "Applying settings…"', (await page.textContent('#wStart')) === 'Applying settings…' && await page.isDisabled('#wStart'));
  await shot(page, 'welcome-applying');
  await page.waitForSelector('.session', { timeout: 20000 });
  await sleep(1200);
  await shot(page, 'session-home');
  await overflow(page, 'session');
  if (MOBILE) {
    ok('home: the how-to note sits on the bare wallpaper, above the home bar', await page.evaluate(() => {
      const n = [...document.querySelectorAll('.simnotes.z-home .simnote')].find(x => x.textContent.includes('Swipe up from the bottom edge')); if (!n) return false;
      const r = n.closest('.simnotes').getBoundingClientRect(), hb = document.querySelector('#homebar').getBoundingClientRect(), pill = document.querySelector('#pillHit').getBoundingClientRect();
      return r.bottom <= Math.min(hb.top, pill.top) - 8;
    }));
    const before = await overlayNotes(page);
    await tap(page, '.simnotes .simnote .x');
    await sleep(150);
    ok('home note dismissible with ×', (await overlayNotes(page)) === before - 1, `${before} → ${await overlayNotes(page)}`);
  } else {
    ok('desktop: notes go to the panel beside the phone, none on the phone', (await overlayNotes(page)) === 0 && (await page.textContent('#pnotesList')).includes('Swipe up from the bottom edge'));
  }
  ok('volume created in storage', await st(page, () => !!ANTUMBRA_SIM.store.vol && !JSON.stringify(ANTUMBRA_SIM.store.vol).includes('correct horse')));
  ok('top bar clock in Phosh format', /^[A-Z][a-z]{2} \d{1,2}\u2003[ \d]\d:\d\d [AP]M$/.test(await page.textContent('#tbClock')), JSON.stringify(await page.textContent('#tbClock')));
  await sleep(1500);
  ok('MAC anonymised: bytes 2-3 kept, first byte loses its locally-administered bit (as in the VM)', await st(page, () => { const n = ANTUMBRA_SIM.state.net; const a = n.cur.split(':'), h = n.hw.split(':'); return n.present && n.cur !== n.hw && a[1] === h[1] && a[2] === h[2] && parseInt(a[0], 16) === (parseInt(h[0], 16) & ~2); }), await st(page, () => ANTUMBRA_SIM.state.net.hw + ' -> ' + ANTUMBRA_SIM.state.net.cur));
  if (MOBILE) await shot(page, 'session-home-wifi-note');

  /* ---------------- quick settings, Wi-Fi ---------------- */
  await tap(page, '#tbClock');
  await sleep(400);
  ok('tap on the top bar opens quick settings', await st(page, () => ANTUMBRA_SIM.state.sess.drawer));
  ok('no note over quick settings', (await overlayNotes(page)) === 0);
  await shot(page, 'quick-settings');
  const tiles = await page.$$eval('#qsTiles .tile', t => t.map(x => x.textContent.trim()));
  ok('tiles in Phosh order', tiles.join('|') === ['Cellular', 'Wi-Fi', 'Bluetooth', '82%', 'Portrait', 'On', 'Dark mode', 'Night Light Off'].join('|'), tiles.join('|'));
  await tap(page, '[data-tile="fb"] button.main');
  ok('feedback tile toggles', (await page.textContent('[data-tile="fb"]')).trim() === 'Quiet');
  await tap(page, '[data-tile="fb"] button.main'); await tap(page, '[data-tile="fb"] button.main');
  await tap(page, '[data-tile="wifi"] .arrow');
  await sleep(300);
  await tapL(page.locator('.net-row', { hasText: 'Café guest' }));
  await shot(page, 'wifi-connecting');
  await waitFor(page, () => ANTUMBRA_SIM.state.net.ssid === 'Café guest', 8000);
  ok('Wi-Fi connected', true);
  await tap(page, '.qs-sub .hbtn');
  await tap(page, '#qsFold');
  await sleep(400);
  ok('quick settings closed', !(await st(page, () => ANTUMBRA_SIM.state.sess.drawer)));
  // swipe down from the top bar
  await swipe(page, 195, 10, 195, 600);
  await sleep(400);
  ok('pull-down gesture opens quick settings', await st(page, () => ANTUMBRA_SIM.state.sess.drawer));
  await swipe(page, 195, 820, 195, 200);
  await sleep(400);
  ok('swipe up on the fold arrow closes quick settings', !(await st(page, () => ANTUMBRA_SIM.state.sess.drawer)));

  /* ---------------- overview ---------------- */
  await swipe(page, 195, 838, 195, 300);
  await sleep(500);
  ok('swipe up from the home bar opens the overview', await st(page, () => ANTUMBRA_SIM.state.sess.overview));
  ok('no note over the app grid', (await overlayNotes(page)) === 0);
  await shot(page, 'overview');
  const fav = await page.$$eval('#ovFav .appbtn', b => b.map(x => x.getAttribute('aria-label')));
  ok('dock: Tor Browser, Files, Camera, Console', fav.join('|') === 'Tor Browser|Files|Camera|Console', fav.join('|'));
  const grid = await page.$$eval('#ovGrid .appbtn', b => b.map(x => x.textContent.trim()));
  ok('app grid with the Android folder', grid[0] === 'Android' && grid.includes('Text Editor') && grid.length === 11, grid.join('|'));
  await page.fill('#ovSearch', 'cam');
  await sleep(200);
  ok('search filters', (await page.$$eval('#ovGrid .appbtn', b => b.map(x => x.textContent.trim()))).join('|') === 'Camera');
  await shot(page, 'overview-search');
  await page.fill('#ovSearch', '');
  await tap(page, '#pillHit');
  await sleep(400);
  ok('tap on the bottom edge folds the overview', !(await st(page, () => ANTUMBRA_SIM.state.sess.overview)));

  /* ---------------- Tor ---------------- */
  await waitFor(page, () => ANTUMBRA_SIM.state.tor.done, 40000);
  const tj = await st(page, () => ANTUMBRA_SIM.test.journal().filter(l => / tor: Bootstrapped/.test(l)).map(l => l.replace(/^\S+ /, '')));
  ok('Tor bootstrapped through the bridge with real phase lines', tj.includes('tor: Bootstrapped 1% (conn_pt): Connecting to pluggable transport') && tj.includes('tor: Bootstrapped 100% (done): Done'), tj.length + ' lines');
  ok('journal says connecting through 1 bridge(s)', (await st(page, () => ANTUMBRA_SIM.test.journal().join('\n'))).includes('antumbra-tor-connect: connecting through 1 bridge(s)'));

  /* ---------------- Camera ---------------- */
  await page.evaluate(() => ANTUMBRA_SIM.test.reset());
  await tap(page, '#pillHit'); await sleep(400);
  await tap(page, '#ovFav [data-app="org.gnome.Snapshot"]');
  await page.waitForSelector('.modal-back', { timeout: 5000 });
  ok('camera portal prompt text', (await page.textContent('.dialog h3')) === 'Allow app to Use the Camera?' && (await page.textContent('.dialog p')) === 'An app wants to access camera devices.');
  await sleep(300);
  await shot(page, 'camera-portal');
  await tapL(page.locator('.dbtns button', { hasText: 'Ok' }));
  await sleep(250);
  ok('camera rising after Ok', await st(page, () => ANTUMBRA_SIM.state.cam.pos === 'rising'));
  await shot(page, 'camera-rising');
  await waitFor(page, () => ANTUMBRA_SIM.state.cam.pos === 'up', 3000);
  await sleep(500);
  ok('preview shows the colour bars', await page.isVisible('#bars'));
  if (MOBILE) ok('in an app, notes wait on the Simulator chip instead of covering it', (await overlayNotes(page)) === 0 && await page.evaluate(() => document.querySelector('#simChip').classList.contains('has-notes')), await page.getAttribute('#simChip', 'aria-label'));
  else ok('desktop: module raised on the frame', await page.evaluate(() => document.querySelector('#popcam').classList.contains('up')));
  ok('Snapshot\'s header controls are uncovered', await page.evaluate(() => [...document.querySelectorAll('.snap-top button')].every(b => { const r = b.getBoundingClientRect(); const e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return e && b.contains(e); })));
  await shot(page, 'camera-preview');
  await tap(page, '.shutter');
  await sleep(600);
  ok('picture saved in ~/Pictures/Camera', await st(page, () => (ANTUMBRA_SIM.state.ram.fs['Pictures/Camera'] || []).length === 1 && /^Photo from \d{4}-\d\d-\d\d \d\d-\d\d-\d\d\.\d{6}\.jpeg$/.test(ANTUMBRA_SIM.state.ram.fs['Pictures/Camera'][0].name)));
  await tap(page, '.cam-chip');
  await sleep(300);
  ok('camera info sheet with the drop warning', (await page.textContent('.sheet')).includes('no drop protection'));
  await shot(page, 'camera-info');
  await tap(page, '.sheet [data-close]');
  await checkButtons(page, 'Camera', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.open('org.gnome.Snapshot'); }); });
  await page.evaluate(() => ANTUMBRA_SIM.test.reset());
  // close from the overview: the camera lowers
  await swipe(page, 195, 838, 195, 300);
  await sleep(500);
  await shot(page, 'overview-running-apps');
  await tap(page, '.card-app .x[aria-label="Close Camera"]');
  await sleep(200);
  ok('closing Snapshot lowers the camera', await st(page, () => ANTUMBRA_SIM.state.cam.pos === 'lowering'));
  await sleep(900);
  ok('camera down after one course', await st(page, () => ANTUMBRA_SIM.state.cam.pos === 'down'));
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); });

  /* ---------------- Android ---------------- */
  await waitFor(page, () => ANTUMBRA_SIM.state.adr.fdroid, 45000);
  ok('Android ready and F-Droid installed', true);
  await page.evaluate(() => ANTUMBRA_SIM.test.overview(true));
  await sleep(300);
  await tap(page, '[data-folder="android"]');
  await sleep(300);
  const folder = await page.$$eval('#fpGrid .appbtn', b => b.map(x => x.textContent.trim()));
  ok('Android folder: Android, then F-Droid', folder.join('|') === 'Android|F-Droid', folder.join('|'));
  await shot(page, 'android-folder');
  await tap(page, '#fpGrid [data-app="antumbra-android"]');
  await page.waitForSelector('.adr-tiles', { timeout: 5000 });
  await sleep(300);
  ok('no note over the Android window', (await overlayNotes(page)) === 0);
  await shot(page, 'android-full-ui');
  await tap(page, '.adr-nav [data-n="home"]');
  await sleep(200);
  await tap(page, '.adr-icons [data-a="fdroid"]');
  await page.waitForSelector('.aperm', { timeout: 5000 });
  ok('F-Droid asks for the notification permission', (await page.textContent('.aperm-card p')).replace(/\s+/g, ' ') === 'Allow F-Droid to send you notifications?');
  ok('no note over F-Droid', (await overlayNotes(page)) === 0);
  await shot(page, 'android-fdroid-permission');
  await tapL(page.locator('.aperm-card button', { hasText: 'Allow' }).first());
  await sleep(300);
  await shot(page, 'android-fdroid');
  await checkButtons(page, 'F-Droid window', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('waydroid.org.fdroid.fdroid'); ANTUMBRA_SIM.test.open('waydroid.org.fdroid.fdroid'); }); await sleep(600); });
  await checkButtons(page, 'Android full UI', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('waydroid-ui'); ANTUMBRA_SIM.test.open('waydroid-ui'); }); await sleep(600); });
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); });

  /* ---------------- notes: Persistent and RAM ---------------- */
  await page.evaluate(() => ANTUMBRA_SIM.test.overview(true));
  await sleep(300);
  await tap(page, '#ovGrid [data-app="org.gnome.TextEditor"]');
  await page.waitForSelector('textarea.editor');
  await page.fill('textarea.editor', 'Kept in Persistent Storage.');
  await tap(page, '[data-k="save"]');
  await page.fill('#saveName', 'kept.txt');
  await tap(page, 'input[name="saveDir"][value="Persistent"]');
  await shot(page, 'editor-save');
  await tap(page, '.hbtn[data-k="ok"]');
  await sleep(300);
  ok('note saved in Persistent', await st(page, () => ANTUMBRA_SIM.store.vol.files.some(f => f.name === 'kept.txt')));
  ok('no note over Text Editor after saving', (await overlayNotes(page)) === 0);
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('org.gnome.TextEditor'); ANTUMBRA_SIM.test.open('org.gnome.TextEditor'); });
  await page.waitForSelector('textarea.editor');
  await page.fill('textarea.editor', 'Forgotten at shutdown.');
  await tap(page, '[data-k="save"]');
  await page.fill('#saveName', 'ram.txt');
  await tap(page, 'input[name="saveDir"][value="Documents"]');
  await tap(page, '.hbtn[data-k="ok"]');
  await sleep(300);
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.open('org.gnome.Nautilus'); });
  await page.waitForSelector('.flist');
  await tapL(page.locator('.frow', { hasText: 'Persistent' }).first());
  await sleep(200);
  ok('Files shows the note in Persistent', (await page.textContent('.flist')).includes('kept.txt'));
  await shot(page, 'files-persistent');
  await checkButtons(page, 'Files (Persistent)', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('org.gnome.Nautilus'); ANTUMBRA_SIM.test.open('org.gnome.Nautilus'); }); await sleep(650); await page.evaluate(() => { const r = [...document.querySelectorAll('.frow')].find(x => x.textContent.includes('Persistent')); r && r.click(); }); });

  /* ---------------- Console ---------------- */
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('org.gnome.Console'); });
  await page.waitForSelector('.term-in input');
  const run = async c => { await page.fill('.term-in input', c); await page.press('.term-in input', 'Enter'); await sleep(150); };
  await run('whoami');
  await run('ip a');
  await run('sudo antumbra-tor-connect status');
  ok('sudo asks for the password', (await page.textContent('.term-in .ps')) === '[sudo] password for amnesia:');
  await run('lockpass1');
  const term = await page.textContent('.term-out');
  ok('whoami → amnesia', term.includes('amnesia\n') || term.includes('$ whoamiamnesia'));
  ok('ip a shows the anonymised MAC with permaddr', /link\/ether [0-9a-f:]{17} brd ff:ff:ff:ff:ff:ff permaddr [0-9a-f:]{17}/.test(term));
  ok('tor status as root', term.includes('NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"') && term.includes('enough-dir-info 1'));
  await run('torify curl example.org');
  await shot(page, 'console');
  await checkButtons(page, 'Console', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('org.gnome.Console'); ANTUMBRA_SIM.test.open('org.gnome.Console'); }); await sleep(650); });

  /* ---------------- Tor Browser, Mobile Settings ---------------- */
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('tor-browser'); });
  await page.waitForSelector('#tbPage');
  ok('Tor Browser shows only the simulator\'s own page', (await page.textContent('#tbPage')).includes("simulator's own page"));
  await shot(page, 'tor-browser');
  await checkButtons(page, 'Tor Browser', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('tor-browser'); ANTUMBRA_SIM.test.open('tor-browser'); }); await sleep(650); });
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('mobi.phosh.MobileSettings'); });
  await sleep(700);
  await shot(page, 'mobile-settings');
  await checkButtons(page, 'Mobile Settings', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.close('mobi.phosh.MobileSettings'); ANTUMBRA_SIM.test.open('mobi.phosh.MobileSettings'); }); await sleep(650); });
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); });

  /* ---------------- overview and quick settings buttons ---------------- */
  await page.evaluate(() => ANTUMBRA_SIM.test.freeze(true));
  await checkButtons(page, 'overview', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.overview(true); }); });
  await checkButtons(page, 'quick settings', async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.drawer(true); }); });
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.freeze(false); });

  /* ---------------- lock screen ---------------- */
  await tap(page, '#tbClock'); await sleep(400);
  await tap(page, '#qsLock'); await sleep(400);
  ok('lock button locks', await st(page, () => ANTUMBRA_SIM.state.sess.locked));
  await shot(page, 'lock');
  await swipe(page, 195, 600, 195, 200);
  await sleep(600);
  await shot(page, 'lock-keypad');
  for (const d of '999999') await tap(page, `.keypad button:text-is("${d}")`);
  await tap(page, '#lkUnlock');
  await sleep(900);
  ok('wrong passphrase keeps it locked', await st(page, () => ANTUMBRA_SIM.state.sess.locked) && (await page.textContent('#lkTitle')) === 'Enter Passcode');
  await page.fill('#lkEntry', 'lockpass1');
  await tap(page, '#lkUnlock');
  await sleep(900);
  ok('right passphrase unlocks', !(await st(page, () => ANTUMBRA_SIM.state.sess.locked)));

  /* ---------------- restart, unlock wrong then right ---------------- */
  await tap(page, '#tbClock'); await sleep(400);
  await tap(page, '#qsPower');
  await tapL(page.locator('.pop [role="menuitem"]', { hasText: 'Restart…' }));
  await sleep(300);
  ok('end-session dialog', (await page.textContent('.dialog h3')) === 'Restart' && /^The system will restart automatically in \d+ seconds\.$/.test(await page.textContent('#esdText')));
  await shot(page, 'restart-dialog');
  await tapL(page.locator('.dbtns button', { hasText: 'Ok' }));
  await sleep(1500);
  await shot(page, 'shutdown-wipe');
  await page.waitForSelector('.orange', { timeout: 10000 });
  await shot(page, 'reboot-orange');
  await page.waitForSelector('.w-root', { timeout: 15000 });
  await sleep(300);
  ok('Repeat row hidden when the volume exists', !(await page.$('#wPP2')));
  await tap(page, '#wPers');
  await page.waitForSelector('.pop [role="option"]');
  const opts2 = await page.$$eval('.pop [role="option"]', o => o.map(x => x.textContent.trim()));
  ok('Unlock offered after restart', JSON.stringify(opts2) === JSON.stringify(['Do not use (amnesic session)', 'Unlock']), JSON.stringify(opts2));
  await tapL(page.locator('.pop [role="option"]', { hasText: 'Unlock' }));
  await tap(page, '#wStart');
  ok('error: unlock without a passphrase', (await page.textContent('#wError')) === 'Enter the Persistent Storage passphrase, or choose not to use it.');
  await typeInto(page, '#wPP', 'wrong passphrase');
  await tap(page, '#wStart');
  await page.waitForFunction(() => document.querySelector('#wStart').textContent === 'Start Antumbra', null, { timeout: 10000 });
  ok('wrong passphrase: the real applier message', (await page.textContent('#wError')) === 'wrong passphrase, or Persistent Storage is damaged');
  await page.locator('#wError').scrollIntoViewIfNeeded();
  await shot(page, 'unlock-wrong');
  await typeInto(page, '#wPP', 'correct horse battery');
  await tap(page, '#wStart');
  await page.waitForSelector('.session', { timeout: 15000 });
  await sleep(500);
  await page.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Nautilus'));
  await page.waitForSelector('.flist');
  const home = await page.textContent('.flist');
  ok('Persistent folder back after unlock', home.includes('Persistent'));
  await tapL(page.locator('.frow', { hasText: 'Persistent' }).first());
  await sleep(200);
  ok('note still in Persistent after restart', (await page.textContent('.flist')).includes('kept.txt'));
  await shot(page, 'files-after-restart');
  await page.evaluate(() => ANTUMBRA_SIM.test.closeAll());
  ok('RAM note forgotten', await st(page, () => !(ANTUMBRA_SIM.state.ram.fs.Documents || []).length));
  ok('photo forgotten', await st(page, () => !ANTUMBRA_SIM.state.ram.fs['Pictures/Camera']));
  await sleep(2600);
  ok('saved Wi-Fi reconnects from Persistent Storage', await st(page, () => ANTUMBRA_SIM.state.net.ssid === 'Café guest' || ANTUMBRA_SIM.state.net.connecting === 'Café guest'));
  ok('Android off this session: the plain Android launcher', await st(page, () => !ANTUMBRA_SIM.state.applied.android));
  await page.evaluate(() => ANTUMBRA_SIM.test.overview(true));
  await sleep(300);
  await tap(page, '#ovGrid [data-app="antumbra-android"]');
  await sleep(400);
  ok('Android launcher with Android off: the real notification', (await page.textContent('#banners')).includes('Android apps are off'));
  await shot(page, 'android-off-notification');

  /* ---------------- reload keeps the volume ---------------- */
  await page.reload();
  await page.waitForSelector('.w-root', { timeout: 15000 });
  await tap(page, '#wPers');
  await page.waitForSelector('.pop [role="option"]');
  ok('after a page reload Unlock is still offered', (await page.$$eval('.pop [role="option"]', o => o.map(x => x.textContent.trim()))).includes('Unlock'));
  await page.keyboard.press('Escape');

  /* ---------------- shut down ---------------- */
  await tap(page, '#wStart');
  await page.waitForSelector('.session', { timeout: 10000 });
  await tap(page, '#tbClock'); await sleep(400);
  await tap(page, '#qsPower');
  await tapL(page.locator('.pop [role="menuitem"]', { hasText: 'Power Off…' }));
  await sleep(200);
  ok('power-off dialog text', /^The system will power off automatically in \d+ seconds\.$/.test(await page.textContent('#esdText')));
  await tapL(page.locator('.dbtns button', { hasText: 'Ok' }));
  await page.waitForFunction(() => (document.querySelector('.console') || {}).textContent?.includes('antumbra-shutdown: caches dropped'), null, { timeout: 8000 }).catch(() => {});
  ok('memory-wipe lines on the way down', (await page.textContent('.console')).includes('antumbra-shutdown: oldroot unmounted'));
  await shot(page, 'poweroff-wipe');
  await page.waitForSelector('.off', { timeout: 10000 });
  await shot(page, 'powered-off');
  await overflow(page, 'off');

  /* ---------------- the panel ---------------- */
  if (MOBILE) {
    await tap(page, '#simChip');
    await sleep(400);
    ok('Simulator panel opens from the chip', await page.isVisible('#panel.open'));
    ok('the panel keeps the notes; opening it clears the chip\'s count', (await page.textContent('#pnotesList')).includes('Swipe up from the bottom edge') && !(await page.evaluate(() => document.querySelector('#simChip').classList.contains('has-notes'))));
    await shot(page, 'panel-phone');
    await tap(page, '#panelClose');
  } else {
    ok('desktop: the panel lists the notes', (await page.$$eval('#pnotesList .pnote', l => l.length)) >= 2 && (await page.textContent('#pnotesList')).includes('Swipe up from the bottom edge'));
    await tap(page, '#pnotesClear');
    ok('desktop: Clear empties the notes list', (await page.$$eval('#pnotesList .pnote', l => l.length)) === 0 && await page.isVisible('#pnotesEmpty') && !(await page.isVisible('#pnotesClear')));
    await tap(page, '#hwPower');
    await page.waitForSelector('.orange', { timeout: 5000 }).catch(() => {});
    ok('desktop: the frame\'s power button powers the phone on', await page.isVisible('.orange'));
  }

  /* ---------------- image without Android, failed self-check, offline ---------------- */
  if (MOBILE) {
    const v2 = await newPage(browser, IPHONE, { errors, storage: { 'antumbra-sim:prefs:v1': JSON.stringify({ introSeen: true, androidImage: false, selfcheckFail: true }) } });
    await v2.page.waitForSelector('.w-root', { timeout: 15000 });
    ok('self-check banner text', (await v2.page.textContent('.w-banner')) === 'Privacy self-check failed: firewall FAIL: Tor-enforcement ruleset is not loaded or incomplete; firewall-android FAIL: the rules for the Android bridge are not loaded or incomplete', await v2.page.textContent('.w-banner'));
    ok('no Android group in the image without Android', !(await v2.page.$('#wAndroid')));
    await shot(v2.page, 'welcome-selfcheck-banner');
    await pick(v2.page, '#wTor', 'Offline mode');
    await v2.page.tap('#wStart');
    await v2.page.waitForSelector('.session', { timeout: 10000 });
    await sleep(1200);
    const j2 = await v2.page.evaluate(() => ANTUMBRA_SIM.test.journal().join('\n'));
    ok('offline mode leaves the drivers blocked', j2.includes('network disabled by the user (offline mode); leaving drivers blocked'));
    await v2.page.evaluate(() => ANTUMBRA_SIM.test.overview(true));
    await sleep(300);
    ok('no Android entry in the grid', !(await v2.page.$('#ovGrid [data-app="antumbra-android"]')));
    await v2.page.evaluate(() => ANTUMBRA_SIM.test.drawer(true));
    await sleep(300);
    ok('offline: Wi-Fi tile insensitive', await v2.page.isDisabled('[data-tile="wifi"] button.main'));
    await overflow(v2.page, 'offline session');
  }

  ok(`notes and chips never cover an OS control or an open app (${coverChecks} screens checked)`, coverFails.length === 0, coverFails.join(' | '));
  ok('no console errors', errors.length === 0, errors.join('\n'));
  await browser.close();
  const failed = results.filter(r => !r.pass);
  console.log(`\n${DEV}: ${results.length - failed.length}/${results.length} checks passed`);
  fs.writeFileSync(path.join(__dirname, `results-${DEV}.json`), JSON.stringify({ device: DEV, results, errors, coverFails }, null, 1));
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error('TEST CRASH', e); process.exit(2); });
