#!/usr/bin/env bash
# Verify the preinstallCloud set against a real (logged-out) VM before rebuilding
# the rootfs. For every catalog tool tagged preinstallCloud:
#   1. install it the way the image build would (bun / pip / cloudInstallCmd)
#   2. confirm the binary resolves
#   3. run its statusCmd with no credentials and check it FAILS (non-zero, no
#      output) within the timeout — a tool whose probe reports "logged in" while
#      logged out, or hangs on a TTY prompt, breaks the agent's tiered tool view
#      (it would render as connected / in full on every user's VM).
#
# Usage: verify-preinstall.sh [tool_catalog.json]   (run as root on a throwaway VM;
#        HOME is redirected to an empty dir so real creds never leak in)
set -uo pipefail
CATALOG="${1:-$(dirname "$0")/../assets/tool_catalog.json}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
export HOME=$(mktemp -d /tmp/verify-home.XXXX) CI=1 TERM=dumb
export BUN_INSTALL=/usr/local PATH="/usr/local/bin:/usr/local/install/global/node_modules/.bin:$PATH"

jqc() { jq -r "$@" "$CATALOG"; }
keys=$(jqc 'to_entries[] | select(.value.preinstallCloud == true) | .key')

if [ "$SKIP_INSTALL" != 1 ]; then
  echo ">> install"
  bun_pkgs=$(jqc '[to_entries[] | select(.value.preinstallCloud == true and (.value.installer == "npm" or .value.installer == "bun")) | .value.pkg] | join(" ")')
  pip_pkgs=$(jqc '[to_entries[] | select(.value.preinstallCloud == true and .value.installer == "pip") | (.value.packages // [.value.pkg])[]] | join(" ")')
  apt_pkgs=$(jqc '[to_entries[] | select(.value.preinstallCloud == true) | .value.cloudAptPackages[]?] | unique | join(" ")')
  [ -n "$apt_pkgs" ] && { apt-get update -qq && apt-get install -y -qq --no-install-recommends $apt_pkgs; }
  jqc 'to_entries[] | select(.value.preinstallCloud == true and (.value.cloudInstallCmd // "") != "") | "\(.key)\t\(.value.cloudInstallCmd)"' \
    | while IFS=$'\t' read -r k cmd; do echo "   [$k] $cmd"; bash -euo pipefail -c "$cmd" || echo "   INSTALL FAILED: $k"; done
  [ -n "$bun_pkgs" ] && bun add -g $bun_pkgs
  [ -n "$pip_pkgs" ] && uv pip install --system --break-system-packages $pip_pkgs
fi

echo; echo ">> probe (logged out, HOME=$HOME)"
printf "%-20s %-9s %-7s %-5s %s\n" TOOL PRESENT STATUS EXIT NOTE
fail=0
for k in $keys; do
  bin=$(jqc --arg k "$k" '.[$k].binName // .[$k].pkg | split("/")[-1]')
  # python libs (pymupdf) have a verify cmd instead of a binary
  present=$(command -v "$k" >/dev/null || command -v "$bin" >/dev/null && echo yes || echo NO)
  verify=$(jqc --arg k "$k" '.[$k].cloudVerifyCmd // ""')
  [ "$present" = NO ] && [ -n "$verify" ] && bash -c "$verify" >/dev/null 2>&1 && present=lib
  status=$(jqc --arg k "$k" '.[$k].statusCmd // ""')
  if [ -z "$status" ]; then
    printf "%-20s %-9s %-7s %-5s %s\n" "$k" "$present" - - "no auth"
    [ "$present" = NO ] && fail=1; continue
  fi
  out=$(timeout 15 bash -c "$status" </dev/null 2>/dev/null); rc=$?
  note=""; verdict=ok
  [ $rc -eq 124 ] && { verdict=HANG; note="probe blocked >15s (TTY prompt?)"; }
  [ $rc -eq 0 ] && { verdict=BAD; note="exit 0 while logged out → would render as connected: '${out:0:60}'"; }
  [ $rc -ne 0 ] && [ -n "$out" ] && { verdict=noisy; note="non-zero but prints: '${out:0:60}'"; }
  [ "$present" = NO ] && { verdict=MISSING; }
  [[ $verdict =~ ^(ok|noisy)$ ]] || fail=1
  printf "%-20s %-9s %-7s %-5s %s\n" "$k" "$present" "$verdict" "$rc" "$note"
done
echo; [ $fail = 0 ] && echo "ALL OK" || { echo "FAILURES above — fix statusCmd/cloudInstallCmd in tool_catalog.json before rebuilding the image"; exit 1; }
