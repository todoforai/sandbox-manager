# Plan — Auth-derived identity, Redis inventory, admin API

Status: proposal
Owner: sandbox-manager

## Goals

1. The caller never self-declares `user_id`. It is derived from the auth token.
2. Sandbox inventory (who owns what, which are running) lives in Redis, not in a single-node in-memory `DashMap`.
3. Two clear API surfaces: **user** (scoped to `user_id` from token) and **admin** (global visibility).
4. Sandbox-manager stays responsible only for: executing VM ops, owning the `sandbox:*` Redis namespace, enforcing per-user limits, reporting stats. It does not own devices, API keys, or billing accounting.

## Non-goals

- Multi-host scheduling across several sandbox-manager nodes. (Redis schema supports it; actual placement logic is a separate later plan.)
- Replacing backend-issued tokens. Backend keeps minting `resource:token:*` and `apikey:*`.

---

## 1. Terminology cleanup

Rename `Session` → `Sandbox`. The word "session" was ambiguous (user login vs. VM instance). Touch every consumer:

- `sandbox-manager/src/vm/session.rs` → `sandbox-manager/src/vm/sandbox.rs`
- `Session`, `SessionState`, `SessionStats` → `Sandbox`, `SandboxState`, `SandboxStats`
- `self.sessions: DashMap<...>` → removed (see §3)
- `SandboxInfo` stays (API DTO); `From<Session>` becomes `From<Sandbox>`

Metrics (`cpu_time_ms`, `peak_memory_kb`) move out of `Sandbox` into a separate pull-on-demand `SandboxMetrics` struct. They are not part of the inventory record.

---

## 2. Auth-derived identity

### 2.1 Request shape

```rust
// before
struct CreateSandboxRequest { user_id, template?, size?, enroll_token? }

// after
struct CreateSandboxRequest { template?, size? }
```

Drop `user_id` and `enroll_token` from the client payload. Both come from the auth layer.

### 2.2 Auth layer

New module: `sandbox-manager/src/auth/mod.rs`

```rust
pub struct AuthIdentity {
    pub user_id: String,
    pub role: Role,          // User | Admin
    pub enroll_token: String,  // the raw token; passed to Firecracker kernel cmdline for the VM's edge agent
}

pub enum Role { User, Admin }

pub async fn authenticate(redis: &RedisClient, token: &str) -> Result<AuthIdentity>;
```

Resolution order (same as today's `resolve_token`, extended):

1. `resource:token:<token>` → userId  (short-lived, frontend flow)
2. `apikey:<token>` → { userId, role? }  (long-lived, CLI / server-to-server)

Role defaults to `User`. Admin role is a field on the `apikey:<token>` HASH set by backend when the API key belongs to a staff user. No new Redis namespace.

If `redis` is not configured (dev), auth is skipped and identity becomes `{ user_id: "dev", role: Admin, enroll_token: "" }` — explicit dev fallback, logged at WARN on every request.

### 2.3 REST auth

Axum extractor `AuthUser` / `AuthAdmin` pulls `Authorization: Bearer <token>`, calls `authenticate`, rejects with 401/403 otherwise. Wire as request extensions so handlers receive `AuthIdentity` directly.

### 2.4 Noise auth

The Noise `NoiseRequest` currently has no auth field. Add:

```rust
struct NoiseRequest {
    id: String,
    kind: String,
    #[serde(default)]
    token: Option<String>,
    #[serde(default)]
    payload: Value,
}
```

`dispatch` calls `authenticate(&redis, &token)` before every non-`health.get` request; admin-only methods require `Role::Admin`. Callers (backend) must include the token — they already have it (they minted it).

---

## 3. Redis as source of truth

### 3.1 Key schema

```
sandbox:<id>                        HASH
  userId, template, size, state,
  ip, tap, pid, createdAt, lastActivity, error

sandbox:user:<userId>               SET   sandboxIds owned by user
sandbox:active                      SET   sandboxIds in Running|Paused|Creating
sandbox:by-template:<template>      SET   sandboxIds per template

stats:sandbox:created               COUNTER   monotonic lifetime counter
```

TTLs: none on `sandbox:<id>` (sandbox-manager is the writer; it deletes). Optional soft TTL of 24h on `Terminated|Error` records, then cleaned up.

### 3.2 Writer interface

New module: `sandbox-manager/src/redis/inventory.rs` (split the existing `redis.rs` into `redis/auth.rs` + `redis/inventory.rs` + `redis/mod.rs`).

```rust
impl RedisClient {
    async fn sandbox_put(&self, s: &Sandbox) -> Result<()>;        // HSET + SADD
    async fn sandbox_get(&self, id: &str) -> Result<Option<Sandbox>>;
    async fn sandbox_delete(&self, id: &str) -> Result<()>;        // HDEL + SREM
    async fn sandbox_set_state(&self, id: &str, state: SandboxState) -> Result<()>;
    async fn sandbox_touch(&self, id: &str) -> Result<()>;         // update lastActivity

    async fn sandbox_list_by_user(&self, user_id: &str) -> Result<Vec<Sandbox>>;
    async fn sandbox_list_active(&self) -> Result<Vec<Sandbox>>;   // admin
    async fn sandbox_user_count(&self, user_id: &str) -> Result<usize>; // for limits
}
```

All writes use a MULTI/EXEC or a single Lua script per op so the HASH and SET stay consistent.

### 3.3 VmManager changes

`VmManager` keeps only non-serializable state:

```rust
pub struct VmManager {
    config: ManagerConfig,
    launcher: Option<FirecrackerLauncher>,
    network: NetworkManager,
    redis: RedisClient,                                        // required, not optional
    vms: DashMap<String, Arc<RwLock<FirecrackerVm>>>,          // process handles only
    boot_configs: DashMap<String, BootConfig>,                 // static
}
```

`sessions: DashMap<String, Session>` is **removed**. Every read of sandbox metadata goes to Redis.

If Redis is not available at startup → hard fail (no more "auth disabled" silent mode for prod). Dev mode = a single local `redis:7` container.

### 3.4 Startup reconciliation

On `VmManager::new`:

1. Read `sandbox:active` from Redis.
2. For each entry, check `pid` is alive via `/proc/<pid>`.
3. Alive: reconstruct `FirecrackerVm` handle (API socket path is deterministic: `overlays/runtime/<id>.sock`), insert into `self.vms`.
4. Dead: mark state=`Error`, error="orphaned on restart", remove from `sandbox:active`.

Logged summary: `reconciled N sandboxes: M alive, K orphaned`.

### 3.5 Per-user limits

Replace the hard-coded `10`:

```rust
const DEFAULT_LIMIT: usize = 10;
let limit = redis.hget::<f64>("appuser:<userId>", "sandboxLimit").await?
    .unwrap_or(DEFAULT_LIMIT);
if redis.sandbox_user_count(user_id).await? >= limit { bail!("limit reached") }
```

Backend sets `sandboxLimit` on `appuser:*` per plan (Hobby 2, Starter 5, Pro 10, Ultra 50 — numbers TBD by product).

---

## 4. API surfaces

### 4.1 User API (REST + Noise)

All scoped to `identity.user_id` from auth. The server refuses to return sandboxes owned by other users.

| Method | Path                     | Notes                                   |
|--------|--------------------------|-----------------------------------------|
| POST   | `/sandbox`               | body: `{ template?, size? }`            |
| GET    | `/sandbox`               | lists caller's sandboxes only           |
| GET    | `/sandbox/:id`           | 403 if not owner                        |
| DELETE | `/sandbox/:id`           | 403 if not owner                        |
| POST   | `/sandbox/:id/pause`     | 403 if not owner                        |
| POST   | `/sandbox/:id/resume`    | 403 if not owner                        |
| GET    | `/sandbox/:id/metrics`   | pull-on-demand Firecracker metrics      |
| GET    | `/templates`             | public, no auth needed                  |

Noise dispatcher mirrors these with `sandbox.create / get / list / delete / pause / resume / metrics`.

### 4.2 Admin API (REST + Noise)

Requires `Role::Admin`.

| Method | Path                            | Notes                                                |
|--------|---------------------------------|------------------------------------------------------|
| GET    | `/admin/sandboxes`              | query: `userId?`, `state?`, `template?`, `limit?`    |
| GET    | `/admin/sandboxes/:id`          | any user's sandbox                                   |
| DELETE | `/admin/sandboxes/:id`          | force-kill (for abuse / runaway VMs)                 |
| GET    | `/admin/users/:userId/sandboxes`| shortcut                                             |
| GET    | `/admin/stats`                  | global counters (see §4.3)                           |
| GET    | `/admin/host`                   | host resources (free mem, KVM slots, bridge IPs)     |
| POST   | `/admin/templates/:name`        | moved from user API — only admins register templates |

Noise: `admin.sandboxes.list / get / delete`, `admin.stats.get`, `admin.host.get`, `admin.template.create`.

### 4.3 `/admin/stats` payload

```json
{
  "sandboxes": {
    "total_created": 12456,
    "active": 87,
    "running": 71,
    "paused": 16,
    "by_template": { "alpine-base": 40, "alpine-edge": 47 },
    "by_size": { "small": 20, "medium": 50, "large": 17 },
    "total_memory_mb": 42800,
    "actual_memory_kb": 1820000
  },
  "host": {
    "cpu_count": 32,
    "load_1m": 4.2,
    "free_memory_mb": 98304,
    "bridge_ips_free": 4891
  },
  "top_users": [
    { "userId": "u_abc", "count": 8 },
    { "userId": "u_def", "count": 6 }
  ]
}
```

`by_template`, `by_size`, `top_users` come from scanning `sandbox:active` + HGETs; cheap at O(active sandboxes), acceptable for admin.

---

## 5. Frontend & admin panel integration

**Frontend (end user)** — already planned flow per `docs/NEXT_STEPS.md`:
1. Frontend calls backend `POST /trpc/resource.getToken` with user session.
2. Backend writes `resource:token:<t> → userId` (TTL 1h) and returns the token.
3. Frontend calls `sandbox-manager` (via backend proxy) with `Authorization: Bearer <t>`.
4. Sandbox-manager resolves token → userId → proceeds.

**Admin panel** — two options, pick one:

- **A. Admin token direct.** Backend mints a long-lived admin API key with `role=Admin` on the `apikey:*` HASH. Admin panel proxies through backend but backend forwards the admin token to sandbox-manager. Simpler; sandbox-manager exposes admin endpoints on a separate port or same port with auth guard.
- **B. Backend-gated.** Admin panel only talks to backend. Backend implements its own admin routes that call sandbox-manager admin API server-to-server with a shared admin token. Sandbox-manager admin API is never exposed publicly.

**Recommendation: B.** Sandbox-manager admin endpoints are only reachable from inside the private network; public ingress is backend only. Less blast radius if sandbox-manager is compromised.

---

## 6. What moves where

| Concern                          | Owner             | Storage           |
|----------------------------------|-------------------|-------------------|
| Device enrollment (CLI)          | backend           | Postgres          |
| API key issuance & roles         | backend           | Redis `apikey:*`  |
| Short-lived resource tokens      | backend           | Redis `resource:token:*` |
| User balance / billing ledger    | backend           | Postgres + Redis  |
| Sandbox inventory (live state)   | **sandbox-manager** | **Redis `sandbox:*`** |
| VM process handles               | sandbox-manager   | in-memory         |
| Template files (kernel/rootfs)   | sandbox-manager   | disk `$DATA_DIR`  |
| VM overlays / snapshots          | sandbox-manager   | disk `$DATA_DIR`  |
| Per-user sandbox limit           | backend writes    | Redis `appuser:*.sandboxLimit` |

---

## 7. Migration steps (implementation order)

Each step is independently shippable and keeps the system working.

### Step 1 — rename `Session` → `Sandbox`
Pure rename. No behavior change. Touch `vm/session.rs`, `vm/manager.rs`, `service/types.rs`, noise protocol field names if any.

### Step 2 — Auth layer & identity extractor
Add `auth/mod.rs`, REST extractor, Noise `token` field. Keep `user_id` in the request for now (ignored if identity says otherwise, logged mismatch). No behavior change for existing callers.

### Step 3 — drop `user_id` from `CreateSandboxRequest`
Breaking API change. Update C CLI (`sandbox-manager/cli/main.c`), backend callers, docs. Noise `sandbox.create` payload no longer takes `user_id`.

### Step 4 — Redis inventory writer
Every `VmManager` op writes to Redis after the local `DashMap` update. Redis now shadows the in-memory state. Read path unchanged (still reads `DashMap`). If Redis write fails, log and continue (non-fatal during rollout).

### Step 5 — Switch reads to Redis
Flip all read paths (`get_sandbox`, `list_sandboxes`, `stats`) to Redis. Remove `sessions: DashMap`. Redis becomes required (hard fail at startup without it).

### Step 6 — Startup reconciliation
Implement §3.4. Without this, restarts lose the ability to manage running VMs.

### Step 7 — Admin API
Add `/admin/*` routes, admin role check, `admin.*` Noise methods, stats aggregation. Frontend/admin panel integration follows.

### Step 8 — Per-user plan limits
Read `sandboxLimit` from `appuser:*`. Backend coordination: add the field to plan upgrade flow.

---

## 8. Open decisions

1. **Admin panel access pattern** — going with option B (backend-gated) unless you say otherwise.
2. **Role storage** — add `role` field to `apikey:*` HASH, or a separate `admin:<userId>` SET? Field is simpler; SET is easier to audit ("list all admins"). Preference?
3. **Reconciliation on restart** — kill orphans, or mark `Error` and let user re-create? Default: mark `Error`, add a `POST /admin/sandboxes/:id/force-kill` to clean up manually. Autokill is aggressive.
4. **Dev mode without Redis** — support it (single-user "dev" identity) or require Redis always? Current proposal: require Redis always, spin up a local container in dev scripts.
5. **`sandboxLimit` defaults** — what numbers per plan? (Hobby, Starter, Pro, Ultra)

---

## 9. Files touched (estimate)

New:
- `sandbox-manager/src/auth/mod.rs`
- `sandbox-manager/src/redis/inventory.rs`
- `sandbox-manager/src/redis/auth.rs`
- `sandbox-manager/src/redis/mod.rs` (re-exports)
- `sandbox-manager/src/api/admin.rs`

Modified:
- `sandbox-manager/src/main.rs` — wire auth, admin routes, require Redis
- `sandbox-manager/src/vm/manager.rs` — drop `sessions`, read/write via Redis, reconcile
- `sandbox-manager/src/vm/sandbox.rs` (renamed) — strip metrics out
- `sandbox-manager/src/service/mod.rs` — take `AuthIdentity`, scope by user
- `sandbox-manager/src/service/types.rs` — drop `user_id` from request
- `sandbox-manager/src/noise/protocol.rs` — add `token` field, new admin methods
- `sandbox-manager/src/noise/server.rs` — auth in dispatch, admin methods
- `sandbox-manager/src/api/sandbox.rs` — take `AuthIdentity` extractor
- `sandbox-manager/cli/main.c` — drop `user_id` arg from create
- `sandbox-manager/README.md`, `sandbox-manager/docs/NEXT_STEPS.md` — update docs
