#!/usr/bin/env bash
# Persistent smoke-test sandbox: one fixed dev user (SMOKE_USER_ID/SMOKE_TOKEN in
# .env.smoke, gitignored) owns one VM + one home.img. Reuse it across runs.
#
#   smoke-vm.sh up                 create (or reuse) the VM, wait for bridge
#   smoke-vm.sh exec <cmd…>        run a command inside (sh -lc when 1 arg)
#   smoke-vm.sh shell              line-REPL over exec
#   smoke-vm.sh status             manager view of the fixture
#   smoke-vm.sh down               delete VM, keep home.img
#   smoke-vm.sh recreate           down + up (= update path onto current rootfs)
#   smoke-vm.sh rebuild            build-oci + import into containerd + recreate
#   smoke-vm.sh reset              down + wipe home.img
#   smoke-vm.sh test [phase…]      versions auth login roundtrip update | all
#   smoke-vm.sh test --only <id>   run one check by id (ids are printed in reports)
#   smoke-vm.sh report             regenerate per-CLI table in docs/smoke-vm.md from .smoke/results.tsv
#
# Report format (one line per check, greppable):
#   PASS <phase>/<id>   <summary>
#   FAIL <phase>/<id>   <reason>
#        cmd: <exact command>      rc: <n>
#        out: <last lines of output>
#        rerun: scripts/smoke-vm.sh exec '<cmd>'
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
REPO=$ROOT/..
CATALOG=$REPO/packages/shared-fbe/src/tool_catalog.json
set -a; . "$ROOT/.env.development"; [ -f "$ROOT/.env.smoke" ] && . "$ROOT/.env.smoke"; set +a
: "${SMOKE_TOKEN:?SMOKE_TOKEN missing — put it in sandbox-manager/.env.smoke (gitignored)}"
: "${SMOKE_USER_ID:?SMOKE_USER_ID missing — put it in sandbox-manager/.env.smoke (gitignored)}"
MGR=${SANDBOX_MANAGER_URL:-http://${BIND_ADDR:-127.0.0.1:8200}}
# The bridge exports TODOFORAI_API_URL into its PTYs (http://<noise host>:<BRIDGE_PORT>
# in dev). Manager exec has no PTY, so mirror it — tfa-* pick the dst_ token
# from credentials.json only when the URL matches the one the bridge minted it for.
VM_API_URL=${SMOKE_API_URL:-http://${NOISE_BACKEND_HOST:-localhost}${BRIDGE_PORT:+:$BRIDGE_PORT}}
STATE_DIR=$ROOT/.smoke; mkdir -p "$STATE_DIR"

api() { curl -sS -H "Authorization: Bearer $SMOKE_TOKEN" -H 'Content-Type: application/json' "$@"; }
die() { echo "ERR: $*" >&2; exit 1; }
live_id() { api "$MGR/sandbox" | jq -r '[.[]|select(.state=="running" or .state=="creating")][0].id // empty'; }
require_id() { ID=$(live_id); [ -n "$ID" ] || die "no live smoke VM (backend idle-reaper stops it after ~1h) — run: $0 up"; }

# vm_exec argv… -> stdout, returns the command's exit code. One arg = shell string.
# Sets RC and OUT (full output) for reporting.
vm_exec() {
  local argv pre
  pre=$(jq -cn --arg u "$VM_API_URL" --arg t "${EXEC_TIMEOUT:-60}" '["timeout",$t,"env","TODOFORAI_API_URL="+$u]')
  if [ $# -eq 1 ]; then argv=$(jq -cn --argjson p "$pre" --arg c "$1" --arg sh "${VM_SHELL:-sh}" '$p+[$sh,"-lc",$c]')
  else argv=$(jq -cn --argjson p "$pre" '$p+$ARGS.positional' --args "$@"); fi
  local r; r=$(api -m "$(( ${EXEC_TIMEOUT:-60} + 10 ))" -X POST "$MGR/sandbox/$ID/exec" -d "{\"argv\":$argv}")
  RC=$(echo "$r" | jq -r '.exit_code // 255')
  OUT=$(echo "$r" | jq -r 'if .error then "EXEC-ERR: "+.error else .output end' | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
  printf '%s\n' "$OUT"
  return "$RC"
}

wait_ready() {
  for _ in $(seq 1 60); do
    st=$(api "$MGR/sandbox/$ID" | jq -r .state)
    [ "$st" = running ] && { vm_exec true >/dev/null 2>&1 && return 0; }
    [ "$st" = error ] && die "sandbox $ID entered error state"
    sleep 2
  done
  die "timeout waiting for $ID"
}

cmd_up() {
  curl -sf "$MGR/health" >/dev/null || die "sandbox-manager not reachable at $MGR"
  curl -sf "$BACKEND_URL/health" >/dev/null || die "backend not reachable at $BACKEND_URL"
  ID=$(live_id)
  if [ -z "$ID" ]; then
    ID=$(api -X POST "$MGR/sandbox" -d '{"template":"ubuntu-base","size":"medium"}' | jq -r '.id // error(.error)')
    echo "created $ID"
  else echo "reusing $ID"; fi
  wait_ready
  echo "ready: $ID  host=$(vm_exec hostname)"
}
cmd_down() { ID=$(live_id); [ -n "$ID" ] || { echo "no live VM"; return; }; api -X DELETE "$MGR/sandbox/$ID" >/dev/null; echo "deleted $ID"; }
cmd_reset() {
  cmd_down
  [ -z "$(api "$MGR/sandbox" | jq -r '.[]|select(.state!="terminated")|.id')" ] || die "a non-terminated sandbox still exists; refusing to wipe home.img"
  local img=$USER_HOMES_DIR/$SMOKE_USER_ID
  [ -e "$img" ] && { sudo rm -rf "$img"; echo "wiped $img"; }
}
cmd_rebuild() {
  (cd "$ROOT" && IMPORT=0 scripts/build-oci.sh) || die "build-oci failed"
  local tar; tar=$(mktemp /tmp/rootfs.XXXX.tar)
  docker save docker.io/library/sandbox-rootfs:dev > "$tar"
  # ctr needs root; refuse to hang on a password prompt when run headless
  sudo -n true 2>/dev/null || { echo "sudo needs a password — run: sudo ctr -n ${CONTAINERD_NAMESPACE:-default} images import $tar && $0 down && $0 up"; exit 2; }
  sudo -n ctr -n "${CONTAINERD_NAMESPACE:-default}" images import "$tar" | tail -1
  rm -f "$tar"
  cmd_down; cmd_up
}
# login <tool>: start the real login on the fixture and print the code/URL; complete it in your browser,
# then `exec '<statusCmd>'` shows the logged-in branch. Nothing is killed afterwards.
cmd_login() {
  local tool=$1 log=/tmp/smoke-login-$1.log; require_id
  VM_SHELL=bash vm_exec "rm -f $log; $(login_launcher "$tool" "$log"); sleep 8; cat $log"
}
cmd_shell() { require_id; while IFS= read -r -e -p "vm> " line; do [ -n "$line" ] && { vm_exec "$line" || echo "[rc=$?]"; }; done; }

# ── check framework ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0; PHASE=""; ONLY=${ONLY:-}
FAILED_IDS=()
RESULTS=$STATE_DIR/results.tsv      # latest per-check outcome: id<TAB>status<TAB>summary
HISTORY=$STATE_DIR/history.log      # one line per test run
record() { printf '%s\t%s\t%s\n' "$PHASE/$1" "$2" "$(tr '\n\t' '  ' <<<"${3:-}" | cut -c1-120)" >> "$RESULTS.new"; }
pass() { PASS=$((PASS+1)); record "$1" PASS "${2:-}"; printf '  \033[32mPASS\033[0m %-28s %s\n' "$PHASE/$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); record "$1" SKIP "${2:-}"; printf '  \033[33mSKIP\033[0m %-28s %s\n' "$PHASE/$1" "${2:-}"; }
fail() { # fail <id> <reason> <cmd>
  FAIL=$((FAIL+1)); FAILED_IDS+=("$PHASE/$1"); record "$1" FAIL "$2"
  printf '  \033[31mFAIL\033[0m %-28s %s\n' "$PHASE/$1" "$2"
  printf '       cmd: %s\n       rc:  %s\n' "$3" "${RC:-?}"
  printf '%s\n' "${OUT:-}" | grep -v '^$' | tail -4 | sed 's/^/       out: /'
  printf "       rerun: %s exec '%s'\n" "$0" "$3"
}
selected() { [ -z "$ONLY" ] || [[ "$PHASE/$1" == "$ONLY"* ]]; }   # --only is a prefix: roundtrip/cli. reruns all cli.* checks
# check <id> <cmd> [<regex the output must match>]  — passes iff rc==0 (and regex matches)
check() {
  local id=$1 cmd=$2 want=${3:-}
  selected "$id" || return 0
  if ! vm_exec "$cmd" >/dev/null; then fail "$id" "exit $RC" "$cmd"; return 0; fi
  if [ -n "$want" ] && ! grep -Eq "$want" <<<"$OUT"; then fail "$id" "output does not match /$want/" "$cmd"; return 0; fi
  pass "$id" "$(grep -v '^$' <<<"$OUT" | head -1 | cut -c1-90)"
}
catalog() { jq -r "$1" "$CATALOG"; }
preinstalled='to_entries[]|select(.value.preinstallCloud==true)'

# ── phase 1: presence + version ──────────────────────────────────────────────
phase_versions() {
  PHASE=versions; echo "== $PHASE: every preinstallCloud tool answers versionCmd (+cloudVerifyCmd)"
  while IFS=$'\t' read -r tool vcmd verify; do
    check "$tool" "$vcmd; exit \${PIPESTATUS:-\$?}" '.'
    if [ -n "$verify" ]; then check "$tool.verify" "$verify && echo verified" verified; fi
  done < <(catalog "$preinstalled|[.key,(.value.versionCmd//\"true\"),(.value.cloudVerifyCmd//\"\")]|@tsv")
}

# ── phase 2: auth state ──────────────────────────────────────────────────────
phase_auth() {
  PHASE=auth; echo "== $PHASE: tfa-* auth via bridge-minted dst_ token (TODOFORAI_API_URL=$VM_API_URL)"
  check credentials.json 'test -s ~/.config/todoforai/credentials.json && grep -q "\"apiToken\": *\"dst_" ~/.config/todoforai/credentials.json'
  # tfa-cli has no whoami: a bare word is a prompt and would start device-login.
  check tfa-cli.list        'tfa-cli list'
  check tfa-cli.models      'tfa-cli --list-models' '.'
  check tfa-memory.whoami   'tfa-memory whoami' 'authenticated as'
  check tfa-vault.whoami    'tfa-vault whoami'  'device session'
  check todoregistry.cats   'todoregistry-cli categories' '.'
  check tfa-wait.help       'tfa-wait --help'
  echo "== $PHASE: third-party statusCmd reports login state (rc 0 = logged in)"
  while IFS=$'\t' read -r tool scmd; do
    selected "$tool.status" || continue
    if vm_exec "$scmd" >/dev/null; then pass "$tool.status" "logged in: $(head -1 <<<"$OUT")"; else pass "$tool.status" "logged out"; fi
  done < <(catalog "$preinstalled|select(.value.statusCmd!=null)|[.key,.value.statusCmd]|@tsv")
}

# login_launcher <tool> <log> → bash snippet that forks the tool's login (product code path:
# detachedLoginCmd with a fake $BROWSER that logs the OAuth URL). subProviders (rclone) use connectCmd.
login_launcher() { local tool=$1 log=$2; cd "$REPO/packages/shared-fbe" && bun -e "import {detachedLoginCmd} from './src/loginFlow.ts'; import {TOOL_CATALOG} from './src/toolCatalog.ts'; const t=TOOL_CATALOG['$tool']; const sp=Object.values(t.subProviders||{}).find(p=>p.authType==='oauth'); const e=sp?{...t, loginCmd: sp.connectCmd.replace('{{REMOTE}}', 'smoke-'+sp.remoteName)}:t; process.stdout.write(detachedLoginCmd(e, '$log'))"; }

# ── phase 3: login flows (product code path: detachedLoginCmd) ───────────────
phase_login() {
  PHASE=login; echo "== $PHASE: detachedLoginCmd from shared-fbe yields a device code / OAuth URL (catalog patterns)"
  while IFS=$'\t' read -r tool needsPty codePat urlPat; do
    selected "$tool" || continue
    if vm_exec "$(catalog "to_entries[]|select(.key==\"$tool\")|.value.statusCmd // \"false\"")" >/dev/null; then skip "$tool" "already logged in — skipping login prompt"; continue; fi
    local log=/tmp/smoke-login-$tool.log
    # Tools with subProviders (rclone) log in via the sub-provider connectCmd, not loginCmd.
    local launch; launch=$(login_launcher "$tool" "$log")
    # detachedLoginCmd is bash (disown, $tmpd); catalog patterns are JS/PCRE → grep -P.
    local cmd="rm -f $log; $launch; sleep 8; cat $log"
    local pat=$urlPat; if [ "$codePat" != "-" ]; then pat=$codePat; fi
    if ! VM_SHELL=bash vm_exec "$cmd" >/dev/null; then fail "$tool" "launcher exit $RC" "$cmd"
    elif ! grep -Pq "$pat" <<<"$OUT"; then fail "$tool" "no match for /$pat/ in login log (pty=$needsPty)" "$cmd"
    else pass "$tool" "$(grep -Po "$pat" <<<"$OUT" | head -1 | cut -c1-80)"; fi
    vm_exec "pkill -f '^$(catalog "to_entries[]|select(.key==\"$tool\")|.value.loginCmd")' ; true" >/dev/null || true
  done < <(catalog "$preinstalled|select(.value.loginCmd!=null and (.value.deviceCodePattern!=null or .value.oauthUrlPattern!=null))|[.key,(.value.loginNeedsPty//false),(.value.deviceCodePattern//\"-\"),(.value.oauthUrlPattern//\"-\")]|join(\"\t\")")
}

# ── phase 4: functional round-trips against the real backend ─────────────────
phase_roundtrip() {
  PHASE=roundtrip; echo "== $PHASE: each tfa-* CLI does real work against $VM_API_URL"
  local k="smoke/$(date +%s)"
  check memory.add     "tfa-memory add $k 'smoke marker'"
  check memory.search  "tfa-memory search 'smoke marker'" "$k"
  check memory.get     "tfa-memory get $k" 'smoke marker'
  check memory.rm      "tfa-memory rm $k"
  check vault.put      "tfa-vault put $k v=1"
  check vault.get      "tfa-vault get $k" 'v'
  check vault.patch    "tfa-vault patch $k w=2"
  check vault.list     "tfa-vault list" 'smoke/'
  check vault.rm       "tfa-vault rm $k"
  check registry.search 'todoregistry-cli search seo' '.'
  check registry.get   'todoregistry-cli get "$(todoregistry-cli search seo --json 2>/dev/null | jq -r ".[0].id" || todoregistry-cli search seo | awk "NR==1{print \$1}")"' '.'
  check cli.agents     'tfa-cli --list-agents' '.'
  check cli.create     "tfa-cli 'Reply with exactly: SMOKE-OK' --no-watch --no-tips 2>&1 | tee /tmp/smoke-cli.out | grep -o 'created [0-9a-f-]*'" 'created'
  check cli.inspect    'id=$(grep -o "created [0-9a-f-]*" /tmp/smoke-cli.out | cut -d" " -f2); for i in $(seq 1 15); do tfa-cli --inspect "$id" 2>/dev/null | grep -A1 ASSISTANT | grep -q "SMOKE-OK" && break; sleep 3; done; tfa-cli --inspect "$id" 2>&1 | grep -A1 ASSISTANT' 'SMOKE-OK'
  check cli.status     'id=$(grep -o "created [0-9a-f-]*" /tmp/smoke-cli.out | cut -d" " -f2); tfa-cli status "$id" DONE'
  check cli.delete     'id=$(grep -o "created [0-9a-f-]*" /tmp/smoke-cli.out | cut -d" " -f2); tfa-cli delete "$id"'
  check wait.version   'tfa-wait --version' 'tfa-wait'
  # browser-manager-cli talks Noise to credentials.json browserHost (bm.todofor.ai, prod) with the
  # dev dst_ token → "invalid api key". Needs BROWSER_NOISE_HOST pointing at a dev browser-manager.
  if [ -n "${BROWSER_NOISE_HOST:-}" ]; then check browser.mgr "BROWSER_NOISE_HOST=$BROWSER_NOISE_HOST browser-manager-cli list"
  else skip browser.mgr "no dev browser-manager Noise endpoint (set BROWSER_NOISE_HOST)"; fi
  check browser.agent  'agent-browser --version' 'agent-browser'
  check python.libs    "python3 -c 'import pymupdf, matplotlib, pandas; print(\"ok\")'" ok
  check home.persist   'echo smoke-$(date +%s) > ~/.smoke-marker && cat ~/.smoke-marker' smoke-
}

# ── phase 5: update path (recreate onto current rootfs keeps state, bumps versions) ──
snapshot_versions() { # -> "tool<TAB>version" lines
  while IFS=$'\t' read -r tool vcmd; do printf '%s\t%s\n' "$tool" "$(vm_exec "$vcmd" 2>/dev/null | head -1)"; done \
    < <(catalog "$preinstalled|select(.value.installer==\"bun\" or .value.installer==\"npm\")|[.key,(.value.versionCmd//\"true\")]|@tsv")
}
phase_update() {
  PHASE=update; echo "== $PHASE: recreate = delete VM + new rootfs; home.img, device identity and auth must survive"
  local before=$STATE_DIR/versions.before after=$STATE_DIR/versions.after
  require_id
  snapshot_versions > "$before"
  vm_exec 'echo update-marker > ~/.smoke-update; cat ~/.config/todoforai/credentials.json | jq -r .deviceId' >/dev/null; local dev_before=$OUT
  local old=$ID
  cmd_down >/dev/null; cmd_up >/dev/null; require_id
  if [ "$ID" != "$old" ]; then pass recreate "$old -> $ID"; else fail recreate "same sandbox id after recreate" "true"; fi
  check marker.survives 'cat ~/.smoke-update' update-marker
  vm_exec 'jq -r .deviceId ~/.config/todoforai/credentials.json' >/dev/null
  if [ "$OUT" = "$dev_before" ]; then pass device.identity "deviceId $OUT unchanged"; else fail device.identity "deviceId changed: $dev_before -> $OUT" 'jq -r .deviceId ~/.config/todoforai/credentials.json'; fi
  check auth.survives 'tfa-memory whoami' 'authenticated as'
  check bridge.version "todoforai-bridge --version" "$(cat "$ROOT/assets/bridge.tag")"
  snapshot_versions > "$after"
  echo "== $PHASE: npm-installed CLIs vs latest published (image staleness)"
  while IFS=$'\t' read -r tool ver; do
    selected "$tool.latest" || continue
    local pkg latest; pkg=$(catalog "to_entries[]|select(.key==\"$tool\")|.value.pkg // empty")
    [ -n "$pkg" ] || { skip "$tool.latest" "no pkg in catalog"; continue; }
    latest=$(npm view "$pkg" version 2>/dev/null || echo '?')
    local have; have=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$ver" | head -1)
    if [ "$have" = "$latest" ]; then pass "$tool.latest" "$have"; else fail "$tool.latest" "image has $have, npm latest $latest → rebuild rootfs" "$(catalog "to_entries[]|select(.key==\"$tool\")|.value.versionCmd")"; fi
  done < "$after"
  echo "  before/after version snapshots: $before $after"
  diff "$before" "$after" | grep '^[<>]' | sed 's/^/  /' || echo "  (no version changes)"
}

cmd_test() {
  if [ "${1:-}" = --only ]; then ONLY=$2; shift 2; fi
  require_id
  local phases=${*:-all}
  [ "$phases" = all ] && phases="versions auth login roundtrip update"
  [ -n "$ONLY" ] && phases=${ONLY%%/*}
  for p in $phases; do case $p in
    versions|1)  phase_versions ;;
    auth|2)      phase_auth ;;
    login|3)     phase_login ;;
    roundtrip|4) phase_roundtrip ;;
    update|5)    phase_update ;;
    *) die "unknown phase $p" ;;
  esac; done
  echo "== $PASS passed, $FAIL failed, $SKIP skipped   vm=$ID"
  [ "$FAIL" -eq 0 ] || { printf '   failed: %s\n' "${FAILED_IDS[@]}"; echo "   rerun one: $0 test --only <phase/id>"; }
  # merge into latest results (checks not run this time keep their previous line)
  # one row per check id, latest wins (old file first, then this run)
  { [ -f "$RESULTS" ] && cat "$RESULTS"; cat "$RESULTS.new"; } | awk -F'\t' '{r[$1]=$0} END{for(k in r) print r[k]}' | sort -o "$RESULTS.tmp" || true
  mv "$RESULTS.tmp" "$RESULTS"; rm -f "$RESULTS.new"
  printf '%s\tphases=%s\tpass=%s fail=%s skip=%s\tvm=%s\tfailed=%s\n' "$(date -Is)" "$phases" "$PASS" "$FAIL" "$SKIP" "$ID" "${FAILED_IDS[*]:-}" >> "$HISTORY"
  echo "   results: $RESULTS   history: $HISTORY   table: $0 report"
  [ "$FAIL" -eq 0 ]
}

# ── report: regenerate the per-CLI table in docs/smoke-vm.md from results.tsv ─
cmd_report() {
  [ -f "$RESULTS" ] || die "no results yet — run: $0 test"
  local doc=$ROOT/docs/smoke-vm.md
  local table; table=$(python3 - "$RESULTS" "$CATALOG" "$HISTORY" <<'PY'
import sys, json, collections
res = {}
for line in open(sys.argv[1]):
    id_, st, summ = (line.rstrip('\n').split('\t') + ['',''])[:3]
    res[id_] = (st, summ)
cat = json.load(open(sys.argv[2]))
tools = [k for k, v in cat.items() if v.get('preinstallCloud')]
alias = {'todoregistry': 'todoregistry-cli', 'memory': 'tfa-memory', 'vault': 'tfa-vault', 'registry': 'todoregistry-cli',
         'cli': 'tfa-cli', 'wait': 'tfa-wait', 'browser.mgr': 'browser-manager-cli', 'browser.agent': 'agent-browser',
         'python.libs': 'python3', 'ripgrep': 'ripgrep'}
def tool_of(id_):
    ph, rest = id_.split('/', 1)
    for a, t in alias.items():
        if rest == a or rest.startswith(a + '.'): return t
    base = rest.split('.')[0]
    return base if base in tools else None
cols = ['versions', 'auth', 'login', 'roundtrip', 'update']
per = collections.defaultdict(lambda: {c: [] for c in cols})
for id_, (st, summ) in res.items():
    t = tool_of(id_)
    if t: per[t][id_.split('/')[0]].append((id_.split('/',1)[1], st))
def cell(items):
    if not items: return '–'
    bad = [i for i, s in items if s == 'FAIL']
    if bad: return '❌ ' + ', '.join(bad)
    if all(s == 'SKIP' for _, s in items): return '⏭ ' + items[0][0]
    return '✅ %d' % len(items)
last = open(sys.argv[3]).read().strip().split('\n')[-1].split('\t') if sys.argv[3] else []
out = ['Generated by `scripts/smoke-vm.sh report` from `.smoke/results.tsv`. Last run: %s (%s).' % (last[0] if last else '?', last[2] if len(last) > 2 else '?'), '',
       '✅ n = n checks passing · ❌ = failing check ids · ⏭ = skipped · – = no check yet', '',
       '| CLI | versions | auth | login | roundtrip | update |', '|---|---|---|---|---|---|']
for t in tools:
    out.append('| %s | %s |' % (t, ' | '.join(cell(per[t][c]) for c in cols)))
other = sorted(i for i in res if not tool_of(i))
if other:
    out += ['', 'Non-tool checks: ' + ', '.join('%s %s' % ('✅' if res[i][0]=='PASS' else '❌' if res[i][0]=='FAIL' else '⏭', i) for i in other)]
print('\n'.join(out))
PY
)
  python3 - "$doc" "$table" <<'PY'
import sys, re
doc, table = sys.argv[1], sys.argv[2]
s = open(doc).read()
start, end = '<!-- coverage:start -->', '<!-- coverage:end -->'
block = f'{start}\n{table}\n{end}'
s = re.sub(re.escape(start) + '.*?' + re.escape(end), lambda _: block, s, flags=re.S) if start in s else s + '\n## Per-CLI coverage\n\n' + block + '\n'
open(doc, 'w').write(s)
PY
  echo "updated $doc"; sed -n "/coverage:start/,/coverage:end/p" "$doc" | grep -c '^|' | sed 's/$/ table rows/'
}

case ${1:-} in
  up)       cmd_up ;;
  down)     cmd_down ;;
  recreate) cmd_down; cmd_up ;;
  rebuild)  cmd_rebuild ;;
  reset)    cmd_reset ;;
  status)   api "$MGR/sandbox" | jq ;;
  exec)     shift; [ $# -gt 0 ] || die "exec: command required"; require_id; vm_exec "$@" ;;
  shell)    cmd_shell ;;
  login)    shift; [ $# -eq 1 ] || die "login <tool>"; cmd_login "$1" ;;
  test)     shift; cmd_test "$@" ;;
  report)   cmd_report ;;
  *) sed -n 2,15p "$0"; exit 1 ;;
esac
