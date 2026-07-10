/* Service worker: offline support with always-fresh updates.
 * Strategy: network first for everything same-origin, falling back to the
 * cache when offline. Every successful response refreshes the cache, so
 * deployments reach users on their next load — no version juggling.
 * Supabase API calls (different origin) are never intercepted.
 */
'use strict';

const CACHE = 'cft-v2';
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

  ev.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req).then((hit) => hit || (req.mode === 'navigate' ? caches.match('index.html') : undefined))),
  );
});
