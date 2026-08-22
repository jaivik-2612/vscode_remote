/*
 * FairShare service worker: the whole app is one self-contained document
 * plus its icons, so the strategy is simply precache-then-serve. The cache
 * name carries a content hash stamped at build time; a new build installs
 * into a fresh cache, activation deletes the old ones, and the page picks
 * up the new version on its next load.
 */

const CACHE = 'fairshare-__CACHE_VERSION__';
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(ASSETS)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((key) => key.startsWith('fairshare-') && key !== CACHE)
          .map((key) => caches.delete(key)),
      ))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((hit) =>
      hit ?? fetch(event.request).then((response) => {
        // Cache same-origin responses opportunistically so a renamed asset
        // still works offline after it has been seen once.
        if (response.ok && new URL(event.request.url).origin === location.origin) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(event.request, copy));
        }
        return response;
      }),
    ),
  );
});
