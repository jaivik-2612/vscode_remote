/*
 * On-device accounts. Each account gets its own namespaced logs and settings
 * in localStorage, so several people can share a device (or one person can
 * keep separate spaces). The PIN gates the app's UI on this device — data is
 * not encrypted and never leaves the browser. A cloud-sync backend can plug
 * in behind this same interface later.
 */
'use strict';

const LS_USERS = 'cft:users';
const LS_SESSION = 'cft:session';

function lsGet(key, fallback) {
  try {
    const v = JSON.parse(localStorage.getItem(key));
    return v === null || v === undefined ? fallback : v;
  } catch (_) { return fallback; }
}
function lsSet(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) { /* storage unavailable */ }
}
function lsRemove(key) {
  try { localStorage.removeItem(key); } catch (_) { /* storage unavailable */ }
}

/* Shared password policy: 8+ characters with a letter, a number and a
 * special character. Returns a human explanation, or null when acceptable. */
function passwordProblem(pass) {
  if (!pass || pass.length < 8) return 'Password needs at least 8 characters.';
  if (!/[a-zA-Z]/.test(pass)) return 'Password needs at least one letter.';
  if (!/[0-9]/.test(pass)) return 'Password needs at least one number.';
  if (!/[^a-zA-Z0-9]/.test(pass)) return 'Password needs at least one special character (e.g. ! @ # $ %).';
  return null;
}

async function hashPin(pin, salt) {
  const text = `${salt}:${pin}`;
  if (typeof crypto !== 'undefined' && crypto.subtle) {
    try {
      const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
      return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
    } catch (_) { /* fall through to non-crypto fallback */ }
  }
  /* file:// and other non-secure contexts have no SubtleCrypto — FNV-1a
   * fallback keeps accounts usable there (a UI gate, not security). */
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return 'fnv:' + h.toString(16);
}

const Accounts = {
  list() { return lsGet(LS_USERS, []); },

  byId(id) { return this.list().find((u) => u.id === id) || null; },

  current() { return this.byId(lsGet(LS_SESSION, null)); },

  async create(name, pin, email) {
    name = (name || '').trim();
    email = (email || '').trim();
    if (!name) throw new Error('Please enter a name.');
    if (!/.+@.+\..+/.test(email)) throw new Error('Please enter a valid email address.');
    const problem = passwordProblem(pin);
    if (problem) throw new Error(problem);
    const users = this.list();
    const salt = Math.random().toString(36).slice(2) + Date.now().toString(36);
    const user = {
      id: 'u' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      name,
      email,
      salt,
      created: new Date().toISOString().slice(0, 10),
    };
    user.hash = await hashPin(pin, salt);
    const isFirst = users.length === 0;
    users.push(user);
    lsSet(LS_USERS, users);
    if (isFirst) {
      /* The first account inherits whatever was logged before accounts
       * existed (guest data), so nothing silently disappears. */
      const guestLogs = lsGet('cft:logs', []);
      const guestSettings = lsGet('cft:settings', null);
      if (guestLogs.length) lsSet(`cft:u:${user.id}:logs`, guestLogs);
      if (guestSettings) lsSet(`cft:u:${user.id}:settings`, guestSettings);
    }
    lsSet(LS_SESSION, user.id);
    return user;
  },

  async login(id, pin) {
    const u = this.byId(id);
    if (!u) return false;
    if (await hashPin(pin, u.salt) !== u.hash) return false;
    lsSet(LS_SESSION, u.id);
    return true;
  },

  logout() { lsSet(LS_SESSION, null); },

  remove(id) {
    lsSet(LS_USERS, this.list().filter((u) => u.id !== id));
    lsRemove(`cft:u:${id}:logs`);
    lsRemove(`cft:u:${id}:settings`);
    if (lsGet(LS_SESSION, null) === id) lsSet(LS_SESSION, null);
  },
};
