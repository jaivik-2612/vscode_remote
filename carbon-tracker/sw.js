/* Service worker: offline app shell.
 * - Navigations: network first, cached shell as offline fallback.
 * - Static assets: cache first (bump CACHE on every release to update).
 * - Everything else (e.g. Supabase API calls) is untouched.
 */
'use strict';

const CACHE = 'cft-v1';
const ASSETS = [
  './',
  'index.html',
  'styles.css',
  'factors.js',
  'accounts.js',
  'cloud.js',
  'config.js',
  'app.js',
  'manifest.webmanifest',
  'icon-192.png',
  'icon-512.png',
];

self.addEventListener('install', (ev) => {
  ev.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (ev) => {
  const req = ev.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (req.mode === 'navigate') {
    ev.respondWith(fetch(req).catch(() => caches.match('index.html')));
    return;
  }

  const name = url.pathname.split('/').pop();
  if (ASSETS.includes(name)) {
    ev.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
  }
});
