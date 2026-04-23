#!/bin/bash
# sandbox-manager deployment script
#
# DEPLOY: Push main to prod — GitHub Actions runs this script automatically:
#   git push origin main:prod
#
# Manual commands:
#   ./deploy.sh              Deploy to production
#   ./deploy.sh rollback     Rollback to previous release
#   ./deploy.sh status       Check status
#   ./deploy.sh logs         View logs
#   ./deploy.sh setup        First-time server setup

set -e

SERVER="${SERVER:-root@sandbox.todofor.ai}"
DEPLOY_PATH="/var/www/todoforai/apps/sandbox-manager"
REPO="git@github.com:todoforai/sandbox-manager.git"
BRANCH="prod"
KEEP_RELEASES=5

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }

check_prod_status() {
    [ -n "${CI:-}" ] && return 0
    git fetch origin --quiet 2>/dev/null
    local main_hash=$(git rev-parse origin/main 2>/dev/null)
    local prod_hash=$(git rev-parse origin/prod 2>/dev/null)
    if [ "$main_hash" != "$prod_hash" ]; then
        local ahead=$(git rev-list --count origin/prod..origin/main 2>/dev/null)
        if [ "$ahead" -gt 0 ]; then
            warn "prod is $ahead commit(s) behind main!"
            git log --oneline origin/prod..origin/main | head -5
            read -p "Continue deploying from prod? [y/N] " -n 1 -r; echo
            [[ $REPLY =~ ^[Yy]$ ]] || exit 0
        fi
    else
        log "prod is up to date with main"
    fi
}

deploy() {
    check_prod_status
    log "Starting sandbox-manager deployment to $SERVER..."

    RELEASE=$(date +%Y%m%d%H%M%S)

    ssh $SERVER << EOF
        set -e

        mkdir -p $DEPLOY_PATH/releases $DEPLOY_PATH/shared

        echo "Creating release $RELEASE..."
        git clone --depth 1 --branch $BRANCH $REPO $DEPLOY_PATH/releases/$RELEASE

        echo "Building sandbox-manager (cargo release)..."
        cd $DEPLOY_PATH/releases/$RELEASE
        cargo build --release --locked
        cp target/release/sandbox-manager ./sandbox-manager

        echo "Linking shared env..."
        ln -sf $DEPLOY_PATH/shared/.env $DEPLOY_PATH/releases/$RELEASE/.env

        echo "Updating current symlink..."
        ln -sfn $DEPLOY_PATH/releases/$RELEASE $DEPLOY_PATH/current

        echo "Rolling deploy..."

        # Determine active REST port (9000 or 9002); pair: Noise = REST + 10
        OLD_PORT=""
        NEW_PORT=9000
        if systemctl is-active --quiet tfa-sandbox-manager@9000; then
            OLD_PORT=9000; NEW_PORT=9002
        elif systemctl is-active --quiet tfa-sandbox-manager@9002; then
            OLD_PORT=9002; NEW_PORT=9000
        fi

        NGINX_CONF=/etc/nginx/sites-available/vm.todofor.ai
        STREAM_CONF=/etc/nginx/streams-available/sandbox-noise-stream.conf

        # One-shot migration: retire the legacy unit name (sandbox-manager@ → tfa-sandbox-manager@).
        # Safe to leave in place — does nothing once the old unit is gone.
        if [ -f /etc/systemd/system/sandbox-manager@.service ]; then
            echo "Migrating legacy unit name → tfa-sandbox-manager@..."
            systemctl disable --now sandbox-manager@9000 sandbox-manager@9002 2>/dev/null || true
            rm -f /etc/systemd/system/sandbox-manager@.service
            systemctl daemon-reload
            OLD_PORT=""; NEW_PORT=9000
        fi

        # Install/refresh systemd unit from repo
        cp $DEPLOY_PATH/current/systemd/tfa-sandbox-manager@.service /etc/systemd/system/tfa-sandbox-manager@.service
        systemctl daemon-reload

        echo "Starting new instance on port \$NEW_PORT..."
        systemctl enable --now tfa-sandbox-manager@\$NEW_PORT

        echo "Waiting for new instance..."
        for i in \$(seq 1 30); do
            if curl -sf http://127.0.0.1:\$NEW_PORT/health >/dev/null 2>&1; then
                echo "✅ New instance healthy on port \$NEW_PORT"
                break
            fi
            [ \$i -eq 30 ] && { echo "❌ New instance failed to start!"; journalctl -u tfa-sandbox-manager@\$NEW_PORT -n 40 --no-pager; exit 1; }
            sleep 1
        done

        # Sync nginx site + stream confs
        cp $DEPLOY_PATH/current/nginx/vm.todofor.ai.conf \$NGINX_CONF
        ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/vm.todofor.ai

        mkdir -p /etc/nginx/streams-available /etc/nginx/streams-enabled
        cp $DEPLOY_PATH/current/nginx/noise-stream.conf \$STREAM_CONF
        ln -sf \$STREAM_CONF /etc/nginx/streams-enabled/sandbox-noise-stream.conf
        if ! grep -q 'streams-enabled' /etc/nginx/nginx.conf; then
            echo 'stream { include /etc/nginx/streams-enabled/*.conf; }' >> /etc/nginx/nginx.conf
        fi

        # Flip upstreams: mark all down, bring the new one up
        sed -i "s|server 127.0.0.1:9000[^;]*;|server 127.0.0.1:9000 down;|g" \$NGINX_CONF
        sed -i "s|server 127.0.0.1:9002[^;]*;|server 127.0.0.1:9002 down;|g" \$NGINX_CONF
        sed -i "s|server 127.0.0.1:\$NEW_PORT down;|server 127.0.0.1:\$NEW_PORT max_fails=2 fail_timeout=5s;|" \$NGINX_CONF

        NEW_NOISE=\$((NEW_PORT + 10))
        sed -i "s|server 127.0.0.1:9010[^;]*;|server 127.0.0.1:9010 down;|g" \$STREAM_CONF
        sed -i "s|server 127.0.0.1:9012[^;]*;|server 127.0.0.1:9012 down;|g" \$STREAM_CONF
        sed -i "s|server 127.0.0.1:\$NEW_NOISE down;|server 127.0.0.1:\$NEW_NOISE max_fails=2 fail_timeout=5s;|" \$STREAM_CONF

        nginx -t && systemctl reload nginx

        if [ -n "\$OLD_PORT" ]; then
            echo "Draining old instance on port \$OLD_PORT..."
            systemctl disable --now tfa-sandbox-manager@\$OLD_PORT || true
            echo "✅ Old instance stopped"
        fi

        sleep 1
        if curl -sf http://127.0.0.1:\$NEW_PORT/health >/dev/null 2>&1; then
            echo "✅ sandbox-manager healthy on port \$NEW_PORT!"
        else
            echo "❌ Final health check failed!"
            journalctl -u tfa-sandbox-manager@\$NEW_PORT -n 40 --no-pager
            exit 1
        fi

        echo "Cleaning old releases..."
        cd $DEPLOY_PATH/releases && ls -t | tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -rf

        echo "Done! Deployed: $RELEASE"
EOF

    log "Deployment complete!"
}

rollback() {
    log "Rolling back..."

    ssh $SERVER << 'EOF'
        set -e
        DEPLOY_PATH="/var/www/todoforai/apps/sandbox-manager"
        cd $DEPLOY_PATH/releases

        CURRENT=$(readlink $DEPLOY_PATH/current | xargs basename)
        PREVIOUS=$(ls -t | grep -v "^$CURRENT$" | head -1)
        [ -z "$PREVIOUS" ] && { echo "No previous release found!"; exit 1; }

        echo "Current: $CURRENT → Rolling back to: $PREVIOUS"
        ln -sfn $DEPLOY_PATH/releases/$PREVIOUS $DEPLOY_PATH/current

        LIVE_PORT=""
        systemctl is-active --quiet tfa-sandbox-manager@9000 && LIVE_PORT=9000
        systemctl is-active --quiet tfa-sandbox-manager@9002 && LIVE_PORT=9002
        ROLLBACK_PORT=9000
        [ "$LIVE_PORT" = "9000" ] && ROLLBACK_PORT=9002

        systemctl enable --now tfa-sandbox-manager@$ROLLBACK_PORT

        for i in $(seq 1 15); do
            curl -sf http://127.0.0.1:$ROLLBACK_PORT/health >/dev/null 2>&1 && break
            [ $i -eq 15 ] && { echo "❌ Rollback health check failed!"; journalctl -u tfa-sandbox-manager@$ROLLBACK_PORT -n 40 --no-pager; exit 1; }
            sleep 2
        done

        NGINX_CONF=/etc/nginx/sites-available/vm.todofor.ai
        STREAM_CONF=/etc/nginx/streams-available/sandbox-noise-stream.conf
        ROLLBACK_NOISE=$((ROLLBACK_PORT + 10))

        sed -i "s|server 127.0.0.1:9000[^;]*;|server 127.0.0.1:9000 down;|g" $NGINX_CONF
        sed -i "s|server 127.0.0.1:9002[^;]*;|server 127.0.0.1:9002 down;|g" $NGINX_CONF
        sed -i "s|server 127.0.0.1:${ROLLBACK_PORT} down;|server 127.0.0.1:${ROLLBACK_PORT} max_fails=2 fail_timeout=5s;|" $NGINX_CONF

        sed -i "s|server 127.0.0.1:9010[^;]*;|server 127.0.0.1:9010 down;|g" $STREAM_CONF
        sed -i "s|server 127.0.0.1:9012[^;]*;|server 127.0.0.1:9012 down;|g" $STREAM_CONF
        sed -i "s|server 127.0.0.1:${ROLLBACK_NOISE} down;|server 127.0.0.1:${ROLLBACK_NOISE} max_fails=2 fail_timeout=5s;|" $STREAM_CONF

        nginx -t && systemctl reload nginx

        [ -n "$LIVE_PORT" ] && systemctl disable --now tfa-sandbox-manager@$LIVE_PORT || true
        echo "Rolled back to $PREVIOUS"
EOF

    log "Rollback complete!"
}

status() {
    ssh $SERVER "systemctl status 'tfa-sandbox-manager@*' --no-pager || true; echo ''; ls -la /var/www/todoforai/apps/sandbox-manager/releases/; echo ''; echo 'Current:'; readlink /var/www/todoforai/apps/sandbox-manager/current"
}

logs() {
    ssh $SERVER "journalctl -u 'tfa-sandbox-manager@*' -n 200 --no-pager"
}

setup() {
    log "Setting up server..."
    ssh $SERVER << 'EOF'
        set -e
        mkdir -p /var/www/todoforai/apps/sandbox-manager/{releases,shared}
        SHARED=/var/www/todoforai/apps/sandbox-manager/shared

        if [ ! -f $SHARED/.env ]; then
            cat > $SHARED/.env << 'ENVEOF'
RUST_LOG=info
TEMPLATES_DIR=/data/templates
OVERLAYS_DIR=/data/overlays
BRIDGE_NAME=br-sandbox
NETWORK_SUBNET=10.0.0.0/16
ENABLE_KVM=true
DEFAULT_VM_SIZE=medium
ENVEOF
            echo "Created default .env — edit $SHARED/.env"
        fi

        if [ ! -f $SHARED/noise.env ]; then
            echo "NOISE_LOCAL_PRIVATE_KEY=CHANGE_ME_32_BYTE_HEX" > $SHARED/noise.env
            chmod 600 $SHARED/noise.env
            echo "Created noise.env — set NOISE_LOCAL_PRIVATE_KEY in $SHARED/noise.env"
        fi

        echo "Done. Next: obtain TLS cert:"
        echo "  certbot --nginx -d vm.todofor.ai -d sandbox.todofor.ai"
EOF
    log "Server setup complete!"
}

case "${1:-deploy}" in
    deploy)   deploy ;;
    rollback) rollback ;;
    status)   status ;;
    logs)     logs ;;
    setup)    setup ;;
    *)        echo "Usage: $0 {deploy|rollback|status|logs|setup}" ;;
esac
