package store

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/todoforai/sandbox-manager/internal/vm"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// State is the lifecycle of a sandbox. Kept string-compatible with the old
// Rust service's wire format ("creating"/"running"/...) because the backend
// and frontend parse these over the Redis event channel.
type State string

const (
	StateCreating    State = "creating"
	StateRunning     State = "running"
	StateTerminating State = "terminating"
	StateError       State = "error"
)

// Sandbox is the inventory record persisted in Redis at `sandbox:<id>` and
// published to `sandbox:events:<userId>`. Field names (JSON) match the old
// SandboxInfo so the backend's subscriber needs no change.
//
// Dropped vs the old model: pid (containerd owns the process), ip allocation
// internals (CNI owns it; we keep the resolved IP only), Lite (VM-only now),
// pause/balloon. `device_id` stays for backend Device cleanup. `kind` is kept
// (always "vm") because the backend's tier alignment still keys off it.
type Sandbox struct {
	ID       string `json:"id"`
	UserID   string `json:"user_id"`
	Template string `json:"template"`
	Size     string `json:"size"`
	// Kind is always "vm": this manager is VM-only (Lite was dropped in the Go
	// rewrite). The backend still distinguishes vm/lite in its tier alignment
	// (`syncToTier` matches `kind === 'vm'`), so we must emit it — a missing
	// kind makes the backend never recognise an existing VM as aligned and it
	// loops creating new ones (→ 409 "user already has an active sandbox").
	Kind       string  `json:"kind"`
	State      State   `json:"state"`
	IPAddress  string  `json:"ip_address,omitempty"`
	CostPerMin float64 `json:"cost_per_minute"`
	// Resources are the purchased overrides on top of Size (zero = none).
	Resources    vm.Resources `json:"resources"`
	Error        string       `json:"error,omitempty"`
	DeviceID     string       `json:"device_id,omitempty"`
	CreatedAt    int64        `json:"created_at"`
	LastActivity int64        `json:"last_activity"`
	// SSHConnections is the live count of SSH relay sessions older than the
	// guest's login grace (so, authenticated). Filled in at read time by the
	// service and never persisted; 0 after a manager restart.
	SSHConnections int `json:"ssh_connections,omitempty"`
}

// IsActive reports whether the sandbox holds resources / counts against quota.
// Terminating MUST count: until the VM is actually gone, the user must not be
// able to create another, and it must not be dropped from sandbox:active.
func (s *Sandbox) IsActive() bool {
	return s.State == StateRunning || s.State == StateCreating || s.State == StateTerminating
}

func NowMillis() int64 { return time.Now().UnixMilli() }

// Identity is the resolved caller. Mirrors the old Rust AuthIdentity.
type Identity struct {
	UserID      string
	Role        string // "admin" | "user"
	IsAnonymous bool
	ScopeUserID string // admin-only: narrow a List to one user ("" = all)
}

func (i Identity) IsAdmin() bool { return i.Role == "admin" }

// Store wraps Redis. Redis is the source of truth for identity (writer:
// backend) and sandbox inventory (writer: this service). Key schema and event
// payloads are a contract with the backend — do not change casually.
type Store struct {
	rdb *redis.Client
}

func New(url string) (*Store, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parse DRAGONFLY_URL: %w", err)
	}
	return &Store{rdb: redis.NewClient(opt)}, nil
}

func (s *Store) Ping(ctx context.Context) error { return s.rdb.Ping(ctx).Err() }

// ── Identity ───────────────────────────────────────────────────────────────

// ResolveIdentity maps a bearer token to (userId, role, isAnonymous). Sources,
// in precedence order (identical to the old service):
//  1. resource:token:<t>  STRING -> userId            (role=user)
//  2. apikey:<t>          HASH {userId, role?}         (only admin source)
//  3. Better Auth session: session:idx:token:<t> SET -> sid,
//     session:<sid> HASH {userId, expiresAt}; isAnonymous from user:<uid>.
//
// Better Auth bearer tokens are signed as "<token>.<sig>"; the Redis index is
// keyed by the unsigned token, so strip the suffix before lookup.
func (s *Store) ResolveIdentity(ctx context.Context, token string) (*Identity, error) {
	if i := strings.IndexByte(token, '.'); i >= 0 {
		token = token[:i]
	}

	if uid, err := s.rdb.Get(ctx, "resource:token:"+token).Result(); err == nil && uid != "" {
		return &Identity{UserID: uid, Role: "user"}, nil
	} else if err != nil && err != redis.Nil {
		return nil, err
	}

	if vals, err := s.rdb.HMGet(ctx, "apikey:"+token, "userId", "role").Result(); err == nil {
		if uid, ok := vals[0].(string); ok && uid != "" {
			role, _ := vals[1].(string)
			if role == "" {
				role = "user"
			}
			return &Identity{UserID: uid, Role: role}, nil
		}
	}

	sids, err := s.rdb.SMembers(ctx, "session:idx:token:"+token).Result()
	if err != nil || len(sids) == 0 {
		return nil, err
	}
	vals, err := s.rdb.HMGet(ctx, "session:"+sids[0], "userId", "expiresAt").Result()
	if err != nil {
		return nil, err
	}
	uid, _ := vals[0].(string)
	if uid == "" {
		return nil, nil
	}
	if exp, _ := vals[1].(string); exp != "" {
		if t, err := time.Parse(time.RFC3339, exp); err == nil && t.Before(time.Now()) {
			return nil, nil // expired
		}
	}
	anon, _ := s.rdb.HGet(ctx, "user:"+uid, "isAnonymous").Result()
	return &Identity{UserID: uid, Role: "user", IsAnonymous: anon == "1"}, nil
}

// ── Inventory ────────────────────────────────────────────────────────────────

// relIfOwner deletes the key only when its value equals ARGV[1] (the owning
// sandbox id). Used by ReleaseUserSlot to avoid clobbering a reused slot.
var relIfOwner = redis.NewScript(`
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0`)

func eventsChannel(userID string) string { return "sandbox:events:" + userID }

// Put inserts/replaces a sandbox record, keeps set memberships consistent, and
// publishes the record to sandbox:events:<userId> in one pipeline so a
// subscriber never sees a write without its event.
func (s *Store) Put(ctx context.Context, sb *Sandbox) error {
	cp := *sb
	cp.SSHConnections = 0 // live-only, never persisted
	js, err := json.Marshal(&cp)
	if err != nil {
		return err
	}
	pipe := s.rdb.TxPipeline()
	pipe.Set(ctx, "sandbox:"+sb.ID, js, 0)
	pipe.SAdd(ctx, "sandbox:user:"+sb.UserID, sb.ID)
	pipe.SAdd(ctx, allKey, sb.ID)
	if sb.IsActive() {
		pipe.SAdd(ctx, "sandbox:active", sb.ID)
	} else {
		pipe.SRem(ctx, "sandbox:active", sb.ID)
	}
	pipe.Publish(ctx, eventsChannel(sb.UserID), js)
	_, err = pipe.Exec(ctx)
	return err
}

// PutRunning commits a boot only while its creating record still owns the slot.
// A concurrent delete must not be undone by a late successful vm.Create.
func (s *Store) PutRunning(ctx context.Context, sb *Sandbox) error {
	cp := *sb
	cp.SSHConnections = 0
	js, err := json.Marshal(&cp)
	if err != nil {
		return err
	}
	n, err := putRunning.Run(ctx, s.rdb, []string{
		"sandbox:user-slot:" + sb.UserID, "sandbox:" + sb.ID, eventsChannel(sb.UserID),
	}, sb.ID, js).Int()
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("sandbox %s was deleted during creation", sb.ID)
	}
	return nil
}

var putRunning = redis.NewScript(`
if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
local record = redis.call('GET', KEYS[2])
if not record or cjson.decode(record).state ~= 'creating' then return 0 end
redis.call('SET', KEYS[2], ARGV[2])
redis.call('PUBLISH', KEYS[3], ARGV[2])
return 1`)

func (s *Store) Get(ctx context.Context, id string) (*Sandbox, error) {
	js, err := s.rdb.Get(ctx, "sandbox:"+id).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var sb Sandbox
	if err := json.Unmarshal(js, &sb); err != nil {
		return nil, err
	}
	// Backfill kind for records persisted before the field existed. This
	// manager is VM-only, so a missing kind is always "vm" — without it the
	// backend's tier alignment (`kind === 'vm'`) never matches an existing VM
	// and loops creating new ones (quota 409).
	if sb.Kind == "" {
		sb.Kind = "vm"
	}
	return &sb, nil
}

// Delete atomically removes the record, indexes and owned quota slot, then publishes a delete event.
func (s *Store) Delete(ctx context.Context, id string) error {
	sb, err := s.Get(ctx, id)
	if err != nil || sb == nil {
		return err
	}
	ev, _ := json.Marshal(map[string]any{"id": id, "user_id": sb.UserID, "deleted": true})
	return deleteSandbox.Run(ctx, s.rdb, []string{
		"sandbox:" + id, sshPortKey(id), "sandbox:active", "sandbox:user:" + sb.UserID,
		allKey, "sandbox:user-slot:" + sb.UserID, eventsChannel(sb.UserID),
	}, id, ev).Err()
}

var deleteSandbox = redis.NewScript(`
redis.call('DEL', KEYS[1], KEYS[2])
redis.call('SREM', KEYS[3], ARGV[1])
redis.call('SREM', KEYS[4], ARGV[1])
redis.call('SREM', KEYS[5], ARGV[1])
if redis.call('GET', KEYS[6]) == ARGV[1] then redis.call('DEL', KEYS[6]) end
redis.call('PUBLISH', KEYS[7], ARGV[2])
return 1`)

func sshPortKey(id string) string { return "sandbox:ssh-port:" + id }

// SetSSHPort remembers a sandbox's relay port so a restarted manager reopens
// the same port. A separate key (not a Sandbox field) so it never races a
// concurrent record Put. Removed by Delete.
func (s *Store) SetSSHPort(ctx context.Context, id string, port int) error {
	return s.rdb.Set(ctx, sshPortKey(id), port, 0).Err()
}

// SSHPort returns the remembered relay port, 0 if none.
func (s *Store) SSHPort(ctx context.Context, id string) (int, error) {
	n, err := s.rdb.Get(ctx, sshPortKey(id)).Int()
	if err == redis.Nil {
		return 0, nil
	}
	return n, err
}

// PurgeUserIndexes removes residual membership/quota keys after all user's
// sandboxes have been deleted. It is idempotent and heals partial prior cleanup.
func (s *Store) PurgeUserIndexes(ctx context.Context, userID string) error {
	return s.rdb.Del(ctx, "sandbox:user:"+userID, "sandbox:user-slot:"+userID).Err()
}

// ListByUserScan finds user sandboxes from authoritative records as a fallback
// when the sandbox:user index is stale or missing. O(sandboxes), never a keyspace SCAN.
func (s *Store) ListByUserScan(ctx context.Context, userID string) ([]*Sandbox, error) {
	all, err := s.List(ctx, "")
	if err != nil {
		return nil, err
	}
	var out []*Sandbox
	for _, sb := range all {
		if sb.UserID == userID {
			out = append(out, sb)
		}
	}
	return out, nil
}

// allKey indexes every sandbox id, so admin/reconcile listing is one SMEMBERS.
// Never SCAN for sandboxes: the shared DB holds ~8M keys, and the 30s reconcile
// loop scanning `sandbox:user:*` cost ~20s of Dragonfly CPU per pass.
const allKey = "sandbox:all"

// List returns a user's sandboxes, or all sandboxes when userID == "" (admin).
func (s *Store) List(ctx context.Context, userID string) ([]*Sandbox, error) {
	key := allKey
	if userID != "" {
		key = "sandbox:user:" + userID
	}
	ids, err := s.rdb.SMembers(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	out := make([]*Sandbox, 0, len(ids))
	for _, id := range ids {
		if sb, err := s.Get(ctx, id); err == nil && sb != nil {
			out = append(out, sb)
		}
	}
	return out, nil
}

// ReserveUserSlot atomically claims the slot and persists its creating record.
// A held slot without a record can therefore only be an interrupted legacy cleanup,
// never a concurrent create between reservation and Put.
func (s *Store) ReserveUserSlot(ctx context.Context, sb *Sandbox) (bool, error) {
	js, err := json.Marshal(sb)
	if err != nil {
		return false, err
	}
	n, err := reserveUserSlot.Run(ctx, s.rdb, []string{
		"sandbox:user-slot:" + sb.UserID, "sandbox:" + sb.ID,
		"sandbox:user:" + sb.UserID, allKey, "sandbox:active", eventsChannel(sb.UserID),
	}, sb.ID, js).Int()
	return n == 1, err
}

var reserveUserSlot = redis.NewScript(`
if not redis.call('SET', KEYS[1], ARGV[1], 'NX') then return 0 end
redis.call('SET', KEYS[2], ARGV[2])
redis.call('SADD', KEYS[3], ARGV[1])
redis.call('SADD', KEYS[4], ARGV[1])
redis.call('SADD', KEYS[5], ARGV[1])
redis.call('PUBLISH', KEYS[6], ARGV[2])
return 1`)

// UserSlot returns the current owner, including orphaned legacy reservations.
func (s *Store) UserSlot(ctx context.Context, userID string) (string, error) {
	id, err := s.rdb.Get(ctx, "sandbox:user-slot:"+userID).Result()
	if err == redis.Nil {
		return "", nil
	}
	return id, err
}

// ReleaseUserSlot frees the slot only if sandboxID still owns it (so a late
// cleanup can't clobber a slot a newer sandbox already took). Idempotent.
func (s *Store) ReleaseUserSlot(ctx context.Context, userID, sandboxID string) error {
	return relIfOwner.Run(ctx, s.rdb, []string{"sandbox:user-slot:" + userID}, sandboxID).Err()
}

func (s *Store) IncCreated(ctx context.Context) error {
	return s.rdb.Incr(ctx, "stats:sandbox:created").Err()
}

func (s *Store) TotalCreated(ctx context.Context) (int64, error) {
	n, err := s.rdb.Get(ctx, "stats:sandbox:created").Int64()
	if err == redis.Nil {
		return 0, nil
	}
	return n, err
}
