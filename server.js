/**
 * Static file server for the web UI.
 *
 * The browser needs the pricing modules served over HTTP rather than opened
 * from disk — ES module imports are blocked on file:// — so this exists
 * purely to hand out `web/` and `src/` during development. No dependencies,
 * so `npm start` works on a fresh clone with nothing installed.
 */

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('.', import.meta.url));
const PORT = Number(process.env.PORT) || 8080;
const HOST = process.env.HOST || '127.0.0.1';

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

/**
 * Map a request path to a file inside ROOT, or null if it escapes.
 * Rejecting traversal matters even for a local dev server: it is one
 * `..%2f` away from serving the rest of the disk.
 */
function resolvePath(urlPath) {
  const decoded = decodeURIComponent(urlPath.split('?')[0]);
  const relative = normalize(decoded).replace(/^(\.\.[/\\])+/, '');
  const full = join(ROOT, relative);
  if (full !== ROOT.replace(/[/\\]$/, '') && !full.startsWith(ROOT.endsWith(sep) ? ROOT : ROOT + sep)) {
    return null;
  }
  return full;
}

const server = createServer(async (request, response) => {
  // Redirect rather than rewrite: serving the app's HTML at "/" would leave
  // its relative "./app.js" pointing at the server root, where it is not.
  if (request.url === '/') {
    response.writeHead(302, { location: '/web/' });
    response.end();
    return;
  }

  const urlPath = request.url.endsWith('/') ? `${request.url}index.html` : request.url;
  const filePath = resolvePath(urlPath);

  if (filePath === null) {
    response.writeHead(403, { 'content-type': 'text/plain' });
    response.end('Forbidden');
    return;
  }

  try {
    const body = await readFile(filePath);
    response.writeHead(200, {
      'content-type': CONTENT_TYPES[extname(filePath)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    response.end(body);
  } catch (error) {
    const status = error.code === 'ENOENT' || error.code === 'EISDIR' ? 404 : 500;
    response.writeHead(status, { 'content-type': 'text/plain' });
    response.end(status === 404 ? 'Not found' : 'Server error');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Option fair value running at http://${HOST}:${PORT}`);
});
