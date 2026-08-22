/**
 * Generates every image Google Play asks for, by driving the real app in a
 * headless browser. Screenshots are therefore never stale mock-ups: they are
 * the shipping UI at the exact pixel sizes the console validates.
 *
 * Usage:  node tools/store-assets.mjs [--out docs/store/assets]
 *
 * Needs a browser and a driver, neither of which is a repo dependency (they
 * would be dead weight in CI, which builds no images):
 *
 *   npm i --no-save playwright-core
 *   # then point at any installed Chrome/Chromium:
 *   CHROME_PATH="C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" \
 *     node tools/store-assets.mjs
 *
 * Play's specs, as implemented below:
 *   icon              512x512   32-bit PNG (alpha channel required)
 *   feature graphic  1024x500   PNG, no alpha, no important text at the edges
 *   phone            1080x1920  9:16, 2-8 of them
 *   7" tablet        1200x2048
 *   10" tablet       1600x2560
 */

import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

import { decode, encodeRgba, inspect } from './png.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const outArg = process.argv.indexOf('--out');
const OUT = outArg > -1 ? process.argv[outArg + 1] : 'docs/store/assets';

/* ------------------------------------------------------------- the browser */

const CANDIDATES = [
  process.env.CHROME_PATH,
  '/opt/pw-browsers/chromium',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/usr/bin/google-chrome',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
].filter(Boolean);

async function findBrowser() {
  for (const path of CANDIDATES) {
    try { await access(path); return path; } catch { /* keep looking */ }
  }
  throw new Error(
    'No Chrome or Chromium found. Install Chrome, or set CHROME_PATH to its ' +
    `executable. Looked in:\n  ${CANDIDATES.join('\n  ')}`);
}

let chromium;
try {
  ({ chromium } = await import('playwright-core'));
} catch {
  console.error('playwright-core is not installed. Run:\n' +
    '  npm i --no-save playwright-core\n' +
    'It is deliberately not a repo dependency — CI builds no images.');
  process.exit(1);
}

/* ------------------------------------------------- the app, in a known state */

const APP = `file://${ROOT}dist/app/index.html`;

try { await access(`${ROOT}dist/app/index.html`); } catch {
  console.error('dist/app/index.html is missing. Run `node build-artifact.mjs --app` first.');
  process.exit(1);
}

/**
 * A believable two-year history: a gently trending stock with a calm stretch
 * and a turbulent one, so the regime fit has something real to find and the
 * instruments show interesting values rather than flat lines.
 */
function sampleSeries(base = 178) {
  const out = [];
  let price = base * 0.82;
  let seed = 20260822;
  const rand = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff - 0.5;
  };
  for (let i = 0; i < 504; i++) {
    const turbulent = i > 250 && i < 340;
    const vol = turbulent ? 0.022 : 0.009;
    price *= 1 + 0.00055 + rand() * 2 * vol;
    out.push(price.toFixed(2));
  }
  return out.join('\n');
}

async function primeApp(page, { market = 'na', ticker = 'AAPL', strike, view = 'simple' } = {}) {
  await page.goto(APP);
  await page.waitForTimeout(500);
  await page.click('#notice-accept');

  await page.selectOption('#market', market);
  await page.fill('#ticker-search', ticker);
  await page.waitForTimeout(350);
  const first = page.locator('#ticker-listbox [role="option"]').first();
  if (await first.count()) {
    await first.click();
    await page.waitForTimeout(300);
  }

  await page.fill('#prices', sampleSeries());
  await page.dispatchEvent('#prices', 'input');
  await page.waitForTimeout(2000);

  if (strike !== undefined) {
    await page.fill('input[name="strike"]', String(strike));
    await page.dispatchEvent('input[name="strike"]', 'input');
    await page.waitForTimeout(2000);
  }
  if (view === 'advanced') {
    await page.click('.view-tab[data-view="advanced"]');
    await page.waitForTimeout(600);
  }
  // Charts animate in; let everything settle before the shutter.
  await page.waitForTimeout(400);
}

/**
 * Scrolls so `selector` sits just below the sticky masthead, then shoots the
 * whole viewport. Without the masthead offset the header eats each panel's
 * title row, which is exactly the line that tells a browsing user what the
 * instrument below it is.
 */
async function shoot(page, file, selector) {
  if (selector) {
    await page.evaluate((sel) => {
      const node = document.querySelector(sel);
      if (!node) return;
      const masthead = document.querySelector('.masthead');
      const cover = masthead ? masthead.getBoundingClientRect().height : 0;
      const top = node.getBoundingClientRect().top + window.scrollY - cover - 10;
      window.scrollTo({ top: Math.max(0, top), behavior: 'instant' });
    }, selector);
    await page.waitForTimeout(350);
  }
  await page.screenshot({ path: `${OUT}/${file}` });
  console.log(`  ${file}`);
}

/* --------------------------------------------------------------------- run */

await mkdir(OUT, { recursive: true });
const browser = await chromium.launch({ executablePath: await findBrowser() });

// --- app icon: 512x512 with a real alpha channel. Play requires a 32-bit
//     PNG, and every encoder drops alpha from a fully opaque image, so the
//     downscale is done here and written back out as RGBA explicitly.
{
  const source = decode(await readFile(`${ROOT}resources/icon.png`));
  const size = 512;
  const pixels = Buffer.alloc(size * size * 4);
  const ratio = source.width / size;
  // Box filter: the source is an exact 2x multiple, so each output pixel is
  // the mean of its block — no resampling artefacts on the dial's thin arcs.
  const block = Math.max(1, Math.round(ratio));
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0; let g = 0; let b = 0; let a = 0; let n = 0;
      for (let dy = 0; dy < block; dy++) {
        for (let dx = 0; dx < block; dx++) {
          const sx = Math.min(source.width - 1, Math.round(x * ratio) + dx);
          const sy = Math.min(source.height - 1, Math.round(y * ratio) + dy);
          const s = (sy * source.width + sx) * 4;
          r += source.pixels[s]; g += source.pixels[s + 1];
          b += source.pixels[s + 2]; a += source.pixels[s + 3];
          n++;
        }
      }
      const p = (y * size + x) * 4;
      pixels[p] = Math.round(r / n); pixels[p + 1] = Math.round(g / n);
      pixels[p + 2] = Math.round(b / n); pixels[p + 3] = Math.round(a / n);
    }
  }
  await writeFile(`${OUT}/icon-512.png`, encodeRgba({ width: size, height: size, pixels }));
  console.log('  icon-512.png');
}

// --- feature graphic: the banner at the top of the listing. Play may overlay
//     UI near the edges, so everything that matters stays centred.
{
  const icon = await readFile(`${ROOT}resources/icon.png`);
  const page = await browser.newPage({ viewport: { width: 1024, height: 500 } });
  await page.setContent(`<!doctype html><html><head><style>
    * { box-sizing: border-box; margin: 0; }
    body {
      width: 1024px; height: 500px; overflow: hidden;
      background:
        radial-gradient(1100px 520px at 50% -18%, #182029 0%, #0a0e12 62%),
        #0a0e12;
      display: grid; place-items: center;
      font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
      color: #e7ebef;
    }
    /* Faint instrument rule, echoing the cockpit's bezel seams. */
    body::before, body::after {
      content: ''; position: absolute; left: 96px; right: 96px; height: 1px;
      background: linear-gradient(90deg, transparent, #29323c 18%, #29323c 82%, transparent);
    }
    body::before { top: 84px; } body::after { bottom: 84px; }
    .stack { display: flex; align-items: center; gap: 44px; }
    .mark { width: 168px; height: 168px; border-radius: 34px; display: block;
            box-shadow: 0 18px 48px rgba(0,0,0,.55); }
    .type { display: flex; flex-direction: column; gap: 16px; }
    .name { font-size: 74px; font-weight: 700; letter-spacing: .01em; line-height: 1; }
    .name b { color: #ffb52e; font-weight: 700; }
    .rule { width: 88px; height: 3px; background: #ffb52e; border-radius: 2px; }
    .tag { font-size: 25px; color: #b6bfc8; letter-spacing: .03em; line-height: 1.35; }
    .models {
      display: flex; gap: 22px; margin-top: 8px;
      font-size: 15px; letter-spacing: .16em; text-transform: uppercase; color: #7d8892;
    }
    .models span { display: flex; align-items: center; gap: 8px; }
    .models i { width: 7px; height: 7px; border-radius: 50%; background: #ffb52e;
                box-shadow: 0 0 9px rgba(255,181,46,.75); }
  </style></head><body>
    <div class="stack">
      <img class="mark" src="data:image/png;base64,${icon.toString('base64')}">
      <div class="type">
        <div class="name">Fair<b>Share</b></div>
        <div class="rule"></div>
        <div class="tag">Fair prices for stock options</div>
        <div class="models">
          <span><i></i>Black-Scholes</span>
          <span><i></i>Monte Carlo</span>
          <span><i></i>Baum-Welch</span>
        </div>
      </div>
    </div>
  </body></html>`);
  await page.waitForTimeout(400);
  await page.screenshot({ path: `${OUT}/feature-graphic-1024x500.png` });
  await page.close();
  console.log('  feature-graphic-1024x500.png');
}

/* Each entry: file name, how to set the app up, what to scroll to. */
const SHOTS = [
  { file: '01-fair-value', setup: { strike: 175 }, at: '#dial-instrument' },
  { file: '02-break-even', setup: { strike: 165 }, at: '#simple-readout .decision-panel' },
  { file: '03-probability', setup: { strike: 175 }, at: '.instrument-grid' },
  { file: '04-outlook', setup: { strike: 175 }, at: '#barbell' },
  { file: '05-markets', setup: { market: 'jp', ticker: 'toyota motor', strike: 3000 }, at: null,
    top: true },
  { file: '06-advanced', setup: { strike: 175, view: 'advanced' }, at: '#ens-regimes' },
];

const FORMATS = [
  { name: 'phone', width: 360, height: 640, scale: 3 },      // 1080x1920
  { name: 'tablet7', width: 600, height: 1024, scale: 2 },   // 1200x2048
  { name: 'tablet10', width: 800, height: 1280, scale: 2 },  // 1600x2560
];

for (const format of FORMATS) {
  console.log(`${format.name} (${format.width * format.scale}x${format.height * format.scale}):`);
  const page = await browser.newPage({
    viewport: { width: format.width, height: format.height },
    deviceScaleFactor: format.scale,
    colorScheme: 'dark',
  });
  for (const shot of SHOTS) {
    await primeApp(page, shot.setup);
    if (shot.top) await page.evaluate(() => window.scrollTo(0, 0));
    await shoot(page, `${format.name}-${shot.file}.png`, shot.at);
  }
  await page.close();
}

await browser.close();

/* ------------------------------------------------- confirm what we produced */

const { readdir } = await import('node:fs/promises');
const files = (await readdir(OUT)).filter((f) => f.endsWith('.png')).sort();
const report = [];
let bad = 0;
for (const file of files) {
  const info = inspect(await readFile(`${OUT}/${file}`));
  const alpha = info.hasAlpha;
  // Play caps each listing image at 8 MB.
  const oversize = info.bytes > 8 * 1024 * 1024;
  const iconNeedsAlpha = file.startsWith('icon-') && !alpha;
  if (oversize || iconNeedsAlpha) bad++;
  report.push(`${file.padEnd(34)} ${String(info.width).padStart(5)}x${String(info.height).padEnd(5)}` +
    ` ${(info.bytes / 1024).toFixed(0).padStart(5)} KB  ${alpha ? 'RGBA' : 'RGB '}` +
    `${oversize ? '  OVER 8MB LIMIT' : ''}${iconNeedsAlpha ? '  ICON NEEDS ALPHA' : ''}`);
}
await writeFile(`${OUT}/MANIFEST.txt`,
  `Generated by tools/store-assets.mjs\n\n${report.join('\n')}\n`);
console.log(`\n${report.join('\n')}`);
console.log(`\n${files.length} images in ${OUT}/`);
if (bad) {
  console.error(`${bad} image(s) violate Play's constraints — see above.`);
  process.exit(1);
}
