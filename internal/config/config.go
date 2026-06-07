package config

import (
	"fmt"
	"os"
)

// Config is the full runtime configuration, all from env. No file, no flags —
// the spike script + deploy set these.
type Config struct {
	BindAddr        string // HTTP API bind, default 0.0.0.0:8200
	DragonflyURL    string // Redis/Dragonfly, identity + inventory (shared with backend)
	BackendURL      string // todofor.ai API base, for minting enroll tokens
	BackendAPIKey   string // admin key for /admin/v1/enroll/mint

	// containerd / Kata
	ContainerdSock  string // default /run/containerd/containerd.sock
	Namespace       string // containerd namespace, default "sandbox"
	Runtime         string // default io.containerd.kata-fc.v2
	Snapshotter     string // default "devmapper"
	RootfsImage     string // OCI image whose entrypoint is todoforai-bridge

	// CNI
	CNIBinDir       string // default /opt/cni/bin
	CNIConfDir      string // default /etc/cni/net.d

	// Per-user persistent home (home.img lives at <UserHomesDir>/<userId>/home.img)
	UserHomesDir    string
	UserDiskSizeMiB uint64 // ceiling for a freshly-created home.img
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// Load reads config from env, erroring only on the truly required values.
func Load() (*Config, error) {
	c := &Config{
		BindAddr:        env("BIND_ADDR", "0.0.0.0:8200"),
		DragonflyURL:    os.Getenv("DRAGONFLY_URL"),
		BackendURL:      os.Getenv("BACKEND_URL"),
		BackendAPIKey:   os.Getenv("BACKEND_ADMIN_API_KEY"),
		ContainerdSock:  env("CONTAINERD_SOCK", "/run/containerd/containerd.sock"),
		Namespace:       env("CONTAINERD_NAMESPACE", "sandbox"),
		Runtime:         env("SANDBOX_RUNTIME", "io.containerd.kata-fc.v2"),
		Snapshotter:     env("SANDBOX_SNAPSHOTTER", "devmapper"),
		RootfsImage:     env("SANDBOX_ROOTFS_IMAGE", "docker.io/todoforai/sandbox-rootfs:latest"),
		CNIBinDir:       env("CNI_BIN_DIR", "/opt/cni/bin"),
		CNIConfDir:      env("CNI_CONF_DIR", "/etc/cni/net.d"),
		UserHomesDir:    env("USER_HOMES_DIR", "/data/user-homes"),
		UserDiskSizeMiB: 20 * 1024,
	}
	for k, v := range map[string]string{
		"DRAGONFLY_URL":         c.DragonflyURL,
		"BACKEND_URL":           c.BackendURL,
		"BACKEND_ADMIN_API_KEY": c.BackendAPIKey,
	} {
		if v == "" {
			return nil, fmt.Errorf("%s is required", k)
		}
	}
	return c, nil
}
