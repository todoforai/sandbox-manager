package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"syscall"
	"time"

	"github.com/todoforai/sandbox-manager/internal/backend"
	"github.com/todoforai/sandbox-manager/internal/config"
	"github.com/todoforai/sandbox-manager/internal/store"
	"github.com/todoforai/sandbox-manager/internal/userhome"
	"github.com/todoforai/sandbox-manager/internal/vm"
)

var (
	ErrQuota     = errors.New("user already has an active sandbox")
	ErrAnonymous = errors.New("anonymous users cannot create VM sandboxes")
	ErrNotFound  = errors.New("sandbox not found")
	ErrForbidden = errors.New("forbidden")
	ErrDiskFull  = errors.New("host disk capacity reached")
)

const enrollTTLSec = 300

// maxDiskPercent is the data-filesystem usage at/above which Create is refused,
// leaving headroom so the host never fills (which corrupts home.img writes).
const maxDiskPercent = 90

// Service is the transport-agnostic business logic: auth/quota decisions,
// then delegate VM lifecycle to vm.Manager and persistence to store.Store.
type Service struct {
	cfg     *config.Config
	store   *store.Store
	vm      *vm.Manager
	homes   *userhome.Store
	backend *backend.Client
}

func New(cfg *config.Config, st *store.Store, mgr *vm.Manager, homes *userhome.Store, be *backend.Client) *Service {
	return &Service{cfg: cfg, store: st, vm: mgr, homes: homes, backend: be}
}

// Create enforces quota (one active sandbox per user) and anonymity, mints an
// enrollment token, ensures the user's home.img, boots the microVM, and
// records it. The whole flow is linear because containerd owns recovery.
func (s *Service) Create(ctx context.Context, id store.Identity, template, size string) (*store.Sandbox, error) {
	if id.IsAnonymous {
		return nil, ErrAnonymous
	}
	// Refuse new VMs once the data filesystem is ≥90% full, so provisioning
	// stops before the host fills (a full disk corrupts in-flight home.img
	// writes and wedges every VM). Fail closed — a safety cap that can't read
	// the disk shouldn't wave creates through. Checked before reserving the
	// slot so a rejected create leaves no state behind.
	if used, err := diskUsagePercent(s.cfg.UserHomesDir); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrDiskFull, err)
	} else if used >= maxDiskPercent {
		return nil, fmt.Errorf("%w: %d%% used", ErrDiskFull, used)
	}
	if size == "" {
		size = "medium"
	}
	sid := newID()
	deviceName := "vm-" + sid[:8]

	// Atomic one-per-user gate. If the user already holds the slot, reject
	// before doing any expensive work. Released on every failure path below
	// and on delete.
	ok, err := s.store.ReserveUserSlot(ctx, id.UserID, sid)
	if err != nil {
		return nil, err
	}
	if !ok {
		// Slot is held. Self-heal the common "Recover hosted desktop" case:
		// the holder may be a dead sandbox (VM died, reconcile hasn't run, or
		// it's stuck in creating/terminating) — a real quota only counts a
		// LIVE VM. Reconcile any non-live holders (delete + release), then
		// retry the reservation once. Only a genuinely live VM yields ErrQuota.
		s.reconcileUserSlot(ctx, id.UserID)
		if ok, err = s.store.ReserveUserSlot(ctx, id.UserID, sid); err != nil {
			return nil, err
		}
		if !ok {
			return nil, ErrQuota
		}
	}
	release := func() { s.store.ReleaseUserSlot(ctx, id.UserID, sid) }

	homeImg, err := s.homes.EnsureDisk(id.UserID, diskSizeMiBForTier(size))
	if err != nil {
		release()
		return nil, fmt.Errorf("ensure home disk: %w", err)
	}
	// NOTE: the token has a short TTL (enrollTTLSec) and is minted before
	// vm.Create — which includes the image pull. On a cold pull this can eat
	// into the redeem window; if that proves flaky in practice, pull/cache the
	// image before minting. Left simple until a live run shows it matters.
	token, err := s.backend.MintEnrollToken(ctx, id.UserID, sid, enrollTTLSec)
	if err != nil {
		release()
		return nil, fmt.Errorf("mint enroll token: %w", err)
	}

	sb := &store.Sandbox{
		ID:           sid,
		UserID:       id.UserID,
		Template:     template,
		Size:         size,
		Kind:         "vm",
		State:        store.StateCreating,
		CostPerMin:   costPerMinute(size),
		CreatedAt:    store.NowMillis(),
		LastActivity: store.NowMillis(),
	}
	if err := s.store.Put(ctx, sb); err != nil {
		release()
		return nil, err
	}

	created, err := s.vm.Create(ctx, vm.Spec{
		ID: sid, UserID: id.UserID, Template: template, Size: size,
		EnrollToken: token, HomeImg: homeImg, DeviceName: deviceName,
	})
	if err != nil {
		sb.State = store.StateError
		sb.Error = err.Error()
		s.store.Put(ctx, sb)
		release()
		return nil, err
	}

	sb.State = store.StateRunning
	sb.IPAddress = created.IP
	sb.LastActivity = store.NowMillis()
	if err := s.store.Put(ctx, sb); err != nil {
		// We have a running VM we can't record — don't leak it. Tear it down
		// best-effort and free the slot, then surface the error.
		s.vm.Delete(ctx, sid)
		release()
		return nil, fmt.Errorf("persist running sandbox: %w", err)
	}
	s.store.IncCreated(ctx)
	return sb, nil
}

func (s *Service) Get(ctx context.Context, id store.Identity, sandboxID string) (*store.Sandbox, error) {
	sb, err := s.store.Get(ctx, sandboxID)
	if err != nil {
		return nil, err
	}
	if sb == nil {
		return nil, ErrNotFound
	}
	if !id.IsAdmin() && sb.UserID != id.UserID {
		return nil, ErrForbidden
	}
	return sb, nil
}

// AttachDevice records the bridge's enrolled device on the sandbox. Called by
// the backend (admin) right after a successful enroll redeem; persisting via
// store.Put republishes the record on sandbox:events:<userId> so the backend's
// SandboxEventSubscriber can promote the device to the user's primary. The
// device_id is also what Delete uses to cascade the Device row cleanup.
func (s *Service) AttachDevice(ctx context.Context, id store.Identity, sandboxID, deviceID string) error {
	if !id.IsAdmin() {
		return ErrForbidden
	}
	sb, err := s.store.Get(ctx, sandboxID)
	if err != nil {
		return err
	}
	if sb == nil {
		return ErrNotFound
	}
	sb.DeviceID = deviceID
	sb.LastActivity = store.NowMillis()
	return s.store.Put(ctx, sb)
}

func (s *Service) List(ctx context.Context, id store.Identity) ([]*store.Sandbox, error) {
	userID := id.UserID
	if id.IsAdmin() {
		userID = id.ScopeUserID // "" = all users
	}
	list, err := s.store.List(ctx, userID)
	if err != nil {
		return nil, err
	}
	// Reflect VM liveness in the reported state: a record may say running/
	// creating while its VM has actually died (reconcile hasn't run yet). The
	// backend's tier sync keys off state to decide "is my cloud alive?", so a
	// stale "running" makes it no-op instead of recovering. Surface dead VMs as
	// error here (read-only — teardown stays in Reconcile/reconcileUserSlot) so
	// the backend re-creates and Create heals the held slot. Copy-on-mutate so
	// we never touch the store's own object.
	for i, sb := range list {
		if s.staleDead(ctx, sb) {
			cp := *sb
			cp.State = store.StateError
			list[i] = &cp
		}
	}
	return list, nil
}

func (s *Service) Exec(ctx context.Context, id store.Identity, sandboxID string, argv []string) ([]byte, error) {
	if _, err := s.Get(ctx, id, sandboxID); err != nil {
		return nil, err
	}
	return s.vm.Exec(ctx, sandboxID, argv)
}

func (s *Service) Delete(ctx context.Context, id store.Identity, sandboxID string) error {
	sb, err := s.Get(ctx, id, sandboxID)
	if err != nil {
		return err
	}
	// Mark terminating (still counts as active, so quota stays held) and only
	// free the record + slot AFTER the VM is actually gone. If vm.Delete
	// fails, the sandbox stays terminating/active — the user can't create
	// another while a VM may still be running.
	sb.State = store.StateTerminating
	sb.LastActivity = store.NowMillis() // refresh so the grace window covers this delete
	s.store.Put(ctx, sb)

	if err := s.vm.Delete(ctx, sandboxID); err != nil {
		return err
	}
	if sb.DeviceID != "" {
		s.backend.DeleteDevice(ctx, sb.UserID, sb.DeviceID)
	}
	if err := s.store.Delete(ctx, sandboxID); err != nil {
		return err
	}
	return s.store.ReleaseUserSlot(ctx, sb.UserID, sandboxID)
}

// staleDead reports whether an active sandbox record's VM is actually gone and
// the record is safe to reconcile. It honours the creating/terminating grace
// window so an in-flight create (VM not booted yet → IsLive false) or delete
// isn't torn down out from under itself. Shared by List (read-only state fix),
// reconcileUserSlot, and Reconcile so they agree on "dead".
func (s *Service) staleDead(ctx context.Context, sb *store.Sandbox) bool {
	if !sb.IsActive() {
		return false
	}
	if sb.State == store.StateCreating || sb.State == store.StateTerminating {
		if store.NowMillis()-sb.LastActivity < reconcileGraceMillis {
			return false
		}
	}
	return !s.vm.IsLive(ctx, sb.ID)
}

// reconcileUserSlot heals a single user's sandbox slot on the create/recover
// path: any of their active sandboxes whose VM is dead (staleDead) is torn down
// and its quota slot deleted, so a retry of ReserveUserSlot can succeed. The
// grace window in staleDead protects a concurrent in-flight create whose VM
// hasn't booted yet.
func (s *Service) reconcileUserSlot(ctx context.Context, userID string) {
	all, err := s.store.List(ctx, userID)
	if err != nil {
		log.Printf("reconcileUserSlot list %s: %v", userID, err)
		return
	}
	for _, sb := range all {
		if !s.staleDead(ctx, sb) {
			continue
		}
		s.vm.Delete(ctx, sb.ID)
		if sb.DeviceID != "" {
			s.backend.DeleteDevice(ctx, sb.UserID, sb.DeviceID)
		}
		if err := s.store.Delete(ctx, sb.ID); err != nil {
			log.Printf("reconcileUserSlot delete %s: %v", sb.ID, err)
			continue // keep the slot held rather than leak a stale record
		}
		if err := s.store.ReleaseUserSlot(ctx, sb.UserID, sb.ID); err != nil {
			log.Printf("reconcileUserSlot release slot %s: %v", sb.UserID, err)
		}
	}
}

// Reconcile re-syncs persisted state against containerd reality at startup.
// containerd owns process liveness across our restarts; this just catches the
// drift: an "active" record whose VM died while we were down is marked error
// and its quota slot released. Cheap — iterates only the active set.
func (s *Service) Reconcile(ctx context.Context) error {
	all, err := s.store.List(ctx, "")
	if err != nil {
		return err
	}
	for _, sb := range all {
		// staleDead honours the creating/terminating grace window so an
		// in-flight Create (VM not booted yet) or Delete isn't torn down.
		if !s.staleDead(ctx, sb) {
			continue
		}
		// Dead VM still marked active: clean up leftover container/netns/
		// direct-volume (best effort), mark error, free the quota slot.
		s.vm.Delete(ctx, sb.ID)
		sb.State = store.StateError
		sb.Error = "vm not running at reconcile"
		s.store.Put(ctx, sb)
		s.store.ReleaseUserSlot(ctx, sb.UserID, sb.ID)
	}
	return nil
}

// reconcileGraceMillis is how long a sandbox may sit in creating/terminating
// before reconcile assumes the operation crashed and cleans it up. Comfortably
// longer than a worst-case create (pull + boot).
const reconcileGraceMillis = 5 * 60 * 1000

// ReconcileLoop runs Reconcile on startup and then every interval until ctx is
// cancelled. containerd owns lifecycle truth; this keeps the Redis projection
// (state + quota slots) from drifting when a VM dies while we're running.
func (s *Service) ReconcileLoop(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if err := s.Reconcile(ctx); err != nil {
			log.Printf("reconcile: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Service) Stats(ctx context.Context) (map[string]any, error) {
	total, err := s.store.TotalCreated(ctx)
	if err != nil {
		return nil, err
	}
	all, err := s.store.List(ctx, "")
	if err != nil {
		return nil, err
	}
	active := 0
	for _, sb := range all {
		if sb.IsActive() {
			active++
		}
	}
	return map[string]any{"total_created": total, "active": active}, nil
}

// VM tier pricing (USD/min), ported from the old vm/size.rs. Lite is gone.
func costPerMinute(size string) float64 {
	switch size {
	case "small":
		return 0.0025
	case "medium":
		return 0.005
	case "large":
		return 0.01
	case "xlarge":
		return 0.02
	default:
		return 0.005
	}
}

// VM tier persistent-home size (MiB). The home.img is sparse, so this is a
// ceiling/quota — a fresh disk costs ~nothing on host storage until filled.
// Never shrinks an existing disk (EnsureDisk leaves an existing image as-is).
func diskSizeMiBForTier(size string) uint64 {
	switch size {
	case "small":
		return 500
	case "medium":
		return 2 * 1024
	case "large":
		return 8 * 1024
	case "xlarge":
		return 20 * 1024
	default:
		return 2 * 1024
	}
}

func newID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// diskUsagePercent returns the used percentage (0–100) of the filesystem
// containing path, rounded up so we trip the cap a hair early rather than late.
// Uses available-to-unprivileged blocks (Bavail) for "free" — matching what df
// reports and what actually constrains writes once reserved blocks kick in.
func diskUsagePercent(path string) (int, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, err
	}
	total := st.Blocks
	if total == 0 {
		return 0, fmt.Errorf("statfs reported zero blocks for %s", path)
	}
	used := st.Blocks - st.Bavail
	return int((used*100 + total - 1) / total), nil
}
