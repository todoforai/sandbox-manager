#!/bin/bash
# Shared deploy helpers. Source from app deploy.sh scripts.
# Requires: $SERVER set by caller for list_releases.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $1"; }
error() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# Warn if prod is behind main (skipped in CI).
check_prod_status() {
    [ -n "${CI:-}" ] && return 0
    git fetch origin --quiet 2>/dev/null
    local main=$(git rev-parse origin/main 2>/dev/null)
    local prod=$(git rev-parse origin/prod 2>/dev/null)
    [ "$main" = "$prod" ] && { log "prod up to date with main"; return 0; }
    local ahead=$(git rev-list --count origin/prod..origin/main 2>/dev/null)
    [ "${ahead:-0}" -gt 0 ] || return 0
    warn "prod is $ahead commit(s) behind main!"
    git log --oneline origin/prod..origin/main | head -5
    read -p "Continue deploying from prod? [y/N] " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
}

# List releases on $SERVER, marking current with *.
# Usage: list_releases <deploy_path> [exclude_regex]
list_releases() {
    ssh "$SERVER" DEPLOY="$1" EXCLUDE="${2:-}" 'bash -s' <<'EOF'
        cd "$DEPLOY/releases"
        CUR=$(readlink "$DEPLOY/current" | xargs basename 2>/dev/null || echo "")
        for d in $(ls -t ${EXCLUDE:+| grep -vE "$EXCLUDE"}); do
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

# Clone or update a git repo at <path>. Intended for use inside server-side heredocs.
# Usage: sync_repo <path> <git-url> [branch]   (branch defaults to main)
sync_repo() {
    local path="$1" url="$2" branch="${3:-main}"
    if [ -d "$path/.git" ]; then
        cd "$path" && git fetch origin && git reset --hard "origin/$branch"
    else
        git clone --depth 1 --branch "$branch" "$url" "$path"
    fi
}

# Roll back a Capistrano-style release. Runs entirely on the remote server.
# Resolves PREVIOUS (or honours TARGET if non-empty), flips the `current` symlink,
# then runs the supplied restart command. Exits non-zero on any failure.
#
# Usage (inject into an SSH heredoc via $(declare -f rollback_release)):
#   rollback_release <deploy_path> <exclude_regex> <restart_cmd> [target]
#
#   deploy_path    e.g. /var/www/todoforai/apps/frontend
#   exclude_regex  regex of dirs in releases/ to skip (or "" for none)
#   restart_cmd    shell command to run after symlink flip (cwd = $deploy_path/current)
#   target         optional explicit release name to roll back to
rollback_release() {
    local deploy_path="$1" exclude="$2" restart_cmd="$3" target="${4:-}"
    cd "$deploy_path/releases"

    local CURRENT PREVIOUS
    CURRENT=$(readlink "$deploy_path/current" | xargs basename)

    if [ -n "$target" ]; then
        [ -d "$target" ] || { echo "Release $target not found! Available:"; ls -t; exit 1; }
        PREVIOUS="$target"
    elif [ -n "$exclude" ]; then
        PREVIOUS=$(ls -t | grep -vE "^($CURRENT|$exclude)$" | head -1)
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
