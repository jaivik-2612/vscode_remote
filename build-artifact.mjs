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
