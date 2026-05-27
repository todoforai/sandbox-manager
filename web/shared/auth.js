// shared-web/auth.js — auth + tiny DOM helpers shared by all *-manager web UIs.
//
// Auth model:
// - Production: Better Auth shared a session cookie across *.todofor.ai. The
//   cookie is HttpOnly so we attach `credentials: 'include'` on every fetch
//   and let the service's auth_extractor authenticate via the cookie.
// - Dev / cross-origin: paste an API key into the sign-in panel; it's saved
//   to localStorage and sent as `Authorization: Bearer <token>`.
//
// On 401 we mark the app unauthenticated and the host page should render its
// sign-in view (helper: renderSignIn).

export const FRONTEND_URL = location.hostname.endsWith('.todofor.ai')
  ? 'https://todofor.ai'
  : `${location.protocol}//localhost:3000`;
// Bounce through the home page with `?signin=1` so AuthProvider opens the
// modal (instead of auto-signing in as anonymous), and `?next=<here>` so it
// hands us a session back via a one-time token after sign-in. Drop any
// fragment from the current URL — single-use OTTs from prior round-trips
// must not be carried into the next handoff.
export const LOGIN_URL = `${FRONTEND_URL}/?signin=1&next=${encodeURIComponent(location.origin + location.pathname + location.search)}`;

/** Exchange an OTT (from #ott=… in the URL) for a real bearer session token.
 *  Done eagerly on module load so panel code never has to know about it. */
async function consumeOttFromUrl(setToken) {
  const m = location.hash.match(/[#&]ott=([^&]+)/);
  if (!m) return;
  const ott = decodeURIComponent(m[1]);
  // Strip the fragment immediately — single-use token, must not linger in
  // history/bookmarks/Referer.
  history.replaceState(null, '', location.pathname + location.search);
  try {
    const r = await fetch(`${FRONTEND_URL}/api/auth/one-time-token/verify`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: ott }),
    });
    if (!r.ok) return;
    const bearer = r.headers.get('set-auth-token');
    if (bearer) setToken(bearer);
  } catch {}
}

/** Per-app token storage namespace, e.g. 'sandbox', 'storage', 'browser'. */
export function makeAuth(appKey) {
  const TOKEN_KEY = `${appKey}_panel_token`;
  const getToken = () => { try { return localStorage.getItem(TOKEN_KEY) || ''; } catch { return ''; } };
  const setToken = (t) => { try { t ? localStorage.setItem(TOKEN_KEY, t) : localStorage.removeItem(TOKEN_KEY); } catch {} };
  // Eager OTT exchange (returns a Promise; we await it on the first api() call).
  const ottReady = consumeOttFromUrl(setToken);

  /** fetch wrapper: cookie-first, Bearer-fallback, JSON-aware, 401-aware. */
  async function api(path, opts = {}) {
    await ottReady; // first call may briefly wait for OTT exchange
    const headers = { ...(opts.headers || {}) };
    if (opts.body && !(opts.body instanceof FormData) && !(opts.body instanceof Blob)
        && typeof opts.body !== 'string' && !headers['Content-Type']) {
      headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.body);
    } else if (opts.body && !headers['Content-Type'] && typeof opts.body === 'string') {
      headers['Content-Type'] = 'application/json';
    }
    const tok = getToken();
    if (tok) headers['Authorization'] = `Bearer ${tok}`;
    const r = await fetch(path, { credentials: 'include', ...opts, headers });
    if (r.status === 401) { const err = new Error('unauthenticated'); err.unauth = true; throw err; }
    if (!r.ok) throw new Error(`${r.status} ${(await r.text()) || r.statusText}`);
    const ct = r.headers.get('content-type') || '';
    if (ct.includes('application/json')) return r.json();
    const text = await r.text();
    return text ? text : null;
  }

  return { TOKEN_KEY, getToken, setToken, api };
}

/** Tiny hyperscript-like DOM builder. */
export const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k === 'html') e.innerHTML = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    e.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
  }
  return e;
};

export const $ = (sel) => document.querySelector(sel);

export function fmtAge(ms) {
  if (!ms) return '—';
  const s = Math.floor((Date.now() - ms) / 1000);
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm';
  if (s < 86400) return Math.floor(s / 3600) + 'h';
  return Math.floor(s / 86400) + 'd';
}

export function fmtSize(n) {
  if (!n) return '';
  const u = ['B','K','M','G','T'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + u[i];
}

export function fmtDate(ms) {
  return ms ? new Date(ms).toISOString().slice(0, 16).replace('T', ' ') : '';
}

/** Standard sign-in card.
 *  onUseToken: (tokenString) => void — called when user pastes an API key. */
export function renderSignIn({ onUseToken, message } = {}) {
  return el('div', { class: 'signin' },
    el('div', { class: 'signin-card' },
      el('div', { class: 'icon' }, '🔒'),
      el('h2', {}, 'Sign in required'),
      el('p', {}, message || 'This panel uses your TODO for AI account. Sign in on the main site, then return here.'),
      el('a', { class: 'btn primary', href: LOGIN_URL }, 'Sign in at todofor.ai'),
      el('details', { style: 'margin-top:20px;text-align:left' },
        el('summary', { style: 'cursor:pointer;color:var(--muted-foreground);font-size:13px;padding:6px 0' }, 'Advanced: use API key instead'),
        el('div', { style: 'margin-top:10px;display:flex;gap:8px' },
          el('input', { id: '__token_input', type: 'password', placeholder: 'todofor.ai API key', style: 'flex:1' }),
          el('button', { onclick: () => {
            const v = document.getElementById('__token_input').value.trim();
            if (v && onUseToken) onUseToken(v);
          } }, 'Use'),
        ),
      ),
    ),
  );
}

/** Standard top bar.
 *  title: brand label (e.g. "sandbox" — rendered as "TODOforAI · <title>")
 *  chip:  optional Node to render in the right-hand user-chip slot. */
export function renderTopBar({ title, chip }) {
  return el('header', { class: 'app-bar' },
    el('div', { class: 'bar' },
      el('a', { class: 'brand', href: '/' },
        el('span', { class: 'dot' }),
        'TODO', el('b', {}, 'for'), 'AI',
        el('span', { class: 'crumbs', style: 'margin-left:8px' },
          el('span', { class: 'sep' }, '/'), title || '',
        ),
      ),
      el('div', {}),
      el('div', { id: 'user-chip' }, chip || ''),
    ),
  );
}

export function renderFooter(label = 'todofor.ai') {
  return el('footer', { class: 'app-footer' },
    'Powered by ', el('a', { href: 'https://todofor.ai', target: '_blank', rel: 'noopener noreferrer' }, label),
  );
}
