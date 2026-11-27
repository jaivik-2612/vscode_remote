// Shared helpers: wrap the artifact in the publish skeleton and serve it from a fake https origin.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const SIM = path.resolve(__dirname, '..');
const PAGE = path.join(SIM, 'antumbra-simulator.html');
const SHOTS = process.env.SIM_SHOTS ? path.resolve(process.env.SIM_SHOTS) : path.join(SIM, 'shots');
const ORIGIN = 'https://antumbra-sim.test/';

function wrapped() {
  const body = fs.readFileSync(PAGE, 'utf8');
  return `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}body{margin:0;font:14px/1.4 system-ui,sans-serif;background:#f7f7f5}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>
${body}
</body></html>`;
}

async function launch() {
  // the cloud container's Chromium unless CHROMIUM names another
  return chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium-1194/chrome-linux/chrome', args: ['--no-sandbox'] });
}

const IPHONE = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true,
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1' };
const DESKTOP = { viewport: { width: 1280, height: 900 }, deviceScaleFactor: 1 };

// the page must make no request at all (its fonts are embedded): anything but the page itself is an error
async function newPage(browser, device, { errors, storage, safe, lsThrow } = {}) {
  const ctx = await browser.newContext(device);
  const page = await ctx.newPage();
  const html = wrapped();
  await page.route('**/*', route => {
    const u = route.request().url();
    if (u === ORIGIN) return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html });
    errors && errors.push('unexpected request: ' + u);
    return route.abort();
  });
  if (errors) {
    page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') errors.push(`console.${m.type()}: ${m.text()}`); });
    page.on('pageerror', e => errors.push('pageerror: ' + e.message + '\n' + (e.stack || '')));
    page.on('dialog', d => { errors.push('dialog: ' + d.type()); d.dismiss(); });
    page.on('popup', () => errors.push('popup opened'));
    page.on('download', () => errors.push('download started'));
  }
  if (errors) await page.addInitScript(() => { window.addEventListener('unhandledrejection', e => console.error('unhandledrejection: ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason))); });
  if (lsThrow) await page.addInitScript(() => { Object.defineProperty(window, 'localStorage', { configurable: true, get() { throw new DOMException('The operation is insecure.', 'SecurityError'); } }); });
  if (safe) { const c = await ctx.newCDPSession(page); await c.send('Emulation.setSafeAreaInsetsOverride', { insets: safe }); }
  if (storage) await ctx.addInitScript(s => { try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v); } catch (e) {} }, storage);
  await page.goto(ORIGIN);
  return { ctx, page };
}

module.exports = { launch, newPage, IPHONE, DESKTOP, SHOTS, ORIGIN };
