package service

import (
	"context"
	"errors"
	"fmt"

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
	n, err := s.store.UserActiveCount(ctx, id.UserID)
	if err != nil {
		return nil, err
	}
	if n > 0 {
		return nil, ErrQuota
	}

	sid := newID()
	deviceName := "vm-" + sid[:8]
	if size == "" {
		size = "medium"
	}

	homeImg, err := s.homes.EnsureDisk(id.UserID, s.cfg.UserDiskSizeMiB)
	if err != nil {
		return nil, fmt.Errorf("ensure home disk: %w", err)
	}
	token, err := s.backend.MintEnrollToken(ctx, id.UserID, sid, enrollTTLSec)
	if err != nil {
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
		return nil, err
	}

	created, err := s.vm.Create(ctx, vm.Spec{
		ID: sid, EnrollToken: token, HomeImg: homeImg, DeviceName: deviceName,
	})
	if err != nil {
		sb.State = sandbox.StateError
		sb.Error = err.Error()
		s.store.Put(ctx, sb)
		return nil, err
	}

	sb.State = sandbox.StateRunning
	sb.IPAddress = created.IP
	sb.LastActivity = sandbox.NowMillis()
	if err := s.store.Put(ctx, sb); err != nil {
		return nil, err
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
	sb.State = sandbox.StateTerminating
	s.store.Put(ctx, sb)

	if err := s.vm.Delete(ctx, sandboxID); err != nil {
		return err
	}
	if sb.DeviceID != "" {
		s.backend.DeleteDevice(ctx, sb.UserID, sb.DeviceID)
	}
	return s.store.Delete(ctx, sandboxID)
}

func (s *Service) Stats(ctx context.Context) (map[string]any, error) {
	total, _ := s.store.TotalCreated(ctx)
	all, _ := s.store.List(ctx, "")
	active := 0
	for _, sb := range all {
		if sb.IsActive() {
			active++
		}
	}
	return map[string]any{"total_created": total, "active": active}, nil
}
