package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/todoforai/sandbox-manager/internal/sandbox"
)

// Identity is the resolved caller. Mirrors the old Rust AuthIdentity.
type Identity struct {
	UserID      string
	Role        string // "admin" | "user"
	IsAnonymous bool
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
func (s *Store) Put(ctx context.Context, sb *sandbox.Sandbox) error {
	js, err := json.Marshal(sb)
	if err != nil {
		return err
	}
	pipe := s.rdb.TxPipeline()
	pipe.Set(ctx, "sandbox:"+sb.ID, js, 0)
	pipe.SAdd(ctx, "sandbox:user:"+sb.UserID, sb.ID)
	if sb.IsActive() {
		pipe.SAdd(ctx, "sandbox:active", sb.ID)
	} else {
		pipe.SRem(ctx, "sandbox:active", sb.ID)
	}
	pipe.Publish(ctx, eventsChannel(sb.UserID), js)
	_, err = pipe.Exec(ctx)
	return err
}

func (s *Store) Get(ctx context.Context, id string) (*sandbox.Sandbox, error) {
	js, err := s.rdb.Get(ctx, "sandbox:"+id).Bytes()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var sb sandbox.Sandbox
	if err := json.Unmarshal(js, &sb); err != nil {
		return nil, err
	}
	return &sb, nil
}

// Delete removes the record + set memberships and publishes a delete event.
func (s *Store) Delete(ctx context.Context, id string) error {
	sb, err := s.Get(ctx, id)
	if err != nil || sb == nil {
		return err
	}
	ev, _ := json.Marshal(map[string]any{"id": id, "user_id": sb.UserID, "deleted": true})
	pipe := s.rdb.TxPipeline()
	pipe.Del(ctx, "sandbox:"+id)
	pipe.SRem(ctx, "sandbox:active", id)
	pipe.SRem(ctx, "sandbox:user:"+sb.UserID, id)
	pipe.Publish(ctx, eventsChannel(sb.UserID), ev)
	_, err = pipe.Exec(ctx)
	return err
}

// List returns a user's sandboxes, or all sandboxes when userID == "" (admin).
func (s *Store) List(ctx context.Context, userID string) ([]*sandbox.Sandbox, error) {
	var ids []string
	if userID != "" {
		var err error
		if ids, err = s.rdb.SMembers(ctx, "sandbox:user:"+userID).Result(); err != nil {
			return nil, err
		}
	} else {
		keys, err := s.rdb.Keys(ctx, "sandbox:user:*").Result()
		if err != nil {
			return nil, err
		}
		seen := map[string]struct{}{}
		for _, k := range keys {
			members, _ := s.rdb.SMembers(ctx, k).Result()
			for _, m := range members {
				seen[m] = struct{}{}
			}
		}
		for id := range seen {
			ids = append(ids, id)
		}
	}
	out := make([]*sandbox.Sandbox, 0, len(ids))
	for _, id := range ids {
		if sb, err := s.Get(ctx, id); err == nil && sb != nil {
			out = append(out, sb)
		}
	}
	return out, nil
}

// ReserveUserSlot atomically claims the single sandbox slot for userID via
// SET NX, returning true if claimed. This is the enforcement point for
// one-sandbox-per-user: a concurrent create for the same user fails the NX.
// The slot is held until ReleaseUserSlot (on delete/error).
func (s *Store) ReserveUserSlot(ctx context.Context, userID, sandboxID string) (bool, error) {
	return s.rdb.SetNX(ctx, "sandbox:user-slot:"+userID, sandboxID, 0).Result()
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
