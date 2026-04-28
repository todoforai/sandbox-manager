const fs = require('fs');
const path = require('path');

// Parse a KEY=VALUE env file into an object. Mirrors backend/ecosystem.config.js
// so PM2 picks up shared .env without needing a separate loader.
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

// REST port; deploy.sh sets DEPLOY_PORT for blue-green flips. Default 9000.
// Noise port is paired: REST + 10 (so 9000→9010, 9002→9012).
const port = process.env.DEPLOY_PORT || '9000';
const noisePort = String(parseInt(port, 10) + 10);

// Log dir: prod = /var/log/todoforai (created by deploy.sh setup running as root).
// Dev = ~/.pm2/logs default (PM2 fallback). Override with PM2_LOG_DIR.
const logDir = process.env.PM2_LOG_DIR
  || (fs.existsSync('/var/log/todoforai') ? '/var/log/todoforai' : null);

// Env loading mirrors run.sh: dev reads .env.development, prod reads .env.
// Prod also overlays shared/{.env,noise.env} (managed by deploy.sh). Later
// entries override earlier ones.
const baseDir = __dirname;
const sharedDir = path.join(baseDir, 'shared');
const isProd = process.env.NODE_ENV === 'production';
const envFromDisk = {
  ...loadEnvFile(path.join(baseDir, isProd ? '.env' : '.env.development')),
  ...loadEnvFile(path.join(sharedDir, '.env')),
  ...loadEnvFile(path.join(sharedDir, 'noise.env')),
};

module.exports = {
  apps: [
    {
      name: `sandbox-manager-${port}`,
      // Prod copies the binary to ./sandbox-manager (see deploy.sh); dev runs
      // straight out of cargo's target dir. Try the prod path, fall back to dev.
      script: fs.existsSync(path.join(baseDir, 'sandbox-manager'))
        ? './sandbox-manager'
        : './target/release/sandbox-manager',
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
        BIND_ADDR: `127.0.0.1:${port}`,
        NOISE_BIND_ADDR: `127.0.0.1:${noisePort}`,
      },
    },
  ],
};
