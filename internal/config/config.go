package config

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// loadDotEnv reads KEY=VALUE lines from an env file into the process
// environment (without overriding values already set). Picks .env in
// production, else .env.development — matching the ecosystem convention. This
// lets the binary self-load its config when launched via `sudo <binary>`,
// which strips the parent environment.
func loadDotEnv() {
	name := ".env.development"
	if os.Getenv("NODE_ENV") == "production" {
		name = ".env"
	}
	f, err := os.Open(name)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if _, set := os.LookupEnv(k); !set {
			os.Setenv(k, strings.TrimSpace(v))
		}
	}
}

// Config is the full runtime configuration, all from env. No file, no flags —
// the spike script + deploy set these.
type Config struct {
	BindAddr      string // HTTP API bind, default 0.0.0.0:8200
	DragonflyURL  string // Redis/Dragonfly, identity + inventory (shared with backend)
	BackendURL    string // todofor.ai API base, for minting enroll tokens
	BackendAPIKey string // admin key for /admin/v1/enroll/mint

	// Noise backend the in-VM bridge enrolls against. Empty in prod so the
	// bridge uses its built-in prod default; set in dev to the host's CNI
	// gateway (10.88.0.1) so VMs enroll against the local backend.
	NoiseBackendHost string // NOISE_BACKEND_HOST injected into the VM (enrollment)
	NoiseBackendPort string // NOISE_BACKEND_PORT injected into the VM (enrollment)
	BridgePort       string // BRIDGE_PORT injected into the VM (daemon WS port)

	// containerd / Kata
	ContainerdSock string // default /run/containerd/containerd.sock
	Namespace      string // containerd namespace, default "sandbox"
	Runtime        string // default io.containerd.kata-fc.v2
	RuntimeConfig  string // Kata config TOML selecting the Firecracker VMM
	KataRuntimeBin string // kata-runtime binary (direct-volume add/remove)
	Snapshotter    string // default "devmapper"
	RootfsImage    string // OCI image whose entrypoint is todoforai-bridge

	// CNI
	CNIBinDir  string // default /opt/cni/bin
	CNIConfDir string // default /etc/cni/net.d

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
	loadDotEnv()
	c := &Config{
		BindAddr:         env("BIND_ADDR", "0.0.0.0:8200"),
		DragonflyURL:     os.Getenv("DRAGONFLY_URL"),
		BackendURL:       os.Getenv("BACKEND_URL"),
		BackendAPIKey:    os.Getenv("BACKEND_ADMIN_API_KEY"),
		NoiseBackendHost: os.Getenv("NOISE_BACKEND_HOST"),
		NoiseBackendPort: os.Getenv("NOISE_BACKEND_PORT"),
		BridgePort:       os.Getenv("BRIDGE_PORT"),
		ContainerdSock:   env("CONTAINERD_SOCK", "/run/containerd/containerd.sock"),
		Namespace:        env("CONTAINERD_NAMESPACE", "sandbox"),
		Runtime:          env("SANDBOX_RUNTIME", "io.containerd.kata-fc.v2"),
		RuntimeConfig:    env("SANDBOX_RUNTIME_CONFIG", "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"),
		KataRuntimeBin:   env("KATA_RUNTIME_BIN", "/opt/kata/bin/kata-runtime"),
		Snapshotter:      env("SANDBOX_SNAPSHOTTER", "devmapper"),
		RootfsImage:      env("SANDBOX_ROOTFS_IMAGE", "docker.io/todoforai/sandbox-rootfs:latest"),
		CNIBinDir:        env("CNI_BIN_DIR", "/opt/cni/bin"),
		CNIConfDir:       env("CNI_CONF_DIR", "/etc/cni/net.d"),
		UserHomesDir:     env("USER_HOMES_DIR", "/data/user-homes"),
		UserDiskSizeMiB:  20 * 1024,
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
