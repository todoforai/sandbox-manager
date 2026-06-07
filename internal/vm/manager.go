package vm

import (
	"context"
	"fmt"
	"syscall"

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
	return &Manager{client: client, cfg: cfg, net: net}, nil
}

func (m *Manager) Close() error { return m.client.Close() }

// ctx scopes every containerd call to our namespace.
func (m *Manager) ctx(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, m.cfg.Namespace)
}

// Spec describes a microVM to create.
type Spec struct {
	ID          string
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

	image, err := m.client.Pull(ctx, m.cfg.RootfsImage, containerd.WithPullUnpack)
	if err != nil {
		return nil, fmt.Errorf("pull %s: %w", m.cfg.RootfsImage, err)
	}

	// The bridge is the image entrypoint; we only inject env + the home disk.
	//
	// TODO(host-verify): home.img is a raw ext4 *file*. Bind-mounting the file
	// to /root exposes the file, not its filesystem — this must instead attach
	// it as a virtio-blk device (mounted by the entrypoint) or loop-mount on
	// the host and bind the resulting dir. Needs a live Kata boot to settle the
	// exact mechanism; left as a bind for now so the shape is visible.
	mounts := []specs.Mount{}
	if s.HomeImg != "" {
		mounts = append(mounts, specs.Mount{
			Destination: "/root",
			Source:      s.HomeImg,
			Type:        "bind",
			Options:     []string{"rbind", "rw"},
		})
	}
	env := []string{"DEVICE_NAME=" + s.DeviceName}
	if s.EnrollToken != "" {
		env = append(env, "ENROLL_TOKEN="+s.EnrollToken)
	}

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
		containerd.WithNewSpec(
			oci.WithImageConfig(image),
			oci.WithEnv(env),
			oci.WithMounts(mounts),
			oci.WithHostname(s.DeviceName),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("new container: %w", err)
	}

	task, err := container.NewTask(ctx, cio.NullIO)
	if err != nil {
		container.Delete(ctx, containerd.WithSnapshotCleanup)
		return nil, fmt.Errorf("new task: %w", err)
	}

	ip, err := m.net.Attach(ctx, s.ID, int(task.Pid()))
	if err != nil {
		task.Delete(ctx, containerd.WithProcessKill)
		container.Delete(ctx, containerd.WithSnapshotCleanup)
		return nil, fmt.Errorf("cni attach: %w", err)
	}

	if err := task.Start(ctx); err != nil {
		m.net.Detach(ctx, s.ID, int(task.Pid()))
		task.Delete(ctx, containerd.WithProcessKill)
		container.Delete(ctx, containerd.WithSnapshotCleanup)
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
		m.net.Detach(ctx, id, int(task.Pid()))
		task.Kill(ctx, syscall.SIGKILL)
		task.Delete(ctx, containerd.WithProcessKill)
	}
	return container.Delete(ctx, containerd.WithSnapshotCleanup)
}
