package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"github.com/todoforai/sandbox-manager/internal/api"
	"github.com/todoforai/sandbox-manager/internal/backend"
	"github.com/todoforai/sandbox-manager/internal/config"
	"github.com/todoforai/sandbox-manager/internal/service"
	"github.com/todoforai/sandbox-manager/internal/store"
	"github.com/todoforai/sandbox-manager/internal/userhome"
	"github.com/todoforai/sandbox-manager/internal/vm"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	st, err := store.New(cfg.DragonflyURL)
	if err != nil {
		log.Fatalf("redis: %v", err)
	}
	if err := st.Ping(context.Background()); err != nil {
		log.Fatalf("redis ping: %v", err)
	}

	mgr, err := vm.NewManager(cfg)
	if err != nil {
		log.Fatalf("vm manager: %v", err)
	}
	defer mgr.Close()

	homes := userhome.New(cfg.UserHomesDir)
	be := backend.New(cfg.BackendURL, cfg.BackendAPIKey)
	svc := service.New(cfg, st, mgr, homes, be)

	// Keep the Redis projection in sync with containerd lifecycle truth:
	// reconcile at startup and periodically thereafter (a VM can die while
	// we're up, leaving a stale 'running' record + held quota slot).
	go svc.ReconcileLoop(context.Background(), 30*time.Second)

	handler := api.NewServer(st, svc)
	log.Printf("sandbox-manager listening on %s (runtime=%s snapshotter=%s)",
		cfg.BindAddr, cfg.Runtime, cfg.Snapshotter)
	if err := http.ListenAndServe(cfg.BindAddr, handler); err != nil {
		log.Fatalf("http: %v", err)
	}
}
