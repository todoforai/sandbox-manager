const fs = require('fs');
const path = require('path');

// Parse a KEY=VALUE env file into an object (shared .env without a loader dep).
function loadEnvFile(p) {
  const out = {};
  if (!fs.existsSync(p)) return out;
  for (const line of fs.readFileSync(p, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out[t.slice(0, i)] = t.slice(i + 1);
  }
  return out;
}

// Resolve a Go >=1.23 binary — PM2's daemon PATH often points at an older
// system Go (go.mod requires 1.23). Prefer an explicit GO_BIN / ~/sdk install.
function resolveGo() {
  const candidates = [
    process.env.GO_BIN,
    `${process.env.HOME || ''}/sdk/go1.23.4/bin/go`,
    '/usr/local/go/bin/go',
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return 'go'; // rely on PATH (dev machines with a current Go)
}
const GO = resolveGo();

// Resolve bun absolute path — PM2's daemon PATH on prod hosts often lacks
// ~/.bun/bin, so an `interpreter: 'bun'` literal can ENOENT.
function resolveBun() {
  const candidates = [
    process.env.BUN_BIN,
    `${process.env.HOME || ''}/.bun/bin/bun`,
    '/usr/local/bin/bun',
  ].filter(Boolean);
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return 'bun';
}
const BUN = resolveBun();

const baseDir = __dirname;
const isProd = process.env.NODE_ENV === 'production';
const envFromDisk = loadEnvFile(path.join(baseDir, isProd ? '.env' : '.env.development'));

const logDir = process.env.PM2_LOG_DIR
  || (fs.existsSync('/var/log/todoforai') ? '/var/log/todoforai' : null);

// Go service — dev runs from source via `go run`, prod runs the built binary.
const restApp = {
  name: 'sandbox-manager',
  script: isProd ? './sandbox-manager' : GO,
  args: isProd ? undefined : 'run ./cmd/sandbox-manager',
  interpreter: 'none',
  cwd: __dirname,
  instances: 1,
  exec_mode: 'fork',
  max_memory_restart: '1G',
  exp_backoff_restart_delay: 100,
  kill_timeout: 10000,
  watch: false,
  time: true,
  merge_logs: true,
  ...(logDir && {
    error_file: `${logDir}/sandbox-manager-err.log`,
    out_file: `${logDir}/sandbox-manager-out.log`,
  }),
  log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
  env: {
    ...envFromDisk,
    NODE_ENV: isProd ? 'production' : 'development',
  },
};

// Dev-only web sidecar: serves web/ on 8250 (user) + 8280 (admin), proxying
// to the REST API on :8200. In prod, nginx serves the static panels directly.
const webApp = !isProd && {
  name: 'sandbox-manager-web',
  script: 'web/dev-server.js',
  interpreter: BUN,
  cwd: __dirname,
  max_memory_restart: '256M',
  watch: false,
  time: true,
  merge_logs: true,
};

module.exports = { apps: [restApp, webApp].filter(Boolean) };
