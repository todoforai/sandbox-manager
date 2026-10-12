package store

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/alicebob/miniredis/v2"
	"testing"
)

func TestIsActive(t *testing.T) {
	cases := map[State]bool{
		StateCreating:    true,
		StateRunning:     true,
		StateTerminating: true, // must hold quota until the VM is actually gone
		StateError:       false,
	}
	for state, want := range cases {
		sb := &Sandbox{State: state}
		if got := sb.IsActive(); got != want {
			t.Errorf("IsActive(%s) = %v, want %v", state, got, want)
		}
	}
}

// The JSON field names are a wire contract with the backend's
// SandboxEventSubscriber — a rename breaks tier sync silently.
func TestSandboxWireFormat(t *testing.T) {
	sb := &Sandbox{
		ID: "i", UserID: "u", Template: "t", Size: "s", Kind: "vm",
		State: StateRunning, IPAddress: "10.88.0.2", CostPerMin: 0.005,
		Error: "e", DeviceID: "d", CreatedAt: 1, LastActivity: 2,
	}
	js, err := json.Marshal(sb)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(js, &m); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		"id", "user_id", "template", "size", "kind", "state", "ip_address",
		"cost_per_minute", "error", "device_id", "created_at", "last_activity",
	} {
		if _, ok := m[key]; !ok {
			t.Errorf("wire format missing %q (backend contract)", key)
		}
	}
}

// ssh_connections is live-only: omitted when zero, never part of a Put.
func TestSSHConnectionsOmitEmpty(t *testing.T) {
	js, _ := json.Marshal(&Sandbox{ID: "i"})
	var m map[string]any
	json.Unmarshal(js, &m)
	if _, ok := m["ssh_connections"]; ok {
		t.Error("ssh_connections must be omitted when zero")
	}
	js, _ = json.Marshal(&Sandbox{ID: "i", SSHConnections: 2})
	json.Unmarshal(js, &m)
	if m["ssh_connections"] != float64(2) {
		t.Errorf("ssh_connections = %v", m["ssh_connections"])
	}
}

func testStore(t *testing.T) *Store {
	t.Helper()
	server := miniredis.RunT(t)
	st, err := New("redis://" + server.Addr())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.rdb.Close() })
	return st
}

func TestReserveUserSlotPersistsRecordAtomically(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	sb := &Sandbox{ID: "first", UserID: "user", State: StateCreating}
	ok, err := st.ReserveUserSlot(ctx, sb)
	if err != nil || !ok {
		t.Fatalf("reserve: %v, %v", ok, err)
	}
	record, err := st.Get(ctx, sb.ID)
	if err != nil || record == nil || record.State != StateCreating {
		t.Fatalf("record: %+v, %v", record, err)
	}
	for _, key := range []string{"sandbox:user:user", allKey, "sandbox:active"} {
		if !st.rdb.SIsMember(ctx, key, sb.ID).Val() {
			t.Errorf("missing membership %s", key)
		}
	}
	ok, err = st.ReserveUserSlot(ctx, &Sandbox{ID: "second", UserID: sb.UserID, State: StateCreating})
	if err != nil || ok {
		t.Fatalf("second reserve: %v, %v", ok, err)
	}
	if st.rdb.Exists(ctx, "sandbox:second").Val() != 0 {
		t.Fatal("rejected create persisted a record")
	}
}

func TestDeleteReleasesOnlyOwnedSlot(t *testing.T) {
	for _, replaced := range []bool{false, true} {
		t.Run(fmt.Sprint(replaced), func(t *testing.T) {
			st := testStore(t)
			ctx := context.Background()
			sb := &Sandbox{ID: "old", UserID: "user", State: StateCreating}
			if ok, err := st.ReserveUserSlot(ctx, sb); err != nil || !ok {
				t.Fatal(ok, err)
			}
			if replaced {
				st.rdb.Set(ctx, "sandbox:user-slot:user", "new", 0)
			}
			if err := st.Delete(ctx, sb.ID); err != nil {
				t.Fatal(err)
			}
			slot, err := st.UserSlot(ctx, sb.UserID)
			if err != nil {
				t.Fatal(err)
			}
			want := ""
			if replaced {
				want = "new"
			}
			if slot != want {
				t.Fatalf("slot = %q, want %q", slot, want)
			}
			if st.rdb.Exists(ctx, "sandbox:old").Val() != 0 {
				t.Fatal("record remains")
			}
			for _, key := range []string{"sandbox:user:user", allKey, "sandbox:active"} {
				if st.rdb.SIsMember(ctx, key, sb.ID).Val() {
					t.Errorf("stale membership %s", key)
				}
			}
		})
	}
}

func TestPutRunningCannotUndoConcurrentDelete(t *testing.T) {
	for _, state := range []string{"creating", "terminating", "deleted", "replaced"} {
		t.Run(state, func(t *testing.T) {
			st := testStore(t)
			ctx := context.Background()
			sb := &Sandbox{ID: "boot", UserID: "user", State: StateCreating}
			if ok, err := st.ReserveUserSlot(ctx, sb); err != nil || !ok {
				t.Fatal(ok, err)
			}
			switch state {
			case "terminating":
				sb.State = StateTerminating
				if err := st.Put(ctx, sb); err != nil {
					t.Fatal(err)
				}
			case "deleted", "replaced":
				if err := st.Delete(ctx, sb.ID); err != nil {
					t.Fatal(err)
				}
				if state == "replaced" {
					if ok, err := st.ReserveUserSlot(ctx, &Sandbox{ID: "new", UserID: "user", State: StateCreating}); err != nil || !ok {
						t.Fatal(ok, err)
					}
				}
			}
			sb.State = StateRunning
			sb.SSHConnections = 2
			err := st.PutRunning(ctx, sb)
			if (err == nil) != (state == "creating") {
				t.Fatalf("PutRunning returned %v", err)
			}
			record, _ := st.Get(ctx, sb.ID)
			if state == "deleted" || state == "replaced" {
				if record != nil {
					t.Fatal("late boot recreated deleted record")
				}
			} else if state == "creating" && (record.State != StateRunning || record.SSHConnections != 0) {
				t.Fatalf("running record %+v", record)
			}
		})
	}
}
