#!/bin/bash
# sandbox-manager (Go) deployment script.
#
# DEPLOY: Push main to prod — GitHub Actions runs this script automatically:
#   git push origin main:prod
#
# Manual commands (run locally):
#   ./deploy.sh                Deploy to production
#   ./deploy.sh rollback [rel] Roll back to previous (or named) release
#   ./deploy.sh status         pm2 status + releases
#   ./deploy.sh logs           Tail pm2 logs
#   ./deploy.sh releases       List releases
#   ./deploy.sh setup          First-time server scaffolding (dirs, PM2, .env)
#   ./deploy.sh preflight      Check host prereqs (containerd/kata/devmapper)
#
# This service is a SINGLE pm2 instance launched as root via sudo (see
# ecosystem.config.js) — no blue/green port pair, no setcap (root has the
# caps), no nginx upstream flip. nginx already proxies vm.todofor.ai →
# 127.0.0.1:8200 directly. The heavy host stack (containerd + Kata-FC +
# devmapper + CNI + firecracker) is provisioned by scripts/spike-kata-fc.sh,
# NOT by this script; we only gate on it being present so we never half-deploy
# onto an unprepared host.

set -e

source "$(dirname "$0")/scripts/deploy-lib.sh"

SERVER="${SERVER:-root@sandbox.todofor.ai}"
DEPLOY_PATH="/var/www/todoforai/apps/sandbox-manager"
REPO="git@github.com:todoforai/sandbox-manager.git"
BRANCH="prod"
KEEP_RELEASES=5
PORT=8200
GO_VERSION="1.26.4"   # keep >= go.mod's toolchain
RESTART_CMD='NODE_ENV=production pm2 startOrReload ecosystem.config.js --env production && pm2 save --force'

# Host prerequisites the running service needs. The deploy aborts if any are
# missing — they come from scripts/spike-kata-fc.sh (run once per host), and a
# clone+build is pointless if the manager would crash on first VM create.
preflight() {
    log "Checking host prerequisites on $SERVER..."
    ssh "$SERVER" 'bash -s' <<'EOF'
        set -e
        miss=0
        chk() { if eval "$2"; then echo "✅ $1"; else echo "❌ $1 — run scripts/spike-kata-fc.sh"; miss=1; fi; }
        chk "containerd socket"  '[ -S /run/containerd/containerd.sock ]'
        chk "ctr CLI"            'command -v ctr >/dev/null'
        chk "kata-runtime"       '[ -x /opt/kata/bin/kata-runtime ]'
        chk "firecracker"        'command -v firecracker >/dev/null'
        chk "CNI bridge plugin"  '[ -x /opt/cni/bin/bridge ]'
        chk "/dev/kvm"           '[ -e /dev/kvm ]'
        chk "devmapper plugin"   'ctr plugin ls 2>/dev/null | grep -qi devmapper'
        [ "$miss" = 0 ] || { echo "Host not provisioned for the Go/Kata stack — aborting."; exit 1; }
        echo "✅ host ready"
EOF
}

deploy() {
    check_prod_status
    preflight
    log "Starting sandbox-manager deployment to $SERVER..."
    RELEASE=$(date +%Y%m%d%H%M%S)

    ssh "$SERVER" GO_VERSION="$GO_VERSION" RELEASE="$RELEASE" BRANCH="$BRANCH" \
        REPO="$REPO" DEPLOY_PATH="$DEPLOY_PATH" PORT="$PORT" KEEP="$KEEP_RELEASES" \
        'bash -s' <<'EOF'
        set -e
        REL_DIR="$DEPLOY_PATH/releases/$RELEASE"

        mkdir -p "$DEPLOY_PATH/releases" "$DEPLOY_PATH/shared"

        # Bootstrap a pinned Go toolchain — PM2's daemon PATH usually has no Go,
        # and ecosystem.config.js resolves /root/sdk/go<ver>/bin/go in prod.
        GO_BIN="/root/sdk/go${GO_VERSION}/bin/go"
        if [ ! -x "$GO_BIN" ]; then
            echo "Installing Go ${GO_VERSION}..."
            curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
                | tar -C "/root/sdk" -xz 2>/dev/null || {
                    mkdir -p /root/sdk
                    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /root/sdk -xz; }
            mv /root/sdk/go "/root/sdk/go${GO_VERSION}" 2>/dev/null || true
            [ -x "$GO_BIN" ] || { echo "❌ Go install failed at $GO_BIN"; exit 1; }
        fi
        echo "Go: $("$GO_BIN" version)"

        echo "Creating release $RELEASE..."
        git clone --depth 1 --branch "$BRANCH" "$REPO" "$REL_DIR"

        echo "Building sandbox-manager (go build)..."
        cd "$REL_DIR"
        "$GO_BIN" build -o ./sandbox-manager ./cmd/sandbox-manager

        # Share the persistent .env so config + secrets survive releases.
        ln -sfn "$DEPLOY_PATH/shared/.env" "$REL_DIR/.env"

        echo "Updating current symlink..."
        ln -sfn "$REL_DIR" "$DEPLOY_PATH/current"

        echo "Reloading sandbox-manager under pm2..."
        cd "$DEPLOY_PATH/current"
        # One-shot migration off the Rust blue/green instances. The Go
        # ecosystem.config.js is a single pm2 app named "sandbox-manager"; the
        # old Rust deploy ran "sandbox-manager-8200"/"-8202". Those would keep
        # holding :8200 and orphan themselves, so retire them first. Idempotent
        # — does nothing once gone.
        for legacy in sandbox-manager-8200 sandbox-manager-8202; do
            if pm2 list 2>/dev/null | grep -q "$legacy"; then
                echo "Retiring legacy pm2 process: $legacy"
                pm2 delete "$legacy" 2>/dev/null || true
            fi
        done
        # ecosystem.config.js runs the prebuilt ./sandbox-manager via sudo as a
        # single fork instance. startOrReload starts it (first deploy) or
        # gracefully reloads in place (subsequent). NODE_ENV picks .env.
        NODE_ENV=production pm2 startOrReload ecosystem.config.js --env production
        pm2 save --force

        echo "Waiting for health on :$PORT..."
        for i in $(seq 1 90); do
            curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 \
                && { echo "✅ healthy on :$PORT (after ${i}s)"; break; }
            [ "$i" -eq 90 ] && { echo "❌ failed to become healthy"; pm2 logs sandbox-manager --lines 40 --nostream; exit 1; }
            sleep 1
        done

        # Must run as root — it talks to containerd.sock, losetup, kata-runtime,
        # ip netns, firecracker. A non-root process fails every VM create.
        PID=$(pm2 pid sandbox-manager 2>/dev/null | tr -d '[:space:]')
        UID_=$([ -n "$PID" ] && awk '/^Uid:/{print $2}' /proc/$PID/status 2>/dev/null || echo "?")
        [ "$UID_" = "0" ] || { echo "❌ sandbox-manager not running as root (uid=$UID_) — check sudoers + ecosystem.config.js"; exit 1; }
        echo "✅ running as root (pid=$PID)"

        # Non-failing template gate: healthy but empty registry → every create 400s.
        TPL=$(curl -sf "http://127.0.0.1:$PORT/templates" || echo '[]')
        [ "$TPL" = "[]" ] && echo "⚠️  templates registry empty" || echo "✅ templates: $TPL"

        echo "Cleaning old releases (keep $KEEP)..."
        cd "$DEPLOY_PATH/releases" && ls -t | tail -n +$((KEEP + 1)) | xargs -r rm -rf
        echo "Done! Deployed: $RELEASE"
EOF
    log "Deployment complete!"
}

rollback() {
    log "Rolling back..."
    ssh "$SERVER" "DEPLOY_PATH='$DEPLOY_PATH' TARGET='${2:-}' bash -s" <<EOF
        $(declare -f rollback_release)
        rollback_release "$DEPLOY_PATH" "$RESTART_CMD" "\${TARGET}"
        for i in \$(seq 1 30); do
            curl -sf http://127.0.0.1:$PORT/health >/dev/null 2>&1 && { echo "✅ healthy"; exit 0; }
            sleep 1
        done
        echo "❌ rollback health check failed"; pm2 logs sandbox-manager --lines 40 --nostream; exit 1
EOF
    log "Rollback complete!"
}

setup() {
    log "Scaffolding $SERVER..."
    ssh "$SERVER" "DEPLOY_PATH='$DEPLOY_PATH' bash -s" <<'EOF'
        set -e
        mkdir -p "$DEPLOY_PATH/releases" "$DEPLOY_PATH/shared" /var/log/todoforai
        if ! command -v pm2 >/dev/null 2>&1; then
            echo "Installing Node.js + PM2..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y nodejs
            npm install -g pm2
            pm2 startup systemd -u root --hp /root
        fi
        if [ ! -f "$DEPLOY_PATH/shared/.env" ]; then
            cat > "$DEPLOY_PATH/shared/.env" <<'ENVEOF'
BIND_ADDR=0.0.0.0:8200
DATA_DIR=/data
USER_HOMES_DIR=/data/user-homes
CONTAINERD_NAMESPACE=sandbox
SANDBOX_SNAPSHOTTER=devmapper
SANDBOX_ROOTFS_IMAGE=docker.io/library/sandbox-rootfs:dev
DRAGONFLY_URL=redis://CHANGE_ME
BACKEND_URL=https://api.todofor.ai
BACKEND_ADMIN_API_KEY=CHANGE_ME
NOISE_BACKEND_HOST=CHANGE_ME
NOISE_BACKEND_PORT=CHANGE_ME
BRIDGE_PORT=CHANGE_ME
ENVEOF
            echo "Created default shared/.env — edit it before deploying."
        fi
        echo "Done. Provision the host stack with scripts/spike-kata-fc.sh, then ./deploy.sh"
EOF
    log "Server setup complete!"
}

status()   { pm2_status 'sandbox-manager' "$DEPLOY_PATH"; }
logs()     { pm2_app_logs 'sandbox-manager'; }
releases() { list_releases "$DEPLOY_PATH"; }

case "${1:-deploy}" in
    deploy)    deploy ;;
    rollback)  rollback "$@" ;;
    status)    status ;;
    logs)      logs ;;
    releases)  releases ;;
    setup)     setup ;;
    preflight) preflight ;;
    *)         echo "Usage: $0 {deploy|rollback|status|logs|releases|setup|preflight}" ;;
esac
