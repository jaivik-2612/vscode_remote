/*
 * Cloud accounts & backup via Supabase (optional — see config.js).
 *
 * Auth uses Supabase's GoTrue REST endpoints (email + password). Data uses a
 * single `backups` row per user holding the full JSON payload (logs, settings,
 * templates) — a backup/restore model, not per-entry sync: simple, robust, and
 * exactly what protects a user who loses their device. Row-level security on
 * the table means users can only ever read/write their own row.
 */
'use strict';

const LS_CLOUD_SESSION = 'cft:cloudSession';

const Cloud = {
  enabled() {
    return typeof CLOUD_CONFIG !== 'undefined'
      && !!(CLOUD_CONFIG.supabaseUrl && CLOUD_CONFIG.supabaseAnonKey);
  },

  session() { return lsGet(LS_CLOUD_SESSION, null); },

  signOut() { lsSet(LS_CLOUD_SESSION, null); },

  _headers(token) {
    return {
      'Content-Type': 'application/json',
      apikey: CLOUD_CONFIG.supabaseAnonKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    };
  },

  async _auth(path, body) {
    const res = await fetch(`${CLOUD_CONFIG.supabaseUrl}/auth/v1/${path}`, {
      method: 'POST', headers: this._headers(), body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(data.msg || data.error_description || data.message || `Request failed (${res.status})`);
    }
    return data;
  },

  _storeSession(data) {
    const meta = (data.user && data.user.user_metadata) || {};
    lsSet(LS_CLOUD_SESSION, {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      expires_at: Math.floor(Date.now() / 1000) + (data.expires_in || 3600),
      user: {
        id: data.user.id,
        email: data.user.email,
        name: meta.name || (data.user.email || '').split('@')[0],
      },
    });
  },

  /* Returns { confirmed } — false when the project requires email confirmation
   * before the first sign-in. */
  async signUp(name, email, password) {
    const data = await this._auth('signup', { email, password, data: { name } });
    if (data.access_token) { this._storeSession(data); return { confirmed: true }; }
    return { confirmed: false };
  },

  async signIn(email, password) {
    const data = await this._auth('token?grant_type=password', { email, password });
    this._storeSession(data);
  },

  async _token() {
    let s = this.session();
    if (!s) throw new Error('Not signed in.');
    if (s.expires_at - 60 < Math.floor(Date.now() / 1000)) {
      const data = await this._auth('token?grant_type=refresh_token', { refresh_token: s.refresh_token });
      this._storeSession(data);
      s = this.session();
    }
    return s.access_token;
  },

  async backup(payload) {
    const token = await this._token();
    const s = this.session();
    const res = await fetch(`${CLOUD_CONFIG.supabaseUrl}/rest/v1/backups`, {
      method: 'POST',
      headers: { ...this._headers(token), Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify([{ user_id: s.user.id, payload, updated_at: new Date().toISOString() }]),
    });
    if (!res.ok) throw new Error(`Backup failed (${res.status})`);
  },

  /* Returns { payload, updated_at } or null when no backup exists yet. */
  async fetchBackup() {
    const token = await this._token();
    const s = this.session();
    const res = await fetch(
      `${CLOUD_CONFIG.supabaseUrl}/rest/v1/backups?select=payload,updated_at&user_id=eq.${encodeURIComponent(s.user.id)}`,
      { headers: this._headers(token) },
    );
    if (!res.ok) throw new Error(`Fetch failed (${res.status})`);
    const rows = await res.json();
    return rows.length ? rows[0] : null;
  },
};
