package service

import (
	"context"
	"errors"
	"fmt"
	"github.com/alicebob/miniredis/v2"
	"github.com/todoforai/sandbox-manager/internal/store"
	"github.com/todoforai/sandbox-manager/internal/vm"
	"os"
	"testing"
)

func TestCostPerMinute(t *testing.T) {
	cases := map[string]float64{
		"small": 0.0025, "medium": 0.005, "large": 0.01, "xlarge": 0.02,
		"": 0.005, "bogus": 0.005, // unknown tiers fall back to medium
	}
	for size, want := range cases {
		if got := costPerMinute(size); got != want {
			t.Errorf("costPerMinute(%q) = %v, want %v", size, got, want)
		}
	}
}

func TestDiskSizeMiBForTier(t *testing.T) {
	cases := map[string]uint64{
		"small": 500, "medium": 2048, "large": 8192, "xlarge": 20480,
		"": 2048, "bogus": 2048,
	}
	for size, want := range cases {
		if got := diskSizeMiBForTier(size); got != want {
			t.Errorf("diskSizeMiBForTier(%q) = %v, want %v", size, got, want)
		}
	}
}

func TestDiskUsagePercent(t *testing.T) {
	got, err := diskUsagePercent(t.TempDir())
	if err != nil {
		t.Fatalf("diskUsagePercent: %v", err)
	}
	if got < 0 || got > 100 {
		t.Errorf("diskUsagePercent = %d, want 0..100", got)
	}
	if _, err := diskUsagePercent("/nonexistent-path-xyz"); err == nil {
		t.Error("diskUsagePercent on missing path: want error, got nil")
	}
}

func TestMemAvailableMiB(t *testing.T) {
	path := t.TempDir() + "/meminfo"
	if err := os.WriteFile(path, []byte("MemTotal: 131072000 kB\nMemAvailable: 25165824 kB\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := memAvailableMiB(path)
	if err != nil {
		t.Fatal(err)
	}
	if got != 24576 {
		t.Fatalf("got %d MiB, want 24576", got)
	}

	if err := os.WriteFile(path, []byte("MemTotal: 1 kB\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := memAvailableMiB(path); err == nil {
		t.Fatal("missing MemAvailable should fail")
	}
}

func TestNewID(t *testing.T) {
	a, b := newID(), newID()
	if len(a) != 32 {
		t.Errorf("newID length = %d, want 32", len(a))
	}
	if a == b {
		t.Error("newID returned duplicates")
	}
}

type recoveryVM struct {
	vmManager
	live     vm.Liveness
	deleted  []string
	deleteFn func() error
}

func (m *recoveryVM) IsLive(context.Context, string) vm.Liveness { return m.live }
func (m *recoveryVM) GuestLogTail(string, int) string            { return "" }
func (m *recoveryVM) Delete(_ context.Context, id string) error {
	m.deleted = append(m.deleted, id)
	if m.deleteFn != nil {
		return m.deleteFn()
	}
	return nil
}

func recoveryService(t *testing.T) (*Service, *miniredis.Miniredis, *recoveryVM) {
	t.Helper()
	redis := miniredis.RunT(t)
	st, err := store.New("redis://" + redis.Addr())
	if err != nil {
		t.Fatal(err)
	}
	mgr := &recoveryVM{live: vm.LiveNo}
	return &Service{store: st, vm: mgr}, redis, mgr
}

func reserveRecoverySandbox(t *testing.T, s *Service, state store.State, age int64) *store.Sandbox {
	t.Helper()
	sb := &store.Sandbox{ID: "sandbox", UserID: "user", State: store.StateCreating, LastActivity: store.NowMillis() - age}
	if ok, err := s.store.ReserveUserSlot(context.Background(), sb); err != nil || !ok {
		t.Fatal(ok, err)
	}
	sb.State = state
	if err := s.store.Put(context.Background(), sb); err != nil {
		t.Fatal(err)
	}
	return sb
}

func TestTeardownSurvivesExpiredCallerContext(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprint(explicit), func(t *testing.T) {
			s, _, mgr := recoveryService(t)
			sb := reserveRecoverySandbox(t, s, store.StateRunning, 0)
			ctx, cancel := context.WithCancel(context.Background())
			mgr.deleteFn = func() error { cancel(); return nil }
			if explicit {
				if err := s.Delete(ctx, store.Identity{Role: "admin"}, sb.ID); err != nil {
					t.Fatal(err)
				}
			} else {
				s.teardownDead(ctx, sb, "test")
			}
			slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
			record, _ := s.store.Get(context.Background(), sb.ID)
			if slot != "" || record != nil {
				t.Fatalf("expired cleanup left slot %q, record %+v", slot, record)
			}
		})
	}
}

func TestRecoverInterruptedTeardown(t *testing.T) {
	s, _, mgr := recoveryService(t)
	sb := reserveRecoverySandbox(t, s, store.StateError, 0)
	s.reconcileUserSlot(context.Background(), sb.UserID)
	slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
	record, _ := s.store.Get(context.Background(), sb.ID)
	if slot != "" || record != nil || len(mgr.deleted) != 1 {
		t.Fatalf("recovery left slot %q, record %+v", slot, record)
	}
}

func TestRecoverMissingRecord(t *testing.T) {
	for _, live := range []vm.Liveness{vm.LiveNo, vm.LiveYes, vm.LiveUnknown} {
		t.Run(fmt.Sprint(live), func(t *testing.T) {
			s, redis, mgr := recoveryService(t)
			redis.Set("sandbox:user-slot:user", "legacy")
			mgr.live = live
			s.reconcileUserSlot(context.Background(), "user")
			slot, _ := s.store.UserSlot(context.Background(), "user")
			if live == vm.LiveNo {
				if slot != "" || len(mgr.deleted) != 1 {
					t.Fatalf("orphan not cleaned: slot %q, deleted %v", slot, mgr.deleted)
				}
			} else if slot != "legacy" || len(mgr.deleted) != 0 {
				t.Fatal("live/unknown holder was cleaned")
			}
		})
	}
}

func TestRecoverPreservesActiveCreateAndLiveVM(t *testing.T) {
	for _, state := range []store.State{store.StateCreating, store.StateRunning, store.StateTerminating} {
		t.Run(string(state), func(t *testing.T) {
			s, _, mgr := recoveryService(t)
			sb := reserveRecoverySandbox(t, s, state, 0)
			if state == store.StateRunning {
				mgr.live = vm.LiveYes
			}
			s.reconcileUserSlot(context.Background(), sb.UserID)
			slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
			if slot != sb.ID || len(mgr.deleted) != 0 {
				t.Fatal("active holder was cleaned")
			}
		})
	}
}

func TestReconcileErrorSlotsAndGarbageCollection(t *testing.T) {
	for _, tc := range []struct {
		name        string
		age         int64
		replacement bool
		deleteErr   error
		wantRecord  bool
		wantSlot    string
	}{
		{name: "held error", wantSlot: ""},
		{name: "failed cleanup", deleteErr: errors.New("containerd unavailable"), wantRecord: true, wantSlot: "sandbox"},
		{name: "old unheld error", age: errorGCMillis + 1, replacement: true, wantSlot: "new"},
		{name: "recent unheld error", replacement: true, wantRecord: true, wantSlot: "new"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, redis, mgr := recoveryService(t)
			sb := reserveRecoverySandbox(t, s, store.StateError, tc.age)
			if tc.replacement {
				redis.Set("sandbox:user-slot:user", "new")
			}
			if tc.deleteErr != nil {
				mgr.live = vm.LiveUnknown
			}
			mgr.deleteFn = func() error { return tc.deleteErr }
			if err := s.Reconcile(context.Background()); err != nil {
				t.Fatal(err)
			}
			slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
			record, _ := s.store.Get(context.Background(), sb.ID)
			if slot != tc.wantSlot || (record != nil) != tc.wantRecord {
				t.Fatalf("slot %q record %+v", slot, record)
			}
		})
	}
}

func TestCleanupFailureOnlyBlocksPossiblyLiveVM(t *testing.T) {
	for _, live := range []vm.Liveness{vm.LiveNo, vm.LiveYes, vm.LiveUnknown} {
		t.Run(fmt.Sprint(live), func(t *testing.T) {
			s, _, mgr := recoveryService(t)
			sb := reserveRecoverySandbox(t, s, store.StateError, 0)
			mgr.live = live
			mgr.deleteFn = func() error { return errors.New("snapshot busy") }
			s.reconcileUserSlot(context.Background(), sb.UserID)
			slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
			if live == vm.LiveNo && slot != "" {
				t.Fatalf("dead VM holds slot %q", slot)
			}
			if live != vm.LiveNo && slot != sb.ID {
				t.Fatal("possibly live VM lost its slot")
			}
		})
	}
}

func TestErrorGarbageCollectionDoesNotDeleteVMOrReuseSlot(t *testing.T) {
	s, redis, mgr := recoveryService(t)
	sb := reserveRecoverySandbox(t, s, store.StateError, errorGCMillis+1)
	redis.Set("sandbox:user-slot:user", "new")
	mgr.deleteFn = func() error { t.Fatal("unheld error GC must not call containerd"); return nil }
	if err := s.Reconcile(context.Background()); err != nil {
		t.Fatal(err)
	}
	slot, _ := s.store.UserSlot(context.Background(), sb.UserID)
	record, _ := s.store.Get(context.Background(), sb.ID)
	if slot != "new" || record != nil {
		t.Fatalf("GC left slot %q record %+v", slot, record)
	}
}
