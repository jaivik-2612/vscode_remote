// Assembles the web test bench: injects the tsc-transpiled engine (CommonJS)
// from web-bench/build/ into shell.html as __define()'d modules.
// Run via `npm run bench` (which transpiles src/core first).
const fs = require('fs');
const path = require('path');

const here = __dirname;
const buildDir = path.join(here, 'build');
const modules = [
  'types',
  'templates/moved',
  'templates/startedBusiness',
  'templates/immigrateCanada',
  'templates/gotMarried',
  'templates/newChild',
  'templates/index',
  'intent',
  'planner',
  'progress',
];

let blob = '';
for (const name of modules) {
  const src = fs.readFileSync(path.join(buildDir, name + '.js'), 'utf8');
  blob += `__define(${JSON.stringify(name)}, function (exports, require, module) {\n${src}\n});\n`;
}

const shell = fs.readFileSync(path.join(here, 'shell.html'), 'utf8');
if (!shell.includes('/*__MODULES__*/')) throw new Error('placeholder missing in shell.html');
const out = shell.replace('/*__MODULES__*/', () => blob);
const target = path.join(here, 'lifeos-test-bench.html');
fs.writeFileSync(target, out);
console.log('wrote', target, out.length, 'bytes');
