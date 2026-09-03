package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	ErrCapacity  = errors.New("host VM capacity reached")
)

const enrollTTLSec = 300

// maxDiskPercent is the data-filesystem usage at/above which Create is refused,
// leaving headroom so the host never fills (which corrupts home.img writes).
const maxDiskPercent = 90

// Service is the transport-agnostic business logic: auth/quota decisions,
// then delegate VM lifecycle to vm.Manager and persistence to store.Store.
type Service struct {
	cfg              *config.Config
	store            *store.Store
	vm               *vm.Manager
	homes            *userhome.Store
	backend          *backend.Client
	admissionMu      sync.Mutex // guards pendingCreates and the admission check
	pendingCreates   int        // admitted creates whose VM hasn't finished booting
	capacityRejected atomic.Uint64
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

	// Host-wide admission: the lock covers only the capacity check + pending
	// reservation, never the VM boot, so one slow/stuck create can't block
	// every other create. STOPPED-orphan cleanup runs in ReconcileLoop.
	release, err := s.admit(ctx)
	if err != nil {
		s.capacityRejected.Add(1)
		return nil, err
	}
	defer release()

	// Bound the whole boot so a wedged containerd/CNI/pull call can't pin the
	// pending slot (and a user's quota slot) forever. Comfortably above a
	// worst-case cold-pull create. Cleanup on the error paths must still run
	// after this deadline fires (or the client disconnects), so it gets its
	// own short context detached from the create's cancellation — otherwise a
	// timed-out create could fail to release the user's quota slot, leaking it
	// with no sandbox record for reconcile to find.
	ctx, cancel := context.WithTimeout(ctx, createTimeout)
	defer cancel()
	cleanupCtx := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	}
	if size == "" {
		size = "medium"
	}
	sid := newID()
	// `vm_` (not `vm-`): the device name doubles as a tool-call alias suffix
	// (`bash_<name>`) backend-side, so `_` keeps the displayed name identical
	// to the alias.
	deviceName := "vm_" + sid[:8]

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
	releaseSlot := func() {
		rctx, rcancel := cleanupCtx()
		defer rcancel()
		if err := s.store.ReleaseUserSlot(rctx, id.UserID, sid); err != nil {
			log.Printf("create %s: release user slot %s: %v", sid, id.UserID, err)
		}
	}

	homeImg, err := s.homes.EnsureDisk(id.UserID, diskSizeMiBForTier(size))
	if err != nil {
		releaseSlot()
		return nil, fmt.Errorf("ensure home disk: %w", err)
	}
	// NOTE: the token has a short TTL (enrollTTLSec) and is minted before
	// vm.Create — which includes the image pull. On a cold pull this can eat
	// into the redeem window; if that proves flaky in practice, pull/cache the
	// image before minting. Left simple until a live run shows it matters.
	token, err := s.backend.MintEnrollToken(ctx, id.UserID, sid, enrollTTLSec)
	if err != nil {
		releaseSlot()
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
		releaseSlot()
		return nil, err
	}

	created, err := s.vm.Create(ctx, vm.Spec{
		ID: sid, UserID: id.UserID, Template: template, Size: size,
		EnrollToken: token, HomeImg: homeImg, DeviceName: deviceName,
	})
	if err != nil {
		sb.State = store.StateError
		sb.Error = err.Error()
		rctx, rcancel := cleanupCtx()
		s.store.Put(rctx, sb)
		rcancel()
		releaseSlot()
		return nil, err
	}

	sb.State = store.StateRunning
	sb.IPAddress = created.IP
	sb.LastActivity = store.NowMillis()
	if err := s.store.Put(ctx, sb); err != nil {
		// We have a running VM we can't record — don't leak it. Tear it down
		// best-effort and free the slot, then surface the error. Teardown gets
		// a fresh context: the create's may already be expired here.
		rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), 60*time.Second)
		s.vm.Delete(rctx, sid)
		rcancel()
		releaseSlot()
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
// device_id also lets the backend find the VM that belongs to a device.
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

func (s *Service) Exec(ctx context.Context, id store.Identity, sandboxID string, argv []string) ([]byte, int, error) {
	if _, err := s.Get(ctx, id, sandboxID); err != nil {
		return nil, 0, err
	}
	return s.vm.Exec(ctx, sandboxID, argv)
}

// DeleteUserData permanently removes every sandbox and the persistent home.img
// for one user. The API exposes this only behind the admin role gate.
func (s *Service) DeleteUserData(ctx context.Context, id store.Identity, userID string) error {
	if !id.IsAdmin() {
		return ErrForbidden
	}
	all, err := s.store.ListByUserScan(ctx, userID)
	if err != nil {
		return err
	}
	for _, sb := range all {
		if err := s.Delete(ctx, id, sb.ID); err != nil && !errors.Is(err, ErrNotFound) {
			return err
		}
	}
	if err := s.store.PurgeUserIndexes(ctx, userID); err != nil {
		return err
	}
	return s.homes.Delete(userID)
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
	// The Device row is intentionally kept: the VM's machine-id persists on
	// the home.img, so the next boot re-enrolls as the SAME device (stable id
	// across stop→wake). Explicit device revocation is backend-initiated and
	// deletes the row there.
	if err := s.store.Delete(ctx, sandboxID); err != nil {
		return err
	}
	return s.store.ReleaseUserSlot(ctx, sb.UserID, sandboxID)
}

// staleDead reports whether an active sandbox record's VM is actually gone and
// the record is safe to reconcile. It honours the creating/terminating grace
// window so an in-flight create (VM not booted yet → IsLive LiveNo) or delete
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
	// Only a definitive "not found" counts as dead. LiveUnknown (containerd
	// unreachable, shim slow, manager mid-restart) must NOT authorize teardown
	// — treating it as dead would tear down a healthy VM on a transient blip.
	return s.vm.IsLive(ctx, sb.ID) == vm.LiveNo
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
// drift: an "active" record whose VM died while we were down is fully torn
// down and its quota slot released. Cheap — iterates only the active set.
func (s *Service) Reconcile(ctx context.Context) error {
	all, err := s.store.List(ctx, "")
	if err != nil {
		return err
	}
	for _, sb := range all {
		// GC error tombstones (failed creates, legacy records): keep them
		// visible briefly for debugging, then drop record + set membership.
		// They hold no VM resources and no quota slot, so plain Delete is
		// enough — without this they accumulate forever (one per failed
		// create) and bloat every List.
		if sb.State == store.StateError {
			if store.NowMillis()-sb.LastActivity > errorGCMillis {
				if err := s.store.Delete(ctx, sb.ID); err != nil {
					log.Printf("reconcile gc error record %s: %v", sb.ID, err)
				}
			}
			continue
		}
		// staleDead honours the creating/terminating grace window so an
		// in-flight Create (VM not booted yet) or Delete isn't torn down.
		if !s.staleDead(ctx, sb) {
			continue
		}
		// Dead VM still marked active: tear it down the same way Delete and
		// reconcileUserSlot do — kill leftover container/netns/direct-volume,
		// drop the record, free the slot. An "error" tombstone left in the
		// index instead would leak forever (one per dead VM), so keep the
		// three teardown paths identical. The Device row survives — the next
		// VM re-enrolls onto it via the persistent machine-id.
		s.vm.Delete(ctx, sb.ID)
		if err := s.store.Delete(ctx, sb.ID); err != nil {
			log.Printf("reconcile delete %s: %v", sb.ID, err)
			continue // keep the slot held rather than leak a stale record
		}
		if err := s.store.ReleaseUserSlot(ctx, sb.UserID, sb.ID); err != nil {
			log.Printf("reconcile release slot %s: %v", sb.UserID, err)
		}
	}
	return nil
}

// reconcileGraceMillis is how long a sandbox may sit in creating/terminating
// before reconcile assumes the operation crashed and cleans it up. Comfortably
// longer than a worst-case create (pull + boot).
const reconcileGraceMillis = 5 * 60 * 1000

// errorGCMillis is how long error tombstones stay around before reconcile
// garbage-collects them. Long enough to inspect a failed create; short enough
// that they don't pile up per user.
const errorGCMillis = 24 * 60 * 60 * 1000

// ReconcileLoop runs Reconcile on startup and then every interval until ctx is
// cancelled. containerd owns lifecycle truth; this keeps the Redis projection
// (state + quota slots) from drifting when a VM dies while we're running.
func (s *Service) ReconcileLoop(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		// Bound each pass so one wedged containerd call can't stall the loop
		// forever — the next tick gets a fresh timeout.
		tickCtx, cancel := context.WithTimeout(ctx, interval*2)
		if err := s.Reconcile(tickCtx); err != nil {
			log.Printf("reconcile: %v", err)
		}
		// Reap Redis-less STOPPED orphans (manager/OOM crash leftovers) so
		// their Firecracker VMMs free memory before the next admission check.
		if cleaned, err := s.vm.CleanupStopped(tickCtx); err != nil {
			log.Printf("cleanup stopped: %v", err)
		} else if cleaned > 0 {
			log.Printf("cleanup stopped: reaped %d orphan VMs", cleaned)
		}
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// createTimeout bounds one whole Create (pull + boot + CNI). On expiry the
// containerd/CNI calls abort, the error path runs, and the pending slot frees.
const createTimeout = 5 * time.Minute

// admissionTimeout bounds the capacity check itself, so a stalled containerd
// can't hold admissionMu (and with it every other create) indefinitely.
const admissionTimeout = 15 * time.Second

// admit reserves a pending-create slot iff running+pending VMs stay under
// MaxVMs and MemAvailable covers the reserve plus every in-flight VM. Fail
// closed: an unreadable count/meminfo rejects the create. The returned release
// MUST be called (success or failure) once the boot attempt is over.
func (s *Service) admit(ctx context.Context) (release func(), err error) {
	ctx, cancel := context.WithTimeout(ctx, admissionTimeout)
	defer cancel()
	s.admissionMu.Lock()
	defer s.admissionMu.Unlock()
	running, err := s.vm.RunningCount(ctx)
	if err != nil {
		return nil, fmt.Errorf("%w: count running VMs: %v", ErrCapacity, err)
	}
	if running+s.pendingCreates >= s.cfg.MaxVMs {
		return nil, fmt.Errorf("%w: %d running + %d pending of max %d", ErrCapacity, running, s.pendingCreates, s.cfg.MaxVMs)
	}
	availableMiB, err := memAvailableMiB("/proc/meminfo")
	if err != nil {
		return nil, fmt.Errorf("%w: read host memory: %v", ErrCapacity, err)
	}
	// Pending VMs haven't faulted their memory in yet, so MemAvailable doesn't
	// reflect them — budget each one at full size on top of the reserve.
	requiredMiB := s.cfg.HostMemoryReserveMiB + uint64(s.pendingCreates+1)*s.cfg.VMMemoryMiB
	if availableMiB < requiredMiB {
		return nil, fmt.Errorf("%w: %d MiB available, %d MiB required", ErrCapacity, availableMiB, requiredMiB)
	}
	s.pendingCreates++
	return func() {
		s.admissionMu.Lock()
		s.pendingCreates--
		s.admissionMu.Unlock()
	}, nil
}

func memAvailableMiB(path string) (uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "MemAvailable:" {
			kib, err := strconv.ParseUint(fields[1], 10, 64)
			if err != nil {
				return 0, err
			}
			return kib / 1024, nil
		}
	}
	return 0, errors.New("MemAvailable not found")
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
	running, err := s.vm.RunningCount(ctx)
	if err != nil {
		return nil, err
	}
	availableMiB, err := memAvailableMiB("/proc/meminfo")
	if err != nil {
		return nil, err
	}
	s.admissionMu.Lock()
	pending := s.pendingCreates
	s.admissionMu.Unlock()
	return map[string]any{
		"total_created":        total,
		"active":               active,
		"running_vms":          running,
		"pending_creates":      pending,
		"max_vms":              s.cfg.MaxVMs,
		"memory_available_mib": availableMiB,
		"memory_reserve_mib":   s.cfg.HostMemoryReserveMiB,
		"vm_memory_mib":        s.cfg.VMMemoryMiB,
		"capacity_rejected":    s.capacityRejected.Load(),
	}, nil
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
