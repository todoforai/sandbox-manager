# Smoke VM — persistent sandbox for CLI tool testing

`scripts/smoke-vm.sh` drives ONE fixed sandbox owned by a dedicated dev user
(`smoke-vm@todofor.ai`). Config in `.env.smoke` (gitignored): `SMOKE_USER_ID`,
`SMOKE_TOKEN` (Dragonfly `resource:token:<tok> -> <uid>`). One sandbox per user +
persistent `home.img` at `$USER_HOMES_DIR/<uid>` = a reusable fixture; the
sandbox id changes on recreate, the user/home/device don't.

```
scripts/smoke-vm.sh up | exec <cmd…> | shell | status | down | recreate | reset
scripts/smoke-vm.sh test [versions|auth|all]
```

`recreate` = delete + create onto the current rootfs (this IS the update path,
see vm-update.todo.md). `reset` also wipes home.img.

Before testing a rootfs change: `IMPORT=0 scripts/build-oci.sh` then
`docker save docker.io/library/sandbox-rootfs:dev | sudo ctr -n default images import -`
(or `IMPORT=1` if sudo is passwordless). After Go changes:
`go build -o ./sandbox-manager ./cmd/sandbox-manager && pm2 restart sandbox-manager`
(pm2 restart alone does not rebuild).

## Coverage

| Area | Status | Notes |
|---|---|---|
| VM create/reuse/delete/recreate/reset | tested | recreate keeps home.img (marker + creds survive) |
| Enrollment (bridge redeems token, device attached) | tested | implied by `up` + phase 2a |
| Presence + version, all `preinstallCloud` tools | tested (phase 1) | `versionCmd` rc=0 + output, `cloudVerifyCmd` |
| tfa-* auth via bridge `dst_` token, no login | tested (phase 2a) | exec is PTY-less → script sets `TODOFORAI_API_URL` like the bridge would |
| 3rd-party `statusCmd`, logged-out branch | tested (phase 2b) | zele xurl gh mcporter rclone |
| 3rd-party `statusCmd`, logged-in + survives recreate | TODO | needs one manual OAuth per tool on the fixture |
| Login prompts match `deviceCodePattern`/`oauthUrlPattern` | TODO (phase 3) | gh/xurl/rclone; zele needs PTY → product UI only |
| Functional round-trips (memory, vault, tfa-cli -n, registry, tfa-wait, browser) | TODO (phase 4) | |
| Update: rebuild → recreate → versions ≥, state intact, update-notifier | TODO (phase 5) | done once by hand |
| In-VM self-update | n/a | by design, recreate is the update |
| tfa-explore / tfa-review / tfa-handoff | not in image | not `preinstallCloud` |
| `statusCmd` for tfa-* tools | catalog gap | tfa-cli has no `whoami`; bare word = prompt → device-login hangs |
| PTY-only behaviour (env injection, pagers, interactive login) | not covered | |
| Prod manager | TODO | `SANDBOX_MANAGER_URL` + prod resource token |

## Per-CLI coverage

<!-- coverage:start -->
(run `scripts/smoke-vm.sh report`)
<!-- coverage:end -->

## Issues found by the smoke VM

Status: 🔴 open · 🟡 workaround in harness · 🟢 fixed. Keep this list current; the
table above is generated, this one is hand-maintained.

| # | Status | Where | Issue | Fix / workaround |
|---|---|---|---|---|
| 1 | 🟢 | sandbox-manager `/exec` | non-zero exit returned HTTP 500 with no output | returns `{output, exit_code}` |
| 2 | 🟢 | sandbox-manager `/exec` | no env → CLIs could not find backend | allowlisted env forwarded (`NOISE_*`, `BRIDGE_PORT`, `DEVICE_NAME`) |
| 3 | 🟢 | dev host | containerd had a stale rootfs (bridge 1.4.5, 17 tools missing) — docker image rebuilt but never `ctr import`ed | `smoke-vm.sh rebuild`; consider `IMPORT=1` default in dev |
| 4 | 🟢 | oci/Dockerfile | matplotlib/pandas missing from image | fixed by rebuild after pip commits |
| 5 | 🟡 | tfa-* + shared-credentials | outside a bridge PTY `TODOFORAI_API_URL` is unset → dst_ token ignored → "not authenticated" (cron/exec paths) | harness sets URL; consider persisting `apiUrl` in credentials.json from the bridge |
| 6 | 🟡 | tfa-cli | no `whoami`; bare unknown word = prompt → device-login hangs. Catalog has no `statusCmd` for any tfa-* | harness uses `tfa-cli list`; add `whoami` + `statusCmd` |
| 7 | 🟡 | tfa-cli `-n` | blocks forever in headless exec (watch never returns) | harness uses `--no-watch` + `--inspect` poll |
| 8 | 🔴 | tfa-memory | `add` warns "embeddings unavailable: 429 You have no credits" on dev | dev embedding provider credits |
| 9 | 🔴 | login/gh | `detachedLoginCmd` for gh writes an empty log; gh run directly prints the device code fine | investigate `script`/nohup interaction for gh |
| 10 | 🔴 | catalog | tfa-explore / tfa-review / tfa-handoff not `preinstallCloud` → absent in VM | decide; add to catalog if wanted |
| 11 | 🔴 | login/zele | needs PTY (`loginNeedsPty`), only testable via product UI | manual |
