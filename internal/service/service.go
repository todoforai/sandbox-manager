package service

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/todoforai/sandbox-manager/internal/backend"
	"github.com/todoforai/sandbox-manager/internal/config"
	"github.com/todoforai/sandbox-manager/internal/sandbox"
	"github.com/todoforai/sandbox-manager/internal/store"
	"github.com/todoforai/sandbox-manager/internal/userhome"
	"github.com/todoforai/sandbox-manager/internal/vm"
)

var (
	ErrQuota     = errors.New("user already has an active sandbox")
	ErrAnonymous = errors.New("anonymous users cannot create VM sandboxes")
	ErrNotFound  = errors.New("sandbox not found")
	ErrForbidden = errors.New("forbidden")
)

const enrollTTLSec = 300

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
func (s *Service) Create(ctx context.Context, id store.Identity, template, size string) (*sandbox.Sandbox, error) {
	if id.IsAnonymous {
		return nil, ErrAnonymous
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
		return nil, ErrQuota
	}
	release := func() { s.store.ReleaseUserSlot(ctx, id.UserID, sid) }

	homeImg, err := s.homes.EnsureDisk(id.UserID, s.cfg.UserDiskSizeMiB)
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

	sb := &sandbox.Sandbox{
		ID:           sid,
		UserID:       id.UserID,
		Template:     template,
		Size:         size,
		State:        sandbox.StateCreating,
		CostPerMin:   costPerMinute(size),
		CreatedAt:    sandbox.NowMillis(),
		LastActivity: sandbox.NowMillis(),
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
		sb.State = sandbox.StateError
		sb.Error = err.Error()
		s.store.Put(ctx, sb)
		release()
		return nil, err
	}

	sb.State = sandbox.StateRunning
	sb.IPAddress = created.IP
	sb.LastActivity = sandbox.NowMillis()
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

func (s *Service) Get(ctx context.Context, id store.Identity, sandboxID string) (*sandbox.Sandbox, error) {
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

func (s *Service) List(ctx context.Context, id store.Identity) ([]*sandbox.Sandbox, error) {
	if id.IsAdmin() {
		return s.store.List(ctx, "")
	}
	return s.store.List(ctx, id.UserID)
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
	sb.State = sandbox.StateTerminating
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
		if !sb.IsActive() {
			continue
		}
		if s.vm.IsLive(ctx, sb.ID) {
			continue
		}
		// Dead VM still marked active: clean up leftover container/netns/
		// direct-volume (best effort), mark error, free the quota slot.
		s.vm.Delete(ctx, sb.ID)
		sb.State = sandbox.StateError
		sb.Error = "vm not running at reconcile"
		s.store.Put(ctx, sb)
		s.store.ReleaseUserSlot(ctx, sb.UserID, sb.ID)
	}
	return nil
}

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
