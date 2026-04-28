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
#   ./deploy.sh setup        First-time server setup (installs PM2, .env)

set -e

source "$(dirname "$0")/../scripts/deploy-lib.sh"

SERVER="${SERVER:-root@sandbox.todofor.ai}"
DEPLOY_PATH="/var/www/todoforai/apps/sandbox-manager"
REPO="git@github.com:todoforai/sandbox-manager.git"
BRANCH="prod"
KEEP_RELEASES=5

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

        echo "Linking shared dir for ecosystem.config.js to read..."
        ln -sfn $DEPLOY_PATH/shared $DEPLOY_PATH/releases/$RELEASE/shared

        echo "Updating current symlink..."
        ln -sfn $DEPLOY_PATH/releases/$RELEASE $DEPLOY_PATH/current

        echo "Rolling deploy..."
        cd $DEPLOY_PATH/current

        # One-shot migration: retire systemd-managed instances (sandbox-manager@,
        # tfa-sandbox-manager@) before PM2 takes over. Safe to leave in place —
        # does nothing once the units are gone.
        for unit in sandbox-manager@.service tfa-sandbox-manager@.service; do
            if [ -f /etc/systemd/system/\$unit ]; then
                echo "Migrating off systemd: \$unit..."
                systemctl disable --now "\${unit%.service}9000" "\${unit%.service}9002" 2>/dev/null || true
                rm -f /etc/systemd/system/\$unit
            fi
        done
        systemctl daemon-reload

        # Determine which port is currently active under PM2
        OLD_PORT=""
        NEW_PORT=""
        if pm2 list 2>/dev/null | grep -q "sandbox-manager-9000"; then
            OLD_PORT=9000; NEW_PORT=9002
        elif pm2 list 2>/dev/null | grep -q "sandbox-manager-9002"; then
            OLD_PORT=9002; NEW_PORT=9000
        else
            NEW_PORT=9000
        fi

        NGINX_CONF=/etc/nginx/sites-available/vm.todofor.ai
        STREAM_CONF=/etc/nginx/streams-available/sandbox-noise-stream.conf

        echo "Starting new instance on port \$NEW_PORT..."
        DEPLOY_PORT=\$NEW_PORT pm2 start ecosystem.config.js --env production
        pm2 save --force

        # Wait for new instance to be healthy before touching nginx
        echo "Waiting for new instance..."
        for i in \$(seq 1 30); do
            if curl -sf http://127.0.0.1:\$NEW_PORT/health >/dev/null 2>&1; then
                echo "✅ New instance healthy on port \$NEW_PORT"
                break
            fi
            [ \$i -eq 30 ] && { echo "❌ New instance failed to start!"; pm2 logs sandbox-manager-\$NEW_PORT --lines 40 --nostream; exit 1; }
            sleep 1
        done

        # Sync nginx site + stream confs from repo
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

        # Drain old instance (if any) — nginx already switched, safe to stop
        if [ -n "\$OLD_PORT" ]; then
            echo "Draining old instance on port \$OLD_PORT..."
            pm2 stop sandbox-manager-\$OLD_PORT
            pm2 delete sandbox-manager-\$OLD_PORT 2>/dev/null || true
            pm2 save --force
            echo "✅ Old instance stopped"
        fi

        sleep 1
        if curl -sf http://127.0.0.1:\$NEW_PORT/health >/dev/null 2>&1; then
            echo "✅ sandbox-manager healthy on port \$NEW_PORT!"
        else
            echo "❌ Final health check failed!"
            pm2 logs sandbox-manager-\$NEW_PORT --lines 40 --nostream
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

        # Determine which port is currently live
        LIVE_PORT=""
        pm2 list 2>/dev/null | grep -q "sandbox-manager-9000" && LIVE_PORT=9000
        pm2 list 2>/dev/null | grep -q "sandbox-manager-9002" && LIVE_PORT=9002
        ROLLBACK_PORT=9000
        [ "$LIVE_PORT" = "9000" ] && ROLLBACK_PORT=9002

        # Start rollback on the inactive port first
        cd $DEPLOY_PATH/current
        DEPLOY_PORT=$ROLLBACK_PORT pm2 start ecosystem.config.js --env production
        pm2 save --force

        # Wait healthy before touching nginx
        NGINX_CONF=/etc/nginx/sites-available/vm.todofor.ai
        STREAM_CONF=/etc/nginx/streams-available/sandbox-noise-stream.conf
        for i in $(seq 1 15); do
            curl -sf http://127.0.0.1:$ROLLBACK_PORT/health >/dev/null 2>&1 && echo "✅ Rollback instance healthy" && break
            [ $i -eq 15 ] && { echo "❌ Rollback health check failed!"; pm2 logs sandbox-manager-$ROLLBACK_PORT --lines 40 --nostream; pm2 delete sandbox-manager-$ROLLBACK_PORT 2>/dev/null; exit 1; }
            sleep 2
        done

        ROLLBACK_NOISE=$((ROLLBACK_PORT + 10))
        sed -i "s|server 127.0.0.1:9000[^;]*;|server 127.0.0.1:9000 down;|g" $NGINX_CONF
        sed -i "s|server 127.0.0.1:9002[^;]*;|server 127.0.0.1:9002 down;|g" $NGINX_CONF
        sed -i "s|server 127.0.0.1:${ROLLBACK_PORT} down;|server 127.0.0.1:${ROLLBACK_PORT} max_fails=2 fail_timeout=5s;|" $NGINX_CONF

        sed -i "s|server 127.0.0.1:9010[^;]*;|server 127.0.0.1:9010 down;|g" $STREAM_CONF
        sed -i "s|server 127.0.0.1:9012[^;]*;|server 127.0.0.1:9012 down;|g" $STREAM_CONF
        sed -i "s|server 127.0.0.1:${ROLLBACK_NOISE} down;|server 127.0.0.1:${ROLLBACK_NOISE} max_fails=2 fail_timeout=5s;|" $STREAM_CONF

        nginx -t && systemctl reload nginx

        if [ -n "$LIVE_PORT" ]; then
            pm2 delete sandbox-manager-$LIVE_PORT 2>/dev/null || true
            pm2 save --force
        fi

        echo "Rolled back to $PREVIOUS"
EOF

    log "Rollback complete!"
}

status() { pm2_status 'sandbox-manager-*' "$DEPLOY_PATH"; }
logs()   { pm2_app_logs 'sandbox-manager-*'; }

setup() {
    log "Setting up server..."
    ssh $SERVER << 'EOF'
        set -e
        mkdir -p /var/www/todoforai/apps/sandbox-manager/{releases,shared}
        mkdir -p /var/log/todoforai
        SHARED=/var/www/todoforai/apps/sandbox-manager/shared

        # Install Node + PM2 if missing (sandbox host has neither by default)
        if ! command -v pm2 >/dev/null 2>&1; then
            echo "Installing Node.js + PM2..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y nodejs
            npm install -g pm2
            pm2 startup systemd -u root --hp /root
        fi

        if [ ! -f $SHARED/.env ]; then
            cat > $SHARED/.env << 'ENVEOF'
RUST_LOG=info
TEMPLATES_DIR=/data/templates
OVERLAYS_DIR=/data/overlays
BRIDGE_NAME=br-sandbox
NETWORK_SUBNET=10.0.0.0/16
DEFAULT_VM_SIZE=medium
BACKEND_URL=https://api.todofor.ai
BACKEND_ADMIN_API_KEY=CHANGE_ME
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
