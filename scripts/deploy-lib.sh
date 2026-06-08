#!/bin/bash
# Shared deploy helpers. Source from deploy.sh.
# Requires: $SERVER set by caller for the ssh-based helpers.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# Warn (interactively) if prod is behind main. Skipped in CI — the push to
# `prod` already pinned the ref we deploy, so there is nothing to confirm.
check_prod_status() {
    [ -n "${CI:-}" ] && return 0
    git fetch origin --quiet 2>/dev/null
    local main prod
    main=$(git rev-parse origin/main 2>/dev/null)
    prod=$(git rev-parse origin/prod 2>/dev/null)
    [ "$main" = "$prod" ] && { log "prod up to date with main"; return 0; }
    local ahead
    ahead=$(git rev-list --count origin/prod..origin/main 2>/dev/null)
    [ "${ahead:-0}" -gt 0 ] || return 0
    warn "prod is $ahead commit(s) behind main!"
    git log --oneline origin/prod..origin/main | head -5
    read -p "Continue deploying from prod? [y/N] " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
}

# List releases on $SERVER, marking the current one with *.
# Usage: list_releases <deploy_path>
list_releases() {
    ssh "$SERVER" DEPLOY="$1" 'bash -s' <<'EOF'
        cd "$DEPLOY/releases" || exit 0
        CUR=$(readlink "$DEPLOY/current" | xargs basename 2>/dev/null || echo "")
        for d in $(ls -t); do
            M=" "; [ "$d" = "$CUR" ] && M="*"
            C=$(cd "$d" && git log -1 --format="%h %s" 2>/dev/null || echo "no git")
            echo "$M $d | $C"
        done
EOF
}

# Show pm2 status for this app + release dir + current symlink.
# Usage: pm2_status <pm2_name_or_glob> <deploy_path>
pm2_status() {
    ssh "$SERVER" "pm2 status '$1' 2>/dev/null || pm2 status; echo; ls -la $2/releases/ 2>/dev/null; echo 'Current:'; readlink $2/current 2>/dev/null || echo 'none'"
}

# Tail pm2 logs for this app.
# Usage: pm2_app_logs <pm2_name_or_glob> [lines]
pm2_app_logs() {
    ssh "$SERVER" "pm2 logs '$1' --lines ${2:-100} --nostream"
}

# Roll back a Capistrano-style release. Runs entirely on the remote server.
# Resolves PREVIOUS (or honours TARGET if non-empty), flips the `current`
# symlink, then runs the supplied restart command.
#
# Inject into an SSH heredoc via $(declare -f rollback_release):
#   rollback_release <deploy_path> <restart_cmd> [target]
rollback_release() {
    local deploy_path="$1" restart_cmd="$2" target="${3:-}"
    cd "$deploy_path/releases" || { echo "no releases dir"; exit 1; }

    local CURRENT PREVIOUS
    CURRENT=$(readlink "$deploy_path/current" | xargs basename)
    if [ -n "$target" ]; then
        [ -d "$target" ] || { echo "Release $target not found! Available:"; ls -t; exit 1; }
        PREVIOUS="$target"
    else
        PREVIOUS=$(ls -t | grep -v "^$CURRENT$" | head -1)
    fi
    [ -z "$PREVIOUS" ] && { echo "No previous release found!"; exit 1; }

    echo "Current: $CURRENT"
    echo "Rolling back to: $PREVIOUS"
    ln -sfn "$deploy_path/releases/$PREVIOUS" "$deploy_path/current"

    cd "$deploy_path/current"
    eval "$restart_cmd"
    echo "Rolled back to $PREVIOUS"
}
