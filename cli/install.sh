#!/bin/sh
# sandbox CLI installer.
#
#   curl -fsSL https://sandbox.todofor.ai/cli/install.sh | sh
#   curl -fsSL https://sandbox.todofor.ai/cli/install.sh | sh -s -- --tag v0.1.0
#
# Env overrides: SANDBOX_PREFIX, SANDBOX_TAG.

set -eu

REPO="todoforai/sandbox-manager"
PREFIX="${SANDBOX_PREFIX:-$HOME/.todoforai/bin}"
TAG="${SANDBOX_TAG:-}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m::\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
sandbox CLI installer.

  curl -fsSL https://sandbox.todofor.ai/cli/install.sh | sh
  curl -fsSL https://sandbox.todofor.ai/cli/install.sh | sh -s -- --tag v0.1.0

Options:
  --prefix DIR      install dir (default: $HOME/.todoforai/bin)
  --tag TAG         specific release tag (default: latest)
EOF
}

need_val() { [ -n "${2:-}" ] || die "$1 requires a value"; }

# ── parse args ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)  need_val "$1" "${2:-}"; PREFIX=$2; shift 2 ;;
        --tag)     need_val "$1" "${2:-}"; TAG=$2;    shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# ── detect OS / arch ────────────────────────────────────────────────────────
uname_s=$(uname -s)
uname_m=$(uname -m)
case "$uname_s" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *)      die "unsupported OS: $uname_s (Windows: download sandbox-windows-x86_64.exe from https://github.com/$REPO/releases/latest)" ;;
esac
case "$uname_m" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported arch: $uname_m" ;;
esac
asset="sandbox-${os}-${arch}"

# ── fetch tool ──────────────────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL "$1" -o "$2"; }
    fetch_text() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q "$1" -O "$2"; }
    fetch_text() { wget -qO- "$1"; }
else
    die "need curl or wget"
fi

# ── resolve release tag (default: latest) ──────────────────────────────────
if [ -z "$TAG" ]; then
    TAG=$(fetch_text "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    [ -z "$TAG" ] && die "could not determine latest release (see https://github.com/$REPO/releases)"
fi
url="https://github.com/$REPO/releases/download/$TAG/$asset"
sha_url="${url}.sha256"

# ── download + verify ───────────────────────────────────────────────────────
info "downloading $asset $TAG"
mkdir -p "$PREFIX"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch "$url"     "$tmp/sandbox"     || die "download failed: $url"
fetch "$sha_url" "$tmp/sandbox.sha" || die "checksum fetch failed: $sha_url"

expected=$(awk '{print $1}' "$tmp/sandbox.sha")
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/sandbox" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$tmp/sandbox" | awk '{print $1}')
else
    die "need sha256sum or shasum"
fi
[ "$expected" = "$actual" ] || die "sha256 mismatch: expected $expected, got $actual"

size=$(wc -c <"$tmp/sandbox" | tr -d ' ')
human=$(awk -v b="$size" 'BEGIN{ s="BKMGT"; for(i=1; b>=1024 && i<5; i++) b/=1024; printf (i==1?"%d %s":"%.1f %siB"), b, substr(s,i,1) }')
ok "downloaded $asset $TAG ($human)"

chmod +x "$tmp/sandbox"
mv "$tmp/sandbox" "$PREFIX/sandbox"

# ── PATH setup ──────────────────────────────────────────────────────────────
# 1) prefix already on PATH → done
# 2) ~/.local/bin on PATH → symlink there (no rc mutation)
# 3) fallback → append to active shell's rc file
CMD="$PREFIX/sandbox"
WHERE="$PREFIX/sandbox"
HINT=""
case ":$PATH:" in
    *":$PREFIX:"*)
        CMD=sandbox
        ;;
    *)
        case ":$PATH:" in
            *":$HOME/.local/bin:"*)
                mkdir -p "$HOME/.local/bin"
                ln -sf "$PREFIX/sandbox" "$HOME/.local/bin/sandbox"
                CMD=sandbox
                WHERE="$WHERE, linked into ~/.local/bin"
                ;;
            *)
                line="export PATH=\"$PREFIX:\$PATH\""
                case "${SHELL##*/}" in
                    zsh)  rc="$HOME/.zshrc" ;;
                    bash) rc="$HOME/.bashrc" ;;
                    *)    rc="$HOME/.profile" ;;
                esac
                if ! grep -qsF "$line" "$rc" 2>/dev/null; then
                    [ -s "$rc" ] && [ -n "$(tail -c1 "$rc" 2>/dev/null)" ] && printf '\n' >>"$rc"
                    printf '\n# added by sandbox CLI installer\n%s\n' "$line" >>"$rc"
                    WHERE="$WHERE, added to PATH in ~/${rc#$HOME/}"
                fi
                CMD=sandbox
                HINT=" (in a new shell, or: $line)"
                ;;
        esac
        ;;
esac
ok "installed $WHERE$HINT"

printf '\n  \033[1mNext:\033[0m\n\n' >&2
printf '      \033[1;36m$\033[0m \033[1;32m%s login\033[0m\n' "$CMD" >&2
printf '      \033[1;36m$\033[0m \033[1;32m%s list\033[0m\n\n' "$CMD" >&2
