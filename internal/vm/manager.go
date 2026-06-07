package vm

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	runtimeoptions "github.com/containerd/containerd/api/types/runtimeoptions/v1"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	specs "github.com/opencontainers/runtime-spec/specs-go"

	"github.com/todoforai/sandbox-manager/internal/config"
)

// Manager is the entire VM lifecycle, delegated to containerd + Kata. This is
// what replaces the old firecracker.rs / network.rs / manager.rs reconcile:
// containerd owns the process, devmapper owns the rootfs, CNI owns networking.
type Manager struct {
	client *containerd.Client
	cfg    *config.Config
	net    *Network
	home   *homeDisk
}

func NewManager(cfg *config.Config) (*Manager, error) {
	client, err := containerd.New(cfg.ContainerdSock)
	if err != nil {
		return nil, fmt.Errorf("containerd connect: %w", err)
	}
	net, err := NewNetwork(cfg.CNIBinDir, cfg.CNIConfDir)
	if err != nil {
		return nil, fmt.Errorf("cni init: %w", err)
	}
	home := newHomeDisk(cfg.KataRuntimeBin, "/run/sandbox-manager/home-volumes")
	return &Manager{client: client, cfg: cfg, net: net, home: home}, nil
}

func (m *Manager) Close() error { return m.client.Close() }

// ctx scopes every containerd call to our namespace.
func (m *Manager) ctx(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, m.cfg.Namespace)
}

// Spec describes a microVM to create.
type Spec struct {
	ID          string
	UserID      string // owner — stamped as a container label for recovery
	Template    string // stamped as a container label
	Size        string // stamped as a container label
	EnrollToken string // injected as ENROLL_TOKEN env — bridge redeems it
	HomeImg     string // host path to the user's home.img (attached as /root)
	DeviceName  string // friendly bridge device name (vm-<id8>)
}

// Created reports the live network address of a started microVM.
type Created struct {
	IP string
}

// Create boots a microVM: pull rootfs, create the container with the Kata-fc
// runtime + devmapper snapshot, start the task, and wire CNI networking.
func (m *Manager) Create(ctx context.Context, s Spec) (*Created, error) {
	ctx = m.ctx(ctx)

	// Use the locally-present rootfs image if we already have it; only pull
	// when it's missing. Avoids a registry round-trip on every create and
	// supports locally-imported images (dev / air-gapped hosts).
	image, err := m.client.GetImage(ctx, m.cfg.RootfsImage)
	if err != nil {
		image, err = m.client.Pull(ctx, m.cfg.RootfsImage, containerd.WithPullUnpack)
		if err != nil {
			return nil, fmt.Errorf("pull %s: %w", m.cfg.RootfsImage, err)
		}
	}

	// The bridge is the image entrypoint; we only inject env + the home disk.
	// home.img attaches as a real block device via Kata direct-volume (see
	// homedisk.go) — the volume path is what we bind to /root, and Kata
	// hot-plugs the disk as virtio-blk so the guest mounts its ext4 there.
	// Proven live: read/write persists across VMs (sandbox migration).
	mounts := []specs.Mount{}
	if s.HomeImg != "" {
		volPath, err := m.home.Attach(s.ID, s.HomeImg)
		if err != nil {
			return nil, fmt.Errorf("attach home disk: %w", err)
		}
		mounts = append(mounts, specs.Mount{
			Destination: "/root",
			Source:      volPath,
			Type:        "bind",
			Options:     []string{"rbind", "rw"},
		})
	}
	// On any failure after this point, release the home disk before returning.
	detachHome := func() {
		if s.HomeImg != "" {
			m.home.Detach(s.ID)
		}
	}
	env := []string{"DEVICE_NAME=" + s.DeviceName}
	if s.EnrollToken != "" {
		env = append(env, "ENROLL_TOKEN="+s.EnrollToken)
	}

	// Networking FIRST: create the netns + run CNI in it, then boot the VM
	// inside that netns. Proven on the spike box — the reverse (CNI on the
	// VM's PID after boot) does NOT wire the guest. Kata's tcfilter model
	// redirects the CNI veth to the Firecracker TAP.
	nsPath, ip, err := m.net.Setup(ctx, s.ID)
	if err != nil {
		detachHome()
		return nil, fmt.Errorf("network setup: %w", err)
	}
	teardownNet := func() { m.net.Teardown(ctx, s.ID) }

	// Select the Firecracker VMM via the Kata config TOML. The containerd
	// client API (unlike CRI) ignores the ConfigPath in containerd's config,
	// so we pass it through the runtime options — without this the kata shim
	// falls back to its default (QEMU). Verified on the spike box: nil opts
	// boot QEMU, this boots firecracker.
	runtimeOpts := &runtimeoptions.Options{ConfigPath: m.cfg.RuntimeConfig}
	container, err := m.client.NewContainer(ctx, s.ID,
		containerd.WithImage(image),
		containerd.WithSnapshotter(m.cfg.Snapshotter),
		containerd.WithNewSnapshot(s.ID+"-snap", image),
		containerd.WithRuntime(m.cfg.Runtime, runtimeOpts),
		// Stamp ownership on the container so containerd is a recoverable
		// source of truth — reconcile can rebuild/validate Redis from these,
		// and orphans are discoverable even if Redis loses state.
		containerd.WithContainerLabels(map[string]string{
			"todoforai.sandbox":  "true",
			"todoforai.user_id":  s.UserID,
			"todoforai.template": s.Template,
			"todoforai.size":     s.Size,
		}),
		containerd.WithNewSpec(
			oci.WithImageConfig(image),
			oci.WithEnv(env),
			oci.WithMounts(mounts),
			oci.WithHostname(s.DeviceName),
			oci.WithLinuxNamespace(specs.LinuxNamespace{
				Type: specs.NetworkNamespace,
				Path: nsPath,
			}),
		),
	)
	if err != nil {
		teardownNet()
		detachHome()
		return nil, fmt.Errorf("new container: %w", err)
	}

	task, err := container.NewTask(ctx, cio.NullIO)
	if err != nil {
		container.Delete(ctx, containerd.WithSnapshotCleanup)
		teardownNet()
		detachHome()
		return nil, fmt.Errorf("new task: %w", err)
	}

	if err := task.Start(ctx); err != nil {
		task.Delete(ctx, containerd.WithProcessKill)
		container.Delete(ctx, containerd.WithSnapshotCleanup)
		teardownNet()
		detachHome()
		return nil, fmt.Errorf("task start: %w", err)
	}
	return &Created{IP: ip}, nil
}

// Exec runs argv inside a running microVM and returns combined output. This is
// the recovery-channel replacement (old SSH-CA + vsock) and the lite-style
// exec, unified into one containerd task.Exec.
func (m *Manager) Exec(ctx context.Context, id string, argv []string) ([]byte, error) {
	ctx = m.ctx(ctx)
	container, err := m.client.LoadContainer(ctx, id)
	if err != nil {
		return nil, err
	}
	task, err := container.Task(ctx, nil)
	if err != nil {
		return nil, err
	}
	if len(argv) == 0 {
		return nil, fmt.Errorf("exec: empty argv")
	}
	buf := &outputBuffer{}
	proc, err := task.Exec(ctx, "exec-"+randHex(6), &specs.Process{
		Args: argv,
		Cwd:  "/root",
		Env:  []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
	}, cio.NewCreator(cio.WithStreams(nil, buf, buf)))
	if err != nil {
		return nil, err
	}
	defer proc.Delete(ctx)
	statusC, err := proc.Wait(ctx)
	if err != nil {
		return nil, err
	}
	if err := proc.Start(ctx); err != nil {
		return nil, err
	}
	status := <-statusC
	out := buf.Bytes()
	if code := status.ExitCode(); code != 0 {
		return out, fmt.Errorf("exec exited %d", code)
	}
	return out, nil
}

// IsLive reports whether a sandbox still has a running task under containerd.
// Used by startup reconciliation to detect VMs that died while we were down.
func (m *Manager) IsLive(ctx context.Context, id string) bool {
	ctx = m.ctx(ctx)
	container, err := m.client.LoadContainer(ctx, id)
	if err != nil {
		return false
	}
	task, err := container.Task(ctx, nil)
	if err != nil {
		return false
	}
	st, err := task.Status(ctx)
	if err != nil {
		return false
	}
	return st.Status == containerd.Running
}

// Delete tears down a microVM: detach CNI, kill task, delete container + snapshot.
func (m *Manager) Delete(ctx context.Context, id string) error {
	ctx = m.ctx(ctx)
	container, err := m.client.LoadContainer(ctx, id)
	if err != nil {
		return nil // already gone
	}
	if task, err := container.Task(ctx, nil); err == nil {
		// Kill is async: set up the exit channel first, SIGKILL, then wait for
		// the task to actually exit before deleting it — otherwise Delete races
		// the still-"running" task and fails with "failed precondition".
		exitC, _ := task.Wait(ctx)
		task.Kill(ctx, syscall.SIGKILL)
		select {
		case <-exitC:
		case <-time.After(15 * time.Second):
		}
		task.Delete(ctx, containerd.WithProcessKill)
	}
	err = container.Delete(ctx, containerd.WithSnapshotCleanup)
	// This kata-fc version orphans the Firecracker VMM on task teardown: the
	// shim exits but firecracker reparents to init and lingers (verified — even
	// `ctr container delete` doesn't reap it). Kill it explicitly by its --id
	// (always the sandbox id). No-op if it already exited cleanly.
	killFirecracker(id)
	m.net.Teardown(ctx, id) // CNI remove + netns del (no-op if absent)
	m.home.Detach(id)       // release loop + direct-volume (no-op if no home disk)
	return err
}

// killFirecracker SIGKILLs the Firecracker VMM launched with `--id <id>`,
// found by scanning /proc (robust: no pattern self-match like pkill -f, which
// matches its own argv). No-op if it's already gone.
func killFirecracker(id string) {
	procs, _ := filepath.Glob("/proc/[0-9]*")
	for _, p := range procs {
		if comm, _ := os.ReadFile(p + "/comm"); strings.TrimSpace(string(comm)) != "firecracker" {
			continue
		}
		cmdline, _ := os.ReadFile(p + "/cmdline")
		if !strings.Contains(strings.ReplaceAll(string(cmdline), "\x00", " "), "--id "+id) {
			continue
		}
		if pid, err := strconv.Atoi(filepath.Base(p)); err == nil {
			syscall.Kill(pid, syscall.SIGKILL)
		}
	}
}
