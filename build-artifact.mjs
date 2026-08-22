/**
 * Bundles the web app into a single self-contained HTML file.
 *
 * The published page cannot fetch anything from its own origin, so the CSS,
 * the UI script and every pricing module have to be inlined. Rather than
 * maintain a second copy of the app, this rewrites the real sources: each
 * module becomes an IIFE, and its imports become destructuring from the
 * module it imported. Module boundaries survive, so `price` in the tree and
 * `price` in Black-Scholes stay separate.
 */

import { readFile, writeFile, mkdir } from 'node:fs/promises';

/* Dependency order: every module must appear after everything it imports,
   because the bundle is a flat sequence of IIFEs with no resolver. */
const MODULES = [
  { file: 'src/stats.js', global: 'Stats' },
  { file: 'src/blackScholes.js', global: 'BlackScholes' },
  { file: 'src/binomial.js', global: 'Binomial' },
  { file: 'src/impliedVol.js', global: 'ImpliedVol' },
  { file: 'src/series.js', global: 'Series' },
  { file: 'src/market.js', global: 'Market' },
  { file: 'src/decision.js', global: 'Decision' },
  { file: 'src/hmm.js', global: 'Hmm' },
  { file: 'src/monteCarlo.js', global: 'MonteCarlo' },
  { file: 'src/valuation.js', global: 'Valuation' },
  { file: 'src/ensemble.js', global: 'Ensemble' },
  { file: 'src/index.js', global: 'Engine' },
];

const BY_PATH = {
  './stats.js': 'Stats',
  './blackScholes.js': 'BlackScholes',
  './binomial.js': 'Binomial',
  './impliedVol.js': 'ImpliedVol',
  './series.js': 'Series',
  './market.js': 'Market',
  './decision.js': 'Decision',
  '../src/decision.js': 'Decision',
  './hmm.js': 'Hmm',
  './monteCarlo.js': 'MonteCarlo',
  './valuation.js': 'Valuation',
  './ensemble.js': 'Ensemble',
  './index.js': 'Engine',
  '../src/index.js': 'Engine',
};

/** Collects the names a module exports, so the IIFE can return them. */
function collectExports(source) {
  const names = new Set();
  for (const [, name] of source.matchAll(/^export\s+(?:async\s+)?function\s+(\w+)/gm)) {
    names.add(name);
  }
  for (const [, name] of source.matchAll(/^export\s+const\s+(\w+)/gm)) names.add(name);
  // `export { a, b as c }` and `export { x } from './y.js'`
  for (const [, clause] of source.matchAll(/^export\s*\{([^}]*)\}/gm)) {
    for (const part of clause.split(',')) {
      const alias = part.trim().split(/\s+as\s+/);
      const name = (alias[1] ?? alias[0]).trim();
      if (name) names.add(name);
    }
  }
  // `export * as stats from './stats.js'`
  for (const [, name] of source.matchAll(/^export\s+\*\s+as\s+(\w+)\s+from/gm)) names.add(name);
  return [...names];
}

/** Rewrites import and export syntax into plain statements. */
function rewrite(source) {
  return source
    // import { a, b } from './x.js'  ->  const { a, b } = Global;
    .replace(/^import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"];?/gms, (whole, clause, path) => {
      const global = BY_PATH[path];
      if (!global) throw new Error(`unmapped import: ${path}`);
      return `const {${clause.replace(/\s+as\s+/g, ': ')}} = ${global};`;
    })
    // import * as ns from './x.js'  ->  const ns = Global;
    .replace(/^import\s*\*\s*as\s+(\w+)\s*from\s*['"]([^'"]+)['"];?/gm, (whole, ns, path) => {
      const global = BY_PATH[path];
      if (!global) throw new Error(`unmapped import: ${path}`);
      return `const ${ns} = ${global};`;
    })
    // export * as ns from './x.js'  ->  const ns = Global;
    .replace(/^export\s*\*\s*as\s+(\w+)\s*from\s*['"]([^'"]+)['"];?/gm, (whole, ns, path) => {
      const global = BY_PATH[path];
      if (!global) throw new Error(`unmapped re-export: ${path}`);
      return `const ${ns} = ${global};`;
    })
    // export { a, b } from './x.js'  ->  const { a, b } = Global;
    .replace(/^export\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"];?/gms, (whole, clause, path) => {
      const global = BY_PATH[path];
      if (!global) throw new Error(`unmapped re-export: ${path}`);
      return `const {${clause.replace(/\s+as\s+/g, ': ')}} = ${global};`;
    })
    // export { a as b }  ->  const b = a;
    .replace(/^export\s*\{([^}]*)\};?/gms, (whole, clause) => clause
      .split(',')
      .map((part) => {
        const [from, to] = part.trim().split(/\s+as\s+/);
        return to ? `const ${to.trim()} = ${from.trim()};` : '';
      })
      .join('\n'))
    .replace(/^export\s+(?=(?:async\s+)?function|const|class)/gm, '');
}

async function moduleIife({ file, global }) {
  const source = await readFile(file, 'utf8');
  const exports = collectExports(source);
  const body = rewrite(source);
  return `/* ${file} */\nconst ${global} = (() => {\n${body}\n` +
    `return { ${exports.join(', ')} };\n})();`;
}

const bundle = [];
for (const module of MODULES) bundle.push(await moduleIife(module));
bundle.push(`/* web/app.js */\n${rewrite(await readFile('web/app.js', 'utf8'))}`);

const html = await readFile('web/index.html', 'utf8');
const css = await readFile('web/styles.css', 'utf8');

// The artifact host supplies the document skeleton, so keep only what goes
// inside it: the title, the font link, then the body's own markup.
const body = html.match(/<body>([\s\S]*?)<\/body>/)[1]
  .replace(/\s*<script[\s\S]*?<\/script>\s*/g, '\n');

// The reference data rides along inside the page: the artifact host blocks
// every external request, so anything the page needs must already be there.
// A plain (non-module) script sets the global before the app bundle runs —
// its presence is also how the app knows it is the artifact build.
const marketData = JSON.stringify({
  tickers: JSON.parse(await readFile('data/tickers.json', 'utf8')),
  rates: JSON.parse(await readFile('data/rates.json', 'utf8')),
});

// No webfonts: the page speaks the platform's own face (SF on Apple
// hardware), which is most of what makes it read as native.
const page = `<title>FairShare</title>
<style>
${css}
</style>
${body}
<script>window.__MARKET_DATA__ = ${marketData};</script>
<script type="module">
${bundle.join('\n\n')}
</script>
`;

await mkdir('dist', { recursive: true });
await writeFile('dist/option-fair-value.html', page);
console.log(`dist/option-fair-value.html — ${(page.length / 1024).toFixed(1)} KB`);

// --app additionally emits the same bundle as a complete standalone document
// under dist/app/, which is what the Capacitor shell loads as its webDir.
if (process.argv.includes('--app')) {
  const icon = 'data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 ' +
    'viewBox=%270 0 32 32%27%3E%3Ctext y=%2726%27 font-size=%2726%27%3E%F0%9F%93%88' +
    '%3C/text%3E%3C/svg%3E';
  // The artifact page opens with <title> and inline <style>; everything from
  // the first body element down belongs after </head>.
  const split = page.indexOf('<header');
  const full = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<link rel="icon" href="${icon}">
${page.slice(0, split)}</head>
<body>
${page.slice(split)}
</body>
</html>
`;
  await mkdir('dist/app', { recursive: true });
  await writeFile('dist/app/index.html', full);
  console.log(`dist/app/index.html — ${(full.length / 1024).toFixed(1)} KB (Capacitor webDir)`);
}

/**
 * Renders docs/store/PRIVACY.md as a standalone page for dist/pwa/.
 *
 * Both app stores demand a privacy policy at a live public URL, and Pages
 * already serves this directory — so the Markdown in the repo stays the one
 * source of truth and the hosted page can never drift from it. The
 * converter handles only what that document uses (setext-free ATX headings,
 * paragraphs, bold, italic, links); anything richer belongs in a real
 * Markdown library, and this deliberately fails loud rather than guessing.
 */
async function privacyPage() {
  const md = await readFile('docs/store/PRIVACY.md', 'utf8');
  const escape = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const inline = (s) => escape(s)
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*_])_([^_]+)_/g, '$1<em>$2</em>');

  const body = [];
  for (const block of md.split(/\n{2,}/)) {
    const text = block.trim();
    if (!text) continue;
    const heading = text.match(/^(#{1,6})\s+(.*)$/s);
    if (heading) {
      const level = heading[1].length;
      body.push(`<h${level}>${inline(heading[2].trim())}</h${level}>`);
    } else {
      body.push(`<p>${inline(text.replace(/\s*\n\s*/g, ' '))}</p>`);
    }
  }

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>FairShare — Privacy Policy</title>
<style>
:root {
  --ground: #f6f7f8; --ink: #191f26; --muted: #5d6771;
  --line: #c7ccd2; --accent: #9a6a08;
}
@media (prefers-color-scheme: dark) {
  :root { --ground: #0a0e12; --ink: #e7ebef; --muted: #97a1ab;
          --line: #29323c; --accent: #ffb52e; }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 40px 20px 72px;
  background: var(--ground); color: var(--ink);
  font: 400 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
}
main { max-width: 680px; margin: 0 auto; }
h1 {
  font: 700 13px/1.4 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  letter-spacing: .18em; text-transform: uppercase; color: var(--accent);
  margin: 0 0 6px; padding-bottom: 14px; border-bottom: 1px solid var(--line);
}
h2 {
  font: 600 19px/1.3 inherit; margin: 34px 0 10px;
}
p { margin: 0 0 14px; }
em { color: var(--muted); font-style: normal;
     font: 400 13px/1.5 ui-monospace, Menlo, Consolas, monospace; }
a { color: var(--accent); }
footer {
  margin-top: 44px; padding-top: 16px; border-top: 1px solid var(--line);
  font-size: 14px; color: var(--muted);
}
</style>
</head>
<body>
<main>
${body.join('\n')}
<footer><a href="./">&larr; Back to FairShare</a></footer>
</main>
</body>
</html>
`;
}

// --pwa emits an installable web app under dist/pwa/: the standalone
// document plus manifest, icons and a precaching service worker whose cache
// name carries this build's content hash.
if (process.argv.includes('--pwa')) {
  const { createHash } = await import('node:crypto');
  const { copyFile } = await import('node:fs/promises');

  const version = createHash('sha256').update(page).digest('hex').slice(0, 12);
  const split = page.indexOf('<header');
  const pwaHead = `<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#0a0e12">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="FairShare">
<link rel="manifest" href="./manifest.webmanifest">
<link rel="icon" href="./icon-192.png">
<link rel="apple-touch-icon" href="./apple-touch-icon.png">`;
  const registration = `<script>
if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  addEventListener('load', () => navigator.serviceWorker.register('./sw.js'));
}
</script>`;
  const pwaDoc = `<!doctype html>
<html lang="en">
<head>
${pwaHead}
${page.slice(0, split)}</head>
<body>
${page.slice(split)}
${registration}
</body>
</html>
`;

  await mkdir('dist/pwa', { recursive: true });
  await writeFile('dist/pwa/index.html', pwaDoc);
  const worker = await readFile('web/pwa/sw.js', 'utf8');
  await writeFile('dist/pwa/sw.js', worker.replace('__CACHE_VERSION__', version));
  for (const asset of ['manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png']) {
    await copyFile(`web/pwa/${asset}`, `dist/pwa/${asset}`);
  }
  await writeFile('dist/pwa/privacy.html', await privacyPage());
  console.log(`dist/pwa/ — installable build, cache fairshare-${version}`);
}
