const fs = require('fs');
const path = require('path');

// Resolve a Go >=1.26 binary — PM2's daemon PATH often points at an older
// system Go (go.mod requires 1.26). Prefer an explicit GO_BIN / ~/sdk install.
function resolveGo() {
  const candidates = [
    process.env.GO_BIN,
    `${process.env.HOME || ''}/sdk/go1.26.4/bin/go`,
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

const isProd = process.env.NODE_ENV === 'production';

const logDir = process.env.PM2_LOG_DIR
  || (fs.existsSync('/var/log/todoforai') ? '/var/log/todoforai' : null);

// The manager must run as ROOT: it talks to containerd.sock (root:root 0660),
// runs losetup / kata-runtime direct-volume / ip netns, and manages firecracker.
// PM2 itself runs as `master`, so we launch the binary through `sudo` — a
// NOPASSWD sudoers rule (/etc/sudoers.d/sandbox-manager-run) whitelists exactly
// this binary. sudo resets the environment (and refuses arbitrary KEY=VALUE
// args without SETENV), so the binary loads its own .env / .env.development
// from its cwd; we only pass NODE_ENV through (whitelisted via SETENV in the
// sudoers rule) so it picks the right file. Both dev and prod run the prebuilt
// ./sandbox-manager binary — `go run` as root would pollute root's Go cache —
// so in dev we build it here, synchronously, before PM2 launches it.
const binary = path.join(__dirname, 'sandbox-manager');
if (!isProd) {
  const go = require('child_process').spawnSync(
    GO, ['build', '-o', binary, './cmd/sandbox-manager'],
    { cwd: __dirname, stdio: 'inherit' });
  if (go.status !== 0) throw new Error('sandbox-manager build failed');
}

const restApp = {
  name: 'sandbox-manager',
  script: 'sudo',
  args: ['-n', `NODE_ENV=${isProd ? 'production' : 'development'}`, binary],
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
