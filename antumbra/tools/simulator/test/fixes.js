// Regression checks for the review findings (fidelity, iPhone, honesty), each in a fresh page.
//   NODE_PATH=/opt/node22/lib/node_modules node fixes.js
// Screenshots: ../shots/fix-*.png; results: ./results-fixes.json
const fs = require('fs');
const path = require('path');
const { launch, newPage, IPHONE, DESKTOP, SHOTS } = require('./harness');

const results = [];
const ok = (name, cond, detail = '') => { results.push({ name, pass: !!cond, detail }); console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + String(detail).slice(0, 400) : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const SE = { ...IPHONE, viewport: { width: 375, height: 667 }, deviceScaleFactor: 2 };
const LAND = { ...IPHONE, viewport: { width: 844, height: 390 } };
const LAND_MAX = { ...IPHONE, viewport: { width: 932, height: 430 } };
const LAND_SE = { ...IPHONE, viewport: { width: 667, height: 375 }, deviceScaleFactor: 2 };
const SAFE_P = { top: 47, bottom: 34, left: 0, right: 0 };
const SAFE_L = { top: 0, bottom: 21, left: 47, right: 47 };
const PREFS = (o = {}) => ({ 'antumbra-sim:prefs:v1': JSON.stringify({ introSeen: true, ...o }) });
const errors = [];
let browser;

async function fresh(device, opts = {}) {
  const { page, ctx } = await newPage(browser, device, { errors, storage: opts.intro ? undefined : PREFS(opts.prefs), safe: opts.safe, lsThrow: opts.lsThrow });
  page.mobile = !!device.hasTouch;
  page.T = sel => (page.mobile ? page.tap(sel) : page.click(sel));
  page.TL = loc => (page.mobile ? loc.tap() : loc.click());
  page.ctxRef = ctx;
  if (!opts.intro) await page.waitForSelector('.w-root', { timeout: 15000 });
  return page;
}
const shot = (page, name) => page.screenshot({ path: path.join(SHOTS, `fix-${name}.png`) });
const J = page => page.evaluate(() => ANTUMBRA_SIM.test.journal().join('\n'));
async function pick(page, combo, label) {
  await page.T(combo);
  await page.waitForSelector('.pop [role="option"]');
  await page.TL(page.locator('.pop [role="option"]', { hasText: label }).first());
}
/* the simulator's "not encrypted" sheet comes up the first time Create is chosen: read it, close it */
async function dismissSheet(page) {
  if (await page.$('.sheet-wrap')) { await page.T('.sheet-wrap [data-close]'); await sleep(150); }
}
/* fill the Welcome screen and start the session */
async function start(page, { android = false, lock = '', admin = false, create = '', bridges = '' } = {}) {
  if (create) { await pick(page, '#wPers', 'Create'); await dismissSheet(page); await page.fill('#wPP', create); await page.fill('#wPP2', create); }
  if (bridges) { await pick(page, '#wTor', 'Through bridges'); await page.fill('#wBridges', bridges); }
  if (lock) { await page.fill('#wLock', lock); await page.fill('#wLock2', lock); }
  if (admin) await page.evaluate(() => document.querySelector('#wAdmin').click());
  if (android) await page.evaluate(() => document.querySelector('#wAndroid').click());
  await page.evaluate(() => document.querySelector('#wStart').click());
  await page.waitForSelector('.session', { timeout: 20000 });
  await sleep(400);
}
async function consoleRun(page, cmds) {
  await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.open('org.gnome.Console'); });
  await page.waitForSelector('.term-in input');
  for (const c of cmds) { await page.fill('.term-in input', c); await page.press('.term-in input', 'Enter'); await sleep(200); }
  return page.innerText('.term-out');
}
async function touchSwipe(page, x1, y1, x2, y2, steps = 12) {
  const c = await page.context().newCDPSession(page);
  await c.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x1, y: y1 }] });
  for (let i = 1; i <= steps; i++) { await c.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x1 + (x2 - x1) * i / steps, y: y1 + (y2 - y1) * i / steps }] }); await sleep(16); }
  await c.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await c.detach();
}
const rect = (page, sel) => page.evaluate(s => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; }, sel);
/* controls a finger can reach: each one brought to the middle of its scroller, its centre inside the
   phone screen and the topmost element there is the control itself; returns the ones that are not */
const unreachable = (page, sels) => page.evaluate(ss => {
  const s = document.querySelector('#screen').getBoundingClientRect(), bad = [];
  for (const q of ss) {
    const e = [...document.querySelectorAll(q)].find(x => x.getClientRects().length);
    if (!e) { bad.push(q + ': missing'); continue; }
    let sc = e.parentElement;
    while (sc && sc !== document.body) { const cs = getComputedStyle(sc); if (/(auto|scroll)/.test(cs.overflowY) && sc.scrollHeight > sc.clientHeight) break; sc = sc.parentElement; }
    if (sc && sc !== document.body) { const r = e.getBoundingClientRect(), b = sc.getBoundingClientRect(); sc.scrollTop += (r.top + r.height / 2) - (b.top + b.height / 2); }
    const r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2, t = document.elementFromPoint(x, y);
    if (!(x > s.left && x < s.right && y > s.top && y < s.bottom && t && (t === e || e.contains(t)))) bad.push(`${q}: ${Math.round(r.top)}-${Math.round(r.bottom)} under ${t ? (t.id || String(t.className)).slice(0, 30) : 'nothing'}`);
  }
  return bad;
}, sels);
const topAt = (page, sel) => page.evaluate(s => { const e = document.querySelector(s); const r = e.getBoundingClientRect(); const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return t ? (t.id ? '#' + t.id : t.className || t.tagName) + (e.contains(t) ? ' (inside)' : '') : null; }, sel);

const scenarios = {
  /* ---------------- fidelity ---------------- */
  async androidLauncher() {
    const page = await fresh(IPHONE);
    await start(page, { android: true });
    const launch = async () => { await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.overview(true); }); await sleep(300); await page.T('[data-folder="android"]'); await sleep(300); await page.T('#fpGrid [data-app="antumbra-android"]'); await sleep(400); };
    ok('Android launcher while preparing: "Android is starting"', (await page.evaluate(() => ANTUMBRA_SIM.state.adr.state)) === 'preparing' && (await launch(), (await page.textContent('#banners')).includes('Android is starting')));
    await page.waitForFunction(() => ANTUMBRA_SIM.state.adr.state === 'booting', null, { timeout: 15000 });
    await page.evaluate(() => { document.querySelector('#banners').innerHTML = ''; });
    const n0 = await page.evaluate(() => ANTUMBRA_SIM.state.sess.notifs.length);
    await launch();
    ok('Android launcher after "Android apps ready": no notification (show-full-ui waits silently)', (await page.evaluate(() => ANTUMBRA_SIM.state.sess.notifs.length)) === n0 && !(await page.textContent('#banners')).includes('Android is starting'));
    await shot(page, 'android-booting-no-notification');
    await page.waitForFunction(() => ANTUMBRA_SIM.state.adr.state === 'ready', null, { timeout: 25000 });
    await sleep(800);
    ok('…and Android opens once booted', await page.evaluate(() => ANTUMBRA_SIM.state.sess.wins.has('waydroid-ui')));
    const t = await consoleRun(page, ['waydroid session stop']);
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); document.querySelector('#banners').innerHTML = ''; });
    const n1 = await page.evaluate(() => ANTUMBRA_SIM.state.sess.notifs.length);
    await launch();
    ok('after "waydroid session stop": the launcher restarts Android with no notification', (await page.evaluate(() => ANTUMBRA_SIM.state.sess.notifs.length)) === n1 && (await page.evaluate(() => ANTUMBRA_SIM.state.adr.state)) === 'booting', t.slice(-80));
    // ip a: the bridge with its /30, attached while the container runs
    const ip = await consoleRun(page, ['clear', 'ip a']);
    ok('ip a: waydroid-tor 10.200.2.1/30, UP with the container attached, and its veth enslaved', /waydroid-tor: <BROADCAST,MULTICAST,UP,LOWER_UP>/.test(ip) && ip.includes('inet 10.200.2.1/30 scope global waydroid-tor') && /master waydroid-tor/.test(ip) && !ip.includes('/24 scope global waydroid-tor'));
    const vm = ip.match(/^\d+: (veth[0-9A-Za-z]{6})@if2: <[^>]*> mtu 1500 qdisc noqueue master waydroid-tor state UP[^\n]*\n\s+link\/ether (\S+) brd ff:ff:ff:ff:ff:ff link-netnsid 5$/m);
    ok('ip a: the LXC veth has its random name and an fe:xx:xx:xx:xx:xx MAC (not its name as MAC)', !!vm && /^fe(:[0-9a-f]{2}){5}$/.test(vm[2]) && !/link\/ether veth/.test(ip), vm ? vm[1] + ' ' + vm[2] : ip.split('\n').filter(l => /veth[0-9A-Za-z]{6}|link-netnsid/.test(l)).join(' / '));
    const sc = await consoleRun(page, ['clear', 'cat /run/antumbra/selfcheck.status']);
    ok('selfcheck.status: firewall-android and android-bridge in the image with Android', sc.includes('firewall OK\nfirewall-android OK\nandroid-bridge OK\nlxc-net OK'));
    await page.evaluate(() => ANTUMBRA_SIM.test.selfcheckLate());
    const sc2 = await consoleRun(page, ['clear', 'cat /run/antumbra/selfcheck.status']);
    const late = sc2.slice(sc2.indexOf('qrtr-access OK\n') + 15);
    ok('late self-check appended: without binder/android-off (Android on), with modem and mac-wlan0 lines (Wi-Fi not connected: the scan address)', late.includes('firewall OK') && !late.includes('binder OK') && late.includes('modem-radio OK\nmodem-registration OK\nmac-wlan0 (scan address) OK'), late.slice(0, 200));
    await page.close();
  },
  async consoleCommands() {
    const page = await fresh(IPHONE, { prefs: { androidImage: true } });
    await start(page);            // no passphrase
    await sleep(2500);
    const t = await consoleRun(page, ['sudo antumbra-tor-connect status', 'ping 1.1.1.1', 'help', 'uname -a', 'ip a', 'cat /run/antumbra/selfcheck.status']);
    ok('sudo without a passphrase: no prompt, sudo\'s refusal for a user with other rules', t.includes("Sorry, user amnesia is not allowed to execute '/usr/local/sbin/antumbra-tor-connect status' as root on amnesia.") && !t.includes('not in the sudoers file') && (await page.textContent('.term-in .ps')) === 'amnesia@amnesia:~$');
    ok('ping: command not found (the image has no ping)', t.includes('bash: ping: command not found') && !t.includes('PING 1.1.1.1'));
    ok('help no longer lists ping', !/date, ping,/.test(t));
    ok('uname -a: the phone\'s kernel release', t.includes('Linux amnesia 6.17.0-sm8150-hotdog-clean-antumbra #6 SMP PREEMPT') && t.includes('Android apps can read it too'));
    ok('ip a: five namespace veths with /30 addresses', ['veth-tbb', 'veth-onioncircs', 'veth-tca', 'veth-onionshare', 'veth-clearnet'].every(v => t.includes(v + '@if')) && t.includes('inet 10.200.1.17/30 scope global veth-clearnet'));
    ok('ip a: the Android bridge exists with Android off (NO-CARRIER, DOWN, /30)', /waydroid-tor: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN/.test(t) && t.includes('inet 10.200.2.1/30 scope global waydroid-tor'));
    ok('selfcheck.status: binder and android-off while Android is off', t.includes('lxc-net OK\nbinder OK\nandroid-off OK\nresolver OK'));
    await shot(page, 'console-sudo-ping');
    await page.close();
    // admin off with a passphrase: prompt, then the same refusal
    const p2 = await fresh(IPHONE);
    await start(p2, { lock: 'lockpass1' });
    const t2 = await consoleRun(p2, ['sudo antumbra-tor-connect status']);
    ok('sudo with Administration off asks for the password', (await p2.textContent('.term-in .ps')) === '[sudo] password for amnesia:');
    const t3 = await consoleRun(p2, ['lockpass1']).catch(() => '');
    await p2.fill('.term-in input', 'lockpass1').catch(() => {});
    const out = await p2.innerText('.term-out');
    ok('…then refuses the command (not "not in the sudoers file")', out.includes("Sorry, user amnesia is not allowed to execute '/usr/local/sbin/antumbra-tor-connect status' as root on amnesia.") && !out.includes('sudoers file'), (t2 + t3).slice(-200));
    await p2.close();
  },
  async snapshotDenied() {
    const page = await fresh(IPHONE);
    await start(page);
    await page.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Snapshot'));
    await page.waitForSelector('.modal-back');
    await page.TL(page.locator('.dbtns button', { hasText: 'Cancel' }));
    await sleep(300);
    ok('Cancel: Snapshot\'s permission-denied page', (await page.textContent('.status-page h4')) === 'Missing Camera Permission' && (await page.textContent('.status-page p')) === 'Allow camera usage in Settings');
    ok('…its header shows the window title "Camera" (camera.ui, window.ui)', (await page.textContent('.snap-hb h3')) === 'Camera');
    ok('…with no shutter or mode buttons, camera down', !(await page.$('.shutter')) && !(await page.$('.snap-modes')) && (await page.evaluate(() => ANTUMBRA_SIM.state.cam.pos)) === 'down');
    ok('…and no invented "Snapshot\'s own text is not recorded" line', !(await page.textContent('.win')).includes('not recorded'));
    await shot(page, 'camera-denied');
    await page.T('[data-k="menu"]');
    await page.waitForSelector('.pop [role="menuitem"]');
    const items = await page.$$eval('.pop [role="menuitem"]', b => b.map(x => x.textContent.trim()));
    ok('Snapshot menu: Preferences, Keyboard Shortcuts, About Camera, then labelled simulator items, no Quit', items.slice(0, 3).join('|') === 'Preferences|Keyboard Shortcuts|About Camera' && !items.includes('Quit') && items.slice(3).every(i => i.startsWith('Simulator')), items.join('|'));
    await page.keyboard.press('Escape');
    await page.close();
    const p2 = await fresh(IPHONE);
    await start(p2);
    await p2.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Snapshot'));
    await p2.waitForSelector('.modal-back');
    await p2.TL(p2.locator('.dbtns button', { hasText: 'Ok' }));
    await sleep(1200);
    await p2.T('[data-k="timer"]');
    await p2.waitForSelector('.pop [role="option"]');
    const cd = await p2.$$eval('.pop [role="option"]', b => b.map(x => x.textContent.trim()));
    ok('countdown is a menu: None, 3s, 5s, 10s', cd.join('|') === 'None|3s|5s|10s', cd.join('|'));
    await p2.TL(p2.locator('.pop [role="option"]', { hasText: '5s' }));
    ok('countdown set to 5s', (await p2.textContent('[data-k="timer"] small')) === '5s');
    ok('raised camera: the chip says Simulator and no drop protection', (await p2.textContent('.cam-chip')).includes('Simulator · no drop protection'));
    ok('drop warning noted when the camera rises', (await p2.textContent('#pnotesList')).includes('no drop protection'));
    ok('photo picker opens the library, not the front camera (no capture attribute)', (await p2.getAttribute('#camFile', 'capture')) === null);
    await p2.close();
  },
  async selfcheckFail() {
    const page = await fresh(IPHONE, { prefs: { selfcheckFail: true, androidImage: true } });
    ok('banner lists both failed checks', (await page.textContent('.w-banner')).includes('firewall-android FAIL: the rules for the Android bridge are not loaded or incomplete'));
    await start(page, { android: true });
    await page.waitForFunction(() => /Android container start refused/.test(ANTUMBRA_SIM.test.journal().join('\n')), null, { timeout: 15000 });
    await sleep(500);
    const j = await J(page);
    ok('Android start refused by the start hook; Android stays stopped', j.includes("antumbra-waydroid: Android container start refused: the firewall's Android nat chain is missing") && !j.includes('Android boot completed') && (await page.evaluate(() => ANTUMBRA_SIM.state.adr.state)) === 'stopped');
    const t = await consoleRun(page, ['cat /run/antumbra/selfcheck.status']);
    ok('selfcheck.status: firewall and firewall-android FAIL', t.includes('firewall FAIL: Tor-enforcement ruleset is not loaded or incomplete\nfirewall-android FAIL: the rules for the Android bridge are not loaded or incomplete'));
    await page.close();
  },
  async welcomeBootMisc() {
    const page = await fresh(IPHONE, { intro: true });
    ok('intro: alpha, never booted on the phone; screens from a VM', (await page.textContent('.intro-card')).includes('has not yet booted on a real OnePlus 7T Pro') && (await page.textContent('.intro-card')).includes('as seen in a virtual machine'));
    ok('intro (iPhone): "an iPhone cannot boot it"', (await page.textContent('.intro-card')).includes('an iPhone cannot boot it'));
    await page.T('#introGo');
    await sleep(600);
    const o = await page.textContent('.orange');
    ok('orange screen: only the repository\'s wording', o.includes("Your device has been unlocked and can't be trusted.") && !o.includes('5 seconds') && (await page.textContent('.boot-cap')).includes('come from Antumbra\'s docs'));
    await page.waitForSelector('.w-root', { timeout: 15000 });
    await start(page);
    await page.evaluate(() => ANTUMBRA_SIM.test.overview(true));
    await sleep(300);
    await page.fill('#ovSearch', 'zzz');
    await sleep(200);
    ok('app search with no match: empty grid, no invented "No results"', (await page.$$('#ovGrid > *')).length === 0 && !(await page.textContent('#ov')).includes('No results'));
    await page.fill('#ovSearch', '');
    await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.open('org.gnome.TextEditor'); });
    await page.waitForSelector('textarea.editor');
    ok('Text Editor: "New Document"', (await page.textContent('.win .hb h3')) === 'New Document');
    await page.T('[data-k="save"]');
    ok('save name defaults to "New Document.txt"', (await page.inputValue('#saveName')) === 'New Document.txt');
    await page.evaluate(() => ANTUMBRA_SIM.test.reset());
    // Wi-Fi rows (Phosh layout) and the scan button
    await sleep(2500);
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.drawer(true); });
    await sleep(300);
    await page.T('[data-tile="wifi"] .arrow');
    await sleep(300);
    const rows = await page.$$eval('.net-row', r => r.map(x => ({ t: x.textContent.trim(), badge: !!x.querySelector('.badge'), small: !!x.querySelector('small') })));
    ok('Wi-Fi rows: SSID only, padlock badge on secured networks, no subtitles', rows.length === 3 && rows.every(r => !r.small) && rows.map(r => r.t).join('|') === 'Home|Café guest|Library' && rows[0].badge && !rows[1].badge, JSON.stringify(rows));
    ok('networks marked simulated once, below the list', (await page.$$('.qs-sub .simline')).length === 1);
    ok('fold handle reachable from the Wi-Fi page', (await topAt(page, '#qsFold')).includes('(inside)'), await topAt(page, '#qsFold'));
    await page.T('.qs-sub .scan button');
    ok('scan button shows a spinner', !!(await page.$('.qs-sub .scan .spin')));
    await shot(page, 'wifi-rows');
    await page.TL(page.locator('.net-row', { hasText: 'Home' }));
    await page.waitForSelector('#wifiPw');
    await page.fill('#wifiPw', 'password1');
    await page.TL(page.locator('.dbtns button', { hasText: 'Connect' }));
    await page.waitForFunction(() => ANTUMBRA_SIM.state.net.ssid === 'Home', null, { timeout: 5000 });
    await sleep(300);
    ok('connected network: check mark', !!(await page.$('.net-row .ic use[href="#i-object-select-symbolic"]')));
    const fr = await rect(page, '#qsFold');
    await touchSwipe(page, 195, fr.top + fr.height / 2, 195, 200);
    await sleep(500);
    ok('swipe up on the fold closes quick settings from the Wi-Fi page', !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.drawer)));
    // Tor at 100 % is labelled acted out
    await page.waitForFunction(() => ANTUMBRA_SIM.state.tor.done, null, { timeout: 40000 });
    await page.evaluate(() => ANTUMBRA_SIM.test.open('tor-browser'));
    await page.waitForSelector('#tbPage');
    ok('Tor Browser: 100 % marked acted out', (await page.textContent('#tbPage')).includes('acted out'));
    ok('Tor note: acted out, never past 14 % in Antumbra', (await page.textContent('#pnotesList')).includes('acted out: Antumbra\'s Tor has not yet bootstrapped past 14 %'));
    // shutdown console
    await page.evaluate(() => { ANTUMBRA_SIM.test.power('poweroff'); });
    await page.waitForFunction(() => (document.querySelector('.console') || {}).textContent?.includes('reboot: Power down'), null, { timeout: 10000 });
    const con = await page.textContent('.console');
    ok('shutdown: the VM\'s real lines, "Powering off." before "Power down"', con.includes('Stopped antumbra-remove-overlayfs-dirs.service - Remove the overlayfs directories.') && /shutdown\[1\]: Powering off\.[\s\S]*reboot: Power down/.test(con));
    ok('shutdown: no invented lines', !/Returning to the initramfs|AntumbraData locked|rw and work directories/.test(con));
    ok('shutdown caption clear of the console lines', await page.evaluate(() => { const c = document.querySelector('.console .boot-cap').getBoundingClientRect(); const l = document.querySelector('.console > div:not(.boot-cap)').getBoundingClientRect(); return c.bottom <= l.top; }));
    await shot(page, 'shutdown-console');
    await page.waitForSelector('.off', { timeout: 8000 });
    ok('off screen: simulated, memory wipe not overstated', (await page.textContent('.off')).includes('Powered off (simulated)') && (await page.textContent('.off')).includes('not measured yet'));
    await page.close();
  },
  /* ---------------- iPhone ---------------- */
  async lockOverDialogs() {
    const page = await fresh(IPHONE, { safe: SAFE_P });
    await start(page, { lock: 'lockpass1' });
    await page.evaluate(() => ANTUMBRA_SIM.test.drawer(true));
    await sleep(300);
    await page.T('#qsPower');
    await page.TL(page.locator('.pop [role="menuitem"]', { hasText: 'Power Off…' }));
    await sleep(300);
    await page.T('#ctlPress').catch(async () => { await page.evaluate(() => document.querySelector('#ctlPress').click()); });
    await sleep(300);
    await page.T('.blank');
    await sleep(300);
    const st = await page.evaluate(() => { const m = document.querySelector('.modal-back'); const r = m.getBoundingClientRect(); const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return { locked: ANTUMBRA_SIM.state.sess.locked, inert: m.inert, under: m.classList.contains('under-lock'), top: t && !m.contains(t) }; });
    ok('locking hides the power-off dialog under the lock screen, out of reach', st.locked && st.inert && st.under && st.top, JSON.stringify(st));
    await shot(page, 'locked-dialog-hidden');
    await page.evaluate(() => ANTUMBRA_SIM.test.unlock());
    await sleep(200);
    ok('unlocking brings the dialog back, still counting', await page.evaluate(() => { const m = document.querySelector('.modal-back'); return !!m && !m.inert && !m.classList.contains('under-lock') && /in \d+ seconds/.test(m.textContent); }));
    await page.TL(page.locator('.dbtns button', { hasText: 'Cancel' }));
    // camera prompt: Ok cannot be pressed through the lock screen
    await page.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Snapshot'));
    await page.waitForSelector('.modal-back');
    await page.evaluate(() => ANTUMBRA_SIM.test.lock());
    await sleep(200);
    const ok1 = await page.evaluate(() => { const b = [...document.querySelectorAll('.dbtns button')].find(x => x.textContent === 'Ok'); const r = b.getBoundingClientRect(); const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return !b.contains(t); });
    ok('camera prompt under the lock screen: its Ok is not reachable', ok1);
    await page.evaluate(() => { const b = [...document.querySelectorAll('.dbtns button')].find(x => x.textContent === 'Ok'); const r = b.getBoundingClientRect(); document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).click(); });
    await sleep(800);
    ok('…a tap there leaves the camera down', (await page.evaluate(() => ANTUMBRA_SIM.state.cam.pos)) === 'down');
    await page.close();
  },
  async lockCheckRace() {
    const page = await fresh(DESKTOP);
    await start(page, { lock: 'lockpass1' });
    await page.evaluate(() => ANTUMBRA_SIM.test.lock());
    await page.evaluate(() => document.querySelector('#lkHint').click());
    await sleep(500);
    const before = errors.length;
    await page.fill('#lkEntry', '1234');
    await page.press('#lkEntry', 'Enter');
    await page.evaluate(() => { ANTUMBRA_SIM.test.power('poweroff'); });
    await sleep(1500);
    await page.fill('#lkEntry', 'lockpass1').catch(() => {});
    ok('passcode submitted just before power-off: no error', errors.length === before, errors.slice(before).join(' | '));
    await page.close();
    const p2 = await fresh(DESKTOP);
    await start(p2, { lock: 'lockpass1' });
    await p2.evaluate(() => ANTUMBRA_SIM.test.lock());
    await p2.evaluate(() => document.querySelector('#lkHint').click());
    await sleep(500);
    await p2.fill('#lkEntry', 'lockpass1');
    await p2.press('#lkEntry', 'Enter');
    await p2.evaluate(() => { ANTUMBRA_SIM.test.power('restart'); });
    await sleep(1500);
    ok('right passcode just before a restart: no error', errors.length === before, errors.slice(before).join(' | '));
    await p2.close();
  },
  async keyboardResize() {
    const page = await fresh(IPHONE);
    await pick(page, '#wTor', 'Through bridges');
    for (const sel of ['#wBridges', '#wLock', '#wLock2']) {
      await page.setViewportSize({ width: 390, height: 844 });
      await sleep(300);
      await page.evaluate(() => { document.activeElement && document.activeElement.blur(); document.querySelector('#wScroll').scrollTop = 0; });
      await sleep(200);
      await page.locator(sel).scrollIntoViewIfNeeded();
      await page.tap(sel);
      await sleep(200);
      await page.setViewportSize({ width: 390, height: 480 });
      await sleep(900);
      const r = await page.evaluate(s => { const e = document.querySelector(s); const b = e.getBoundingClientRect(); const t = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2); return { top: Math.round(b.top), bottom: Math.round(b.bottom), ih: innerHeight, hit: e.closest('.w-row').contains(t), kb: document.querySelector('.w-root').classList.contains('kb') }; }, sel);
      ok(`keyboard that resizes the page: ${sel} stays visible and uncovered`, r.top >= 0 && r.bottom <= r.ih && r.hit && r.kb, JSON.stringify(r));
      if (sel === '#wLock2') await shot(page, 'keyboard-resize');
    }
    await page.evaluate(() => document.activeElement.blur());
    await page.setViewportSize({ width: 390, height: 844 });
    await sleep(400);
    ok('keyboard closed: the Start bar is back', !(await page.evaluate(() => document.querySelector('.w-root').classList.contains('kb'))) && await page.isVisible('#wStart'));
    await page.close();
  },
  async layouts() {
    for (const [dev, name, safe] of [[LAND, '844x390', SAFE_L], [LAND_MAX, '932x430', SAFE_L]]) {
      const page = await fresh(dev, { safe });
      const r = await page.evaluate(() => ({ mobile: document.querySelector('#sim').classList.contains('sim-mobile'), fs: getComputedStyle(document.documentElement).getPropertyValue('--fs').trim(), start: (() => { const b = document.querySelector('#wStart').getBoundingClientRect(); return [b.width, b.height]; })(), screen: (() => { const b = document.querySelector('#screen').getBoundingClientRect(); return [b.left, b.top, b.right, b.bottom]; })(), h1: getComputedStyle(document.querySelector('.w-head h1')).fontSize }));
      ok(`landscape ${name}: full-screen phone layout, not the scaled frame`, r.mobile && r.fs === '1' && r.start[1] >= 40 && r.h1 === '24px', JSON.stringify(r));
      ok(`landscape ${name}: the screen keeps clear of the notch (safe areas left/right)`, r.screen[0] >= 47 && r.screen[2] <= dev.viewport.width - 47, JSON.stringify(r.screen));
      if (name === '844x390') await shot(page, 'landscape-welcome');
      await page.close();
    }
    const d = await fresh(DESKTOP);
    ok('desktop 1280x900: frame beside the panel', !(await d.evaluate(() => document.querySelector('#sim').classList.contains('sim-mobile'))));
    await d.close();
    const short = await fresh({ viewport: { width: 1280, height: 560 }, deviceScaleFactor: 1 });
    ok('short desktop window (1280x560): phone layout instead of a frame below 0.6 scale', await short.evaluate(() => document.querySelector('#sim').classList.contains('sim-mobile')));
    await short.close();
  },
  async hitAreas() {
    const page = await fresh(IPHONE, { safe: SAFE_P });
    await start(page);
    const c = await rect(page, '#simChip');
    await page.touchscreen.tap(c.left + c.width / 2, c.bottom + 3);
    await sleep(400);
    ok('a tap 3 px below the Sim chip opens the panel (not quick settings)', await page.isVisible('#panel.open') && !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.drawer)));
    const sizes = await page.evaluate(() => {
      const h = s => { const e = document.querySelector(s); if (!e) return null; const a = getComputedStyle(e, '::after'); const r = e.getBoundingClientRect(); return a.content !== 'none' && a.position === 'absolute' ? r.height - parseFloat(a.top) - parseFloat(a.bottom) : r.height; };
      return { chip: h('#simChip'), clear: (() => { const e = document.querySelector('#pnotesClear'); e.hidden = false; const v = e.getBoundingClientRect().height; return v; })() };
    });
    ok('Sim chip hit area 36 px (top bar plus 4 px, from the screen edge); panel Clear ≥ 40 px', sizes.chip >= 36 && sizes.clear >= 40, JSON.stringify(sizes));
    await page.T('#panelClose');
    await sleep(300);
    const t = await consoleRun(page, ['whoami']);
    const keys = await page.$$eval('.term-keys button', b => b.map(x => x.getBoundingClientRect().height));
    ok('Console shortcut keys ≥ 40 px tall', keys.every(h => h >= 40), keys.join(','));
    await page.evaluate(() => ANTUMBRA_SIM.test.closeAll());
    await sleep(300);
    const pill = await rect(page, '#pillHit');
    ok('bare home screen: pill hit area 40 px tall', pill.height >= 40, JSON.stringify(pill));
    await page.close();
  },
  async osHitAreas() {
    // a tap 3 px above and below the visible control still reaches it
    const reach = (page, sel) => page.evaluate(s => {
      const e = [...document.querySelectorAll(s)].find(x => { const r = x.getBoundingClientRect(); return r.width > 2 && r.height > 2; }); if (!e) return 'missing';
      const r = e.getBoundingClientRect(), x = r.left + r.width / 2;
      const hit = y => { const t = document.elementFromPoint(x, y); return !!t && (t === e || e.contains(t)); };
      return r.height >= 40 || (hit(r.top - 3) && hit(r.bottom + 3)) ? 'ok' : `${Math.round(r.height)} px, no reach`;
    }, sel);
    const page = await fresh(IPHONE);
    await pick(page, '#wPers', 'Create');
    await dismissSheet(page);
    const res = { peek: await reach(page, '#wPP ~ .peek, [data-for="wPP"] .peek') };
    await start(page, { create: 'a long enough passphrase' });
    await page.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Nautilus')); await sleep(800);
    await page.TL(page.locator('.frow', { hasText: 'Documents' }).first()); await sleep(200);
    res.hbtn = await reach(page, '.win .hb .hbtn.sim-btn');
    // the Sim chip's hit area ends above the visible Back button of an app header
    res.backClear = await page.evaluate(() => { const b = document.querySelector('.win .hb .hbtn').getBoundingClientRect(); const t = document.elementFromPoint(b.left + b.width / 2, b.top + 1); return t && t.closest('.hbtn') ? 'ok' : 'covered by ' + (t && (t.id || t.className)); });
    res.pathbar = await reach(page, '.pathbar button');
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('tor-browser'); }); await sleep(800);
    res.tbInfoClose = await reach(page, '.tb-info .x');
    res.tbImport = await reach(page, '.tb-imp button');
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.drawer(true); }); await sleep(400);
    res.slider = await reach(page, '#slBright');
    ok('OS controls under 40 px reach a finger 3 px beyond their edges', Object.values(res).every(v => v === 'ok'), JSON.stringify(res));
    await page.close();
  },
  async overviewSwipes() {
    const page = await fresh(IPHONE, { safe: SAFE_P });
    await start(page);
    const hb = await rect(page, '#homebar');
    for (const [name, from, to] of [['home bar to the edge', [195, hb.top + 5], [195, 843]], ['grid at its top', [195, 520], [195, 760]], ['search pill', [100, 0], [100, 300]]]) {
      await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.overview(true); });
      await sleep(400);
      if (name === 'search pill') { const s = await rect(page, '.ov-search'); from[1] = s.top + s.height / 2; to[1] = from[1] + 260; }
      await touchSwipe(page, from[0], from[1], to[0], to[1]);
      await sleep(500);
      ok(`swipe down on the ${name} folds the overview`, !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.overview)));
    }
    await page.close();
  },
  async desktopPowerButton() {
    const page = await fresh(DESKTOP);
    await start(page);
    const b = await rect(page, '#hwPower');
    await page.mouse.move(b.left + b.width / 2, b.top + b.height / 2);
    await page.mouse.down();
    await sleep(300);
    await page.mouse.move(b.left + 40, b.top + b.height / 2, { steps: 4 });
    await page.mouse.up();
    await sleep(5600);
    ok('desktop: a press that slides off the power button does nothing (no power-off 5 s later)', (await page.evaluate(() => ANTUMBRA_SIM.state.scr)) === 'session' && !(await page.evaluate(() => document.querySelector('#hwPower').classList.contains('held'))) && !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.locked)));
    await page.mouse.click(b.right + 8, b.top + b.height / 2);
    await sleep(300);
    ok('desktop: a click just beside the 5 px button (wider hit area) is a short press', await page.evaluate(() => ANTUMBRA_SIM.state.sess.locked && ANTUMBRA_SIM.state.sess.blank));
    await page.close();
  },
  async seLockKeypad() {
    const page = await fresh(SE, { safe: SAFE_P });
    await start(page, { lock: 'lockpass1' });
    await page.evaluate(() => ANTUMBRA_SIM.test.lock());
    await page.evaluate(() => document.querySelector('#lkHint').click());
    await sleep(700);
    const g = await page.evaluate(() => { const s = document.querySelector('#screen').getBoundingClientRect(), e = document.querySelector('#lkEntry').getBoundingClientRect(), u = document.querySelector('#lkUnlock').getBoundingClientRect(); return { entryH: e.height, gap: s.bottom - u.bottom }; });
    ok('375x667 lock keypad: entry keeps 46 px, Unlock clear of the bottom edge', g.entryH === 46 && g.gap >= 8, JSON.stringify(g));
    await shot(page, 'se-lock-keypad');
    await page.close();
  },
  async fontsAndRequests() {
    const page = await fresh(IPHONE);
    await page.evaluate(() => document.fonts.ready);
    const f = await page.evaluate(async () => { await Promise.all(['300 16px Roboto', '400 16px Roboto', '500 16px Roboto', '700 16px Roboto', '800 16px Roboto', '400 12px "Noto Sans Mono"'].map(x => document.fonts.load(x))); return [...document.fonts].filter(x => x.status === 'loaded').map(x => `${x.family} ${x.weight}`); });
    ok('embedded fonts load: Roboto 300/400/500/700/900 and Noto Sans Mono', ['"Roboto" 300', '"Roboto" 400', '"Roboto" 500', '"Roboto" 700', '"Roboto" 900', '"Noto Sans Mono" 400'].every(x => f.map(y => y.replace(/^Roboto/, '"Roboto"').replace(/^Noto Sans Mono/, '"Noto Sans Mono"')).includes(x)), f.join(', '));
    ok('no stylesheet or script from another origin', await page.evaluate(() => ![...document.querySelectorAll('link[href], script[src]')].length));
    await page.close();
  },
  async storageBlocked() {
    const page = await fresh(IPHONE, { lsThrow: true, intro: true });
    await page.T('#introGo');
    await page.waitForSelector('.w-root', { timeout: 15000 });
    await start(page, { create: 'a passphrase of mine' });
    ok('storage blocked: a note says the volume lasts only until reload', (await page.textContent('#pnotesList')).includes('This browser blocks site storage'));
    ok('…and the panel\'s live state says so', (await page.textContent('#liveState')).includes('lost at reload'));
    await page.close();
  },
  /* ---------------- honesty ---------------- */
  async persistentHonesty() {
    const page = await fresh(IPHONE);
    await start(page, { create: 'my real bank passphrase' });
    const ls = await page.evaluate(() => localStorage.getItem('antumbra-sim:persistent-storage:v1'));
    const vol = JSON.parse(ls);
    ok('volume passphrase: PBKDF2 hash, never the passphrase', vol.kdf === 'pbkdf2-sha256-310000' && vol.hash.length === 64 && !ls.includes('bank passphrase'));
    ok('Create warns that the simulated volume is NOT encrypted', (await page.textContent('#pnotesList')).includes('NOT encrypted') && (await page.textContent('#panelBody')).includes('The simulated Persistent Storage is NOT encrypted.'));
    // a picture made from the viewer's own photo never reaches localStorage
    await page.evaluate(() => ANTUMBRA_SIM.test.open('org.gnome.Snapshot'));
    await page.waitForSelector('.modal-back');
    await page.TL(page.locator('.dbtns button', { hasText: 'Ok' }));
    await page.waitForFunction(() => ANTUMBRA_SIM.state.cam.pos === 'up', null, { timeout: 4000 });
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==', 'base64');
    await page.setInputFiles('#camFile', { name: 'me.png', mimeType: 'image/png', buffer: png });
    await sleep(600);
    ok('own picture: "stays on this page; nothing is uploaded"', (await page.textContent('.cam-cap')).includes('nothing is uploaded'));
    await page.T('.shutter');
    await sleep(700);
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('org.gnome.Nautilus'); });
    await page.waitForSelector('.flist');
    await page.TL(page.locator('.frow', { hasText: 'Pictures' }).first()); await sleep(200);
    await page.TL(page.locator('.frow', { hasText: 'Camera' }).first()); await sleep(200);
    await page.T('.frow .more');
    await page.TL(page.locator('.pop [role="menuitem"]', { hasText: 'Move to Persistent' }));
    await sleep(300);
    const v2 = JSON.parse(await page.evaluate(() => localStorage.getItem('antumbra-sim:persistent-storage:v1')));
    ok('own picture moved to Persistent: only a placeholder is stored', v2.files.length === 1 && v2.files[0].placeholder === true && v2.files[0].img.startsWith('data:image/svg+xml'));
    await page.close();
  },
  async legacyVolume() {
    // a volume saved by the earlier page (fast cyrb53 hash) unlocks, then is re-hashed with PBKDF2
    function cyrb53(str, seed = 0) {
      let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
      for (let i = 0; i < str.length; i++) { const ch = str.charCodeAt(i); h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677); }
      h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
      h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
      return 4294967296 * (2097151 & h2) + (h1 >>> 0);
    }
    const pass = 'legacy passphrase', salt = '0123456789abcdef';
    const hash = cyrb53(salt + '\u0000' + pass, 7).toString(16) + cyrb53(pass + '\u0001' + salt, 13).toString(16);
    const vol = { v: 1, salt, hash, created: '2026-10-01T00:00:00Z', android: false, files: [{ name: 'old.txt', text: 'x', mtime: 0 }], wifi: [], fdroid: false, fdroidNotif: null, settings: {} };
    const { page } = await newPage(browser, IPHONE, { errors, storage: { ...PREFS(), 'antumbra-sim:persistent-storage:v1': JSON.stringify(vol) } });
    page.mobile = true; page.T = sel => page.tap(sel); page.TL = loc => loc.tap();
    await page.waitForSelector('.w-root', { timeout: 15000 });
    await pick(page, '#wPers', 'Unlock');
    await page.fill('#wPP', pass);
    await page.evaluate(() => document.querySelector('#wStart').click());
    await page.waitForSelector('.session', { timeout: 20000 });
    const v = JSON.parse(await page.evaluate(() => localStorage.getItem('antumbra-sim:persistent-storage:v1')));
    ok('a volume from the earlier page unlocks and is re-hashed with PBKDF2', v.kdf === 'pbkdf2-sha256-310000' && v.hash !== hash && v.files[0].name === 'old.txt');
    await page.close();
  },
  async panelHonesty() {
    const page = await fresh(DESKTOP, { intro: true });
    ok('desktop intro: "a web page cannot boot it"', (await page.textContent('.intro-card')).includes('a web page cannot boot it') && !(await page.textContent('.intro-card')).includes('an iPhone cannot boot it'));
    const body = await page.textContent('#panelBody');
    ok('panel: camera prompt is no protection, whatever you answer', body.includes('whatever you answer') && !body.includes('once one app was allowed'));
    ok('panel: no phone timing measured; VM roughly ten times slower', body.includes('No timing has been measured on a phone yet') && body.includes('roughly ten times slower') && body.includes('Phone, expected: "seconds"'));
    ok('panel: Tor past 14 % and bridge lines marked as never seen in a VM log', body.includes('acted out past 14 %') && body.includes('never appeared in a VM log'));
    ok('panel: plain words first (no virtual machines on iOS; "sensitivity" explained)', body.includes('iOS allows apps and web pages no virtual machine') && body.includes('which fields are enabled when'));
    ok('panel: Known issues come before Timings', body.indexOf('Known issues') < body.indexOf('Timings'));
    ok('panel credits: fonts embedded, not loaded from Google', body.includes('Fonts embedded in the page') && !body.includes('Google Fonts'));
    await page.T('#introGo');
    await page.waitForSelector('.w-root', { timeout: 15000 });
    ok('live state before Start: "network off until Start"', (await page.textContent('#liveState')).includes('network off until Start'));
    await page.close();
  },

  /* ---------------- final verification ---------------- */
  async encryptionSheet() {
    for (const [dev, name, safe] of [[IPHONE, 'iPhone', SAFE_P], [LAND, 'landscape 844x390', SAFE_L], [DESKTOP, 'desktop', undefined]]) {
      const page = await fresh(dev, { safe });
      const chip0 = await page.getAttribute('#simChip', 'aria-label');
      await pick(page, '#wPers', 'Create');
      await page.waitForSelector('.sheet-wrap.enc-sheet', { timeout: 3000 }).catch(() => {});
      const g = await page.evaluate(() => {
        const w = document.querySelector('.sheet-wrap.enc-sheet'); if (!w) return null;
        const s = document.querySelector('#screen').getBoundingClientRect(), b = w.querySelector('[data-close]').getBoundingClientRect();
        const pp = document.querySelector('[data-for="wPP"]').getBoundingClientRect();
        const atPP = document.elementFromPoint(pp.left + pp.width / 2, pp.top + pp.height / 2);
        return { text: w.textContent.replace(/\s+/g, ' '), badge: (w.querySelector('.badge-sim') || {}).textContent, label: w.getAttribute('aria-label'), modal: w.getAttribute('aria-modal'),
          inert: document.querySelector('.w-root').inert, focus: document.activeElement === w.querySelector('[data-close]'),
          btnOn: b.top >= s.top && b.bottom <= s.bottom && b.left >= s.left && b.right <= s.right && w.contains(document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2)),
          ppCovered: !!atPP && w.contains(atPP) };
      });
      ok(`${name}: choosing Create brings up the simulator's own sheet (NOT encrypted) before any passphrase can be typed`, g && /not encrypted/i.test(g.text) && g.text.includes('Do not type a passphrase you really use') && g.badge === 'Simulator' && g.label.startsWith('Simulator note') && g.modal === 'true' && g.inert && g.focus && g.btnOn && g.ppCovered, JSON.stringify(g && { ...g, text: g.text.slice(0, 70) }));
      if (name === 'iPhone') await shot(page, 'encryption-sheet');
      if (name.startsWith('landscape')) await shot(page, 'encryption-sheet-landscape');
      await page.T('.sheet-wrap [data-close]');
      await sleep(200);
      const after = await page.evaluate(() => { const r = document.querySelector('[data-for="wPP"]').getBoundingClientRect(); const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2); return { sheet: !!document.querySelector('.sheet-wrap'), inert: document.querySelector('.w-root').inert, focus: document.activeElement && document.activeElement.id, ppReach: !!t && !!t.closest('[data-for="wPP"]') }; });
      ok(`${name}: "I understand" closes it: nothing left over the Welcome screen, focus back on the combo row`, !after.sheet && !after.inert && after.focus === 'wPers' && after.ppReach, JSON.stringify(after));
      ok(`${name}: the warning stays in the panel's notes without raising the chip's count`, (await page.textContent('#pnotesList')).includes('NOT encrypted') && (await page.getAttribute('#simChip', 'aria-label')) === chip0, await page.getAttribute('#simChip', 'aria-label'));
      await pick(page, '#wPers', 'Do not use'); await pick(page, '#wPers', 'Create'); await sleep(200);
      ok(`${name}: shown once per page: choosing Create again does not repeat it`, !(await page.$('.sheet-wrap')));
      await page.close();
    }
  },
  async landscapeScreens() {
    for (const [dev, name, safe] of [[LAND, '844x390', SAFE_L], [LAND_SE, '667x375', undefined]]) {
      const page = await fresh(dev, { safe });
      ok(`landscape ${name}: Welcome controls reachable`, (await unreachable(page, ['#wPers', '#wMac', '#wTor', '#wLock', '#wLock2', '#wAdmin', '#wAndroid', '#wStart'])).length === 0, (await unreachable(page, ['#wPers', '#wMac', '#wTor', '#wLock', '#wLock2', '#wAdmin', '#wAndroid', '#wStart'])).join(', '));
      await start(page, { lock: '123456', android: name === '844x390' });
      await page.evaluate(() => ANTUMBRA_SIM.test.reset());
      // lock screen keypad: all twelve keys, the entry and Unlock on screen
      await page.evaluate(() => ANTUMBRA_SIM.test.lock()); await sleep(300);
      await page.T('#lkHint'); await sleep(700);
      const keys = ['#lkEntry', '#lkUnlock', ...Array.from({ length: 12 }, (_, i) => `#keypad button:nth-child(${i + 1})`)];
      const kbad = await unreachable(page, keys);
      ok(`landscape ${name}: lock screen: entry, all 12 keypad keys and Unlock on screen and reachable`, kbad.length === 0, kbad.join(', '));
      const kh = await page.evaluate(() => Math.min(...[...document.querySelectorAll('#keypad button')].map(b => b.getBoundingClientRect().height)));
      ok(`landscape ${name}: keypad keys stay finger-sized (≥ 56 px)`, kh >= 56, String(kh));
      if (name === '844x390') await shot(page, 'landscape-lock-keypad');
      for (const k of '123456') await page.TL(page.locator('#keypad button', { hasText: k }));
      await page.T('#lkUnlock');
      await page.waitForFunction(() => !ANTUMBRA_SIM.state.sess.locked, null, { timeout: 5000 }).catch(() => {});
      ok(`landscape ${name}: the passcode typed on the keypad unlocks`, !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.locked)));
      // quick settings
      await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.drawer(true); }); await sleep(400);
      const qbad = await unreachable(page, ['#slBright', '#slVol', '[data-tile="wifi"]', '[data-tile="wifi"] .arrow', '#qsFold']);
      ok(`landscape ${name}: quick settings reachable, fold handle included`, qbad.length === 0, qbad.join(', '));
      // app grid with apps open
      await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ['org.gnome.Console', 'org.gnome.Nautilus', 'tor-browser'].forEach(a => ANTUMBRA_SIM.test.open(a)); }); await sleep(900);
      await page.evaluate(() => ANTUMBRA_SIM.test.overview(true)); await sleep(500);
      const gh = await page.evaluate(() => document.querySelector('#ovScroll').getBoundingClientRect().height);
      const obad = await unreachable(page, ['.card-app .x', '#ovSearch', '#ovGrid .appbtn', '#ovShowAll']);
      ok(`landscape ${name}: overview with three apps open: cards, search and app grid all reachable (grid ≥ 100 px tall)`, gh >= 100 && obad.length === 0, `grid ${Math.round(gh)} px; ` + obad.join(', '));
      if (name === '844x390') await shot(page, 'landscape-overview-cards');
      await page.evaluate(() => { ANTUMBRA_SIM.test.overview(false); ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.open('org.gnome.Snapshot'); });
      await page.waitForSelector('.modal-back');
      if (name === '844x390') {
        // camera: allowed, preview with shutter
        await page.TL(page.locator('.dbtns button', { hasText: 'Ok' }));
        await page.waitForFunction(() => ANTUMBRA_SIM.state.cam.pos === 'up', null, { timeout: 4000 }); await sleep(400);
        const cbad = await unreachable(page, ['.shutter', '[data-k="timer"]', '.snap-modes button', '.snap-top [data-k="menu"]', '.cam-chip']);
        ok(`landscape ${name}: camera: shutter, countdown, modes and menu reachable`, cbad.length === 0, cbad.join(', '));
        // Android
        await page.evaluate(() => ANTUMBRA_SIM.test.closeAll());
        await page.waitForFunction(() => ANTUMBRA_SIM.state.adr.state === 'ready', null, { timeout: 40000 });
        await page.evaluate(() => ANTUMBRA_SIM.test.open('waydroid-ui')); await sleep(900);
        const abad = await unreachable(page, ['.win:not([hidden]) button']);
        ok(`landscape ${name}: Android's window reachable`, abad.length === 0, abad.join(', '));
      } else {
        // camera refused: Snapshot's status page scrolls from its top
        await page.TL(page.locator('.dbtns button', { hasText: 'Cancel' })); await sleep(300);
        const d = await page.evaluate(() => { const sc = document.querySelector('.snap-denied'); sc.scrollTop = 0; const i = sc.querySelector('.status-page .ic').getBoundingClientRect(), b = sc.getBoundingClientRect(); return { iconTop: Math.round(i.top), boxTop: Math.round(b.top), scrolls: sc.scrollHeight > sc.clientHeight }; });
        ok(`landscape ${name}: Snapshot's permission page scrolls from its top (icon not cut off above the scroll area)`, d.iconTop >= d.boxTop, JSON.stringify(d));
        const dbad = await unreachable(page, ['.snap-hb [data-k="menu"]', '.snap-denied .simline']);
        ok(`landscape ${name}: Snapshot's menu and the simulator line reachable`, dbad.length === 0, dbad.join(', '));
      }
      await page.close();
    }
  },
  async touchTargets() {
    const page = await fresh(IPHONE, { safe: SAFE_P });
    await start(page);
    await page.evaluate(() => ANTUMBRA_SIM.test.reset()); await sleep(300);
    const tb = await rect(page, '#topbar');
    const under = y => page.evaluate(y => { const t = document.elementFromPoint(250, y); return t ? (t.closest('#topbar') ? 'topbar' : t.closest('.win') ? 'app' : (t.id || String(t.className)).slice(0, 30)) : null; }, y);
    const bare = await under(tb.bottom + 6);
    await page.touchscreen.tap(250, tb.bottom + 6); await sleep(400);
    ok('bare home screen: the top bar takes taps 8 px below its edge (40 px); a tap 6 px under it opens quick settings', tb.height === 32 && bare === 'topbar' && await page.evaluate(() => ANTUMBRA_SIM.state.sess.drawer), `${bare}, bar ${tb.height} px`);
    await page.evaluate(() => ANTUMBRA_SIM.test.reset()); await sleep(300);
    const chipReach = await page.evaluate(() => { const c = document.querySelector('#simChip').getBoundingClientRect(), s = document.querySelector('#screen').getBoundingClientRect(); const x = c.left + c.width / 2; let y = s.top + 0.5; while (y < s.top + 60) { const t = document.elementFromPoint(x, y); if (!t || !t.closest('#simChip')) break; y += 1; } return Math.round(y - s.top); });
    ok('bare home screen: the Sim chip answers from the screen edge down to 40 px', chipReach >= 40, chipReach + ' px');
    await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.open('org.gnome.Nautilus'); }); await sleep(800);
    ok('app open: the top bar keeps Phosh\'s 32 px; just under it is the app\'s header', (await under(tb.bottom + 2)) === 'app', await under(tb.bottom + 2));
    const ph = await page.evaluate(() => {
      const x = innerWidth / 2, on = y => { const t = document.elementFromPoint(x, y); return !!t && (t.id === 'pillHit' || t.id === 'pillExt'); };
      let top = innerHeight - 0.5; while (top > 1 && on(top - 1)) top -= 1;
      const above = document.elementFromPoint(x, top - 2);
      return { span: Math.round(innerHeight - top), above: above && above.closest('.win') ? 'app' : above && (above.id || String(above.className)) };
    });
    ok('app open: the pill reaches a finger over ≥ 40 px (24 px of the screen plus the 34 px home-indicator area under it), and the app keeps everything above', ph.span >= 40 && ph.above === 'app', JSON.stringify(ph));
    await page.touchscreen.tap(195, 844 - 12); await sleep(500);
    const o1 = await page.evaluate(() => ANTUMBRA_SIM.state.sess.overview);
    await page.touchscreen.tap(195, 844 - 12); await sleep(500);
    ok('a tap in the safe area under the pill opens the overview, a second one closes it', o1 && !(await page.evaluate(() => ANTUMBRA_SIM.state.sess.overview)));
    await touchSwipe(page, 195, 844 - 14, 195, 420); await sleep(500);
    ok('a swipe up from under the pill opens the overview too', await page.evaluate(() => ANTUMBRA_SIM.state.sess.overview));
    await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.lock(); }); await sleep(300);
    await page.touchscreen.tap(195, 844 - 12); await sleep(400);
    ok('locked: the strip under the screen does nothing', await page.evaluate(() => ANTUMBRA_SIM.state.sess.locked && !ANTUMBRA_SIM.state.sess.overview));
    await page.close();
    // the Welcome screen and the panel do not get the strip
    const w = await fresh(IPHONE, { safe: SAFE_P });
    ok('Welcome screen: no hit strip under the screen', !(await w.isVisible('#pillExt')));
    await w.close();
  },
  async wlanScanAddress() {
    const page = await fresh(IPHONE);
    await start(page);
    await page.waitForFunction(() => ANTUMBRA_SIM.state.net.nm, null, { timeout: 8000 });
    const n = await page.evaluate(() => ({ cur: ANTUMBRA_SIM.state.net.cur, hw: ANTUMBRA_SIM.state.net.hw }));
    const ip = await consoleRun(page, ['ip a']);
    const m = ip.match(/wlan0: <NO-CARRIER[^\n]*\n\s+link\/ether (\S+) brd ff:ff:ff:ff:ff:ff permaddr (\S+)/);
    ok('not connected: ip a shows NetworkManager\'s random scan address on wlan0 (locally administered, unicast), permaddr the driver\'s', !!m && m[1] !== n.cur && m[2] === n.hw && /^[0-9a-f][26ae]:/.test(m[1]) && ip.includes('scan-rand-mac-address'), m ? `${m[1]} permaddr ${m[2]} (anonymised ${n.cur})` : ip.slice(-300));
    await page.evaluate(() => ANTUMBRA_SIM.test.selfcheckLate());
    const sc = await consoleRun(page, ['clear', 'cat /run/antumbra/selfcheck.status']);
    ok('…the late self-check says "mac-wlan0 (scan address) OK", as antumbra-selfcheck does below NM state 40', sc.split('\n').includes('mac-wlan0 (scan address) OK'), sc.split('\n').filter(l => l.startsWith('mac')).join(' | '));
    ok('…and the panel names it the scan address', (await page.textContent('#liveState')).includes('scan address while not connected'));
    await page.evaluate(() => { ANTUMBRA_SIM.test.closeAll(); ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.drawer(true); }); await sleep(300);
    await page.T('[data-tile="wifi"] .arrow'); await sleep(300);
    await page.TL(page.locator('.net-row', { hasText: 'Café guest' }));
    await page.waitForFunction(() => ANTUMBRA_SIM.state.net.ssid === 'Café guest', null, { timeout: 5000 });
    await page.evaluate(() => { ANTUMBRA_SIM.test.reset(); ANTUMBRA_SIM.test.closeAll(); });
    const ip2 = await consoleRun(page, ['ip a']);
    const m2 = ip2.match(/wlan0: <BROADCAST[^\n]*state UP[^\n]*\n\s+link\/ether (\S+) brd ff:ff:ff:ff:ff:ff permaddr (\S+)/);
    ok('connected: the anonymised address is back on wlan0', !!m2 && m2[1] === n.cur && m2[2] === n.hw && !ip2.includes('scan-rand-mac-address'), m2 ? m2[1] : ip2.slice(-300));
    await page.evaluate(() => ANTUMBRA_SIM.test.selfcheckLate());
    const sc2 = await consoleRun(page, ['clear', 'cat /run/antumbra/selfcheck.status']);
    const macs = sc2.split('\n').filter(l => l.startsWith('mac-wlan0'));
    ok('…and the next late self-check says "mac-wlan0 OK"', macs[macs.length - 1] === 'mac-wlan0 OK', macs.join(' | '));
    await page.close();
    const p2 = await fresh(IPHONE);
    await p2.evaluate(() => document.querySelector('#wMac').click());
    await start(p2);
    await p2.waitForFunction(() => ANTUMBRA_SIM.state.net.nm, null, { timeout: 8000 });
    await p2.evaluate(() => ANTUMBRA_SIM.test.selfcheckLate());
    const sc3 = await consoleRun(p2, ['cat /run/antumbra/selfcheck.status']);
    ok('anonymization off: "mac-wlan0 (anonymization off by choice) OK" whatever address is on wlan0', sc3.includes('mac-wlan0 (anonymization off by choice) OK') && !sc3.includes('(scan address)'));
    await p2.close();
  },
};

(async () => {
  browser = await launch();
  const only = process.argv.slice(2);
  for (const [name, fn] of Object.entries(scenarios)) {
    if (only.length && !only.includes(name)) continue;
    console.log(`--- ${name}`);
    try { await fn(); } catch (e) { ok(`${name} ran to the end`, false, e.message.split('\n')[0]); }
  }
  ok('no console errors, dialogs, popups, downloads or network requests', errors.length === 0, errors.join('\n'));
  await browser.close();
  const failed = results.filter(r => !r.pass);
  console.log(`\nfixes: ${results.length - failed.length}/${results.length} checks passed`);
  fs.writeFileSync(path.join(__dirname, 'results-fixes.json'), JSON.stringify({ results, errors }, null, 1));
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error('TEST CRASH', e); process.exit(2); });
