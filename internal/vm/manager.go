package vm

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	runtimeoptions "github.com/containerd/containerd/api/types/runtimeoptions/v1"
	containerd "github.com/containerd/containerd/v2/client"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	gocni "github.com/containerd/go-cni"
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
	m := &Manager{client: client, cfg: cfg, net: net, home: home}
	// Fail loud at startup if the rootfs snapshotter isn't loaded, instead of
	// serving HTTP "healthy" and 500ing on the first createSandbox. The usual
	// cause is the loopback devmapper thin-pool missing after a reboot — see
	// scripts/sandbox-pool-up.sh (the boot-time restore unit). Retry briefly so
	// a manager started a hair before containerd finished loading its plugins
	// (PM2 has no ordering guarantee vs containerd) waits it out instead of
	// crash-looping on a transient.
	var lastErr error
	for i := 0; i < 10; i++ {
		if lastErr = m.checkSnapshotter(context.Background()); lastErr == nil {
			break
		}
		if i < 9 {
			time.Sleep(time.Second)
		}
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return m, nil
}

// checkSnapshotter probes the configured snapshotter so a broken one surfaces
// at boot. A *loaded* snapshotter returns NotFound for the empty key — that's
// the one success case. Any other error (snapshotter not loaded, socket down,
// permission denied, namespace issues) is fatal: better a crash-loop that names
// the cause than a "healthy" process that 500s on the first createSandbox. The
// usual culprit is the devmapper thin-pool missing after a reboot.
func (m *Manager) checkSnapshotter(ctx context.Context) error {
	_, err := m.client.SnapshotService(m.cfg.Snapshotter).Stat(m.ctx(ctx), "")
	if err == nil || errdefs.IsNotFound(err) {
		return nil
	}
	hint := ""
	if strings.Contains(err.Error(), "snapshotter not loaded") {
		hint = " — devmapper thin-pool likely missing after reboot; run scripts/sandbox-pool-up.sh and restart containerd"
	}
	return fmt.Errorf("snapshotter %q unavailable: %w%s", m.cfg.Snapshotter, err, hint)
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

	// A locally-imported image keeps its content+manifest across reboots, but
	// its devmapper snapshot chain does not survive (loop-backed pool). Without
	// the unpacked layers, NewContainer fails with "parent snapshot ... does
	// not exist". Unpack on demand so the first create after a reboot heals it.
	if unpacked, uerr := image.IsUnpacked(ctx, m.cfg.Snapshotter); uerr != nil {
		return nil, fmt.Errorf("check unpacked %s: %w", m.cfg.RootfsImage, uerr)
	} else if !unpacked {
		if uerr := image.Unpack(ctx, m.cfg.Snapshotter); uerr != nil {
			return nil, fmt.Errorf("unpack %s into %s: %w", m.cfg.RootfsImage, m.cfg.Snapshotter, uerr)
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
	// Tell the in-VM bridge which Noise backend to enroll against. Unset in
	// prod (bridge uses its built-in default); set in dev to the host's CNI
	// gateway so the VM redeems against the local backend, not prod.
	if m.cfg.NoiseBackendHost != "" {
		env = append(env, "NOISE_BACKEND_HOST="+m.cfg.NoiseBackendHost)
	}
	if m.cfg.NoiseBackendPort != "" {
		env = append(env, "NOISE_BACKEND_PORT="+m.cfg.NoiseBackendPort)
	}
	// The daemon's WS port defaults to 80 for any non-localhost host, but the
	// dev backend serves WS on 4000. NOISE_BACKEND_HOST=10.88.0.1 is not
	// recognized as localhost, so without this the daemon hits :80 → 404 and
	// the device never comes online. Unset in prod (bridge default :80 is right).
	if m.cfg.BridgePort != "" {
		env = append(env, "BRIDGE_PORT="+m.cfg.BridgePort)
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

// Delete tears down a microVM: kill task, delete container + snapshot, then
// reap the orphaned VMM, CNI and home disk. The host-side cleanup (firecracker/
// netns/loop) runs UNCONDITIONALLY — even when the container is already gone —
// so a retry or reconcile after a partial/crashed delete still leaves no
// residue.
func (m *Manager) Delete(ctx context.Context, id string) error {
	ctx = m.ctx(ctx)
	var err error
	if container, lerr := m.client.LoadContainer(ctx, id); lerr == nil {
		if task, terr := container.Task(ctx, nil); terr == nil {
			// Kill is async: set up the exit channel first, SIGKILL, then wait
			// for the task to actually exit before deleting it — otherwise
			// Delete races the still-"running" task ("failed precondition").
			exitC, _ := task.Wait(ctx)
			task.Kill(ctx, syscall.SIGKILL)
			select {
			case <-exitC:
			case <-time.After(15 * time.Second):
			}
			task.Delete(ctx, containerd.WithProcessKill)
		}
		err = container.Delete(ctx, containerd.WithSnapshotCleanup)
	}
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

// --- networking (go-cni) ---

// Network wraps go-cni. Replaces the old 352-line hand-rolled ioctl
// TAP/bridge/IP code in network.rs. The conflist at
// /etc/cni/net.d/10-sandbox.conflist (bridge + host-local IPAM + firewall)
// declares everything; go-cni applies it into a per-sandbox netns.
//
// Proven flow on the spike box (NOT the old run-CNI-on-the-VM-PID approach):
//
//  1. create a netns
//  2. run CNI ADD in it  -> veth eth0 with 10.88.x.x + default route
//  3. boot the Kata VM *inside* that netns (OCI spec NetworkNamespace)
//
// Kata's internetworking_model=tcfilter then redirects the veth to the
// Firecracker TAP automatically — so the conflist must NOT include
// tc-redirect-tap (it would collide with Kata's own qdisc setup).
type Network struct {
	cni gocni.CNI
}

func NewNetwork(binDir, confDir string) (*Network, error) {
	c, err := gocni.New(
		gocni.WithPluginDir([]string{binDir}),
		gocni.WithPluginConfDir(confDir),
		gocni.WithDefaultConf, // loads 10-sandbox.conflist
	)
	if err != nil {
		return nil, err
	}
	return &Network{cni: c}, nil
}

func netnsPath(id string) string { return "/var/run/netns/" + id }

// Setup creates a netns named after the sandbox, wires CNI into it, and returns
// the netns path (to put on the OCI spec) and the allocated IPv4. Call BEFORE
// creating the container.
func (n *Network) Setup(ctx context.Context, id string) (nsPath, ip string, err error) {
	if out, err := exec.Command("ip", "netns", "add", id).CombinedOutput(); err != nil {
		return "", "", fmt.Errorf("netns add: %v: %s", err, out)
	}
	nsPath = netnsPath(id)
	res, err := n.cni.Setup(ctx, id, nsPath)
	if err != nil {
		// CNI may have partially allocated (IPAM lease, host veth, fw rules)
		// before failing — run Remove to release it, then drop the netns.
		n.cni.Remove(ctx, id, nsPath)
		exec.Command("ip", "netns", "del", id).Run()
		return "", "", fmt.Errorf("cni setup: %w", err)
	}
	for _, iface := range res.Interfaces {
		for _, ipc := range iface.IPConfigs {
			if ip4 := ipc.IP.To4(); ip4 != nil {
				return nsPath, ip4.String(), nil
			}
		}
	}
	return nsPath, "", nil // attached but no IPv4 surfaced; non-fatal
}

// Teardown removes CNI config and the netns. Idempotent (best-effort on delete).
func (n *Network) Teardown(ctx context.Context, id string) {
	_ = n.cni.Remove(ctx, id, netnsPath(id))
	_ = exec.Command("ip", "netns", "del", id).Run()
}

// --- home disk (Kata direct-volume) ---

// homeDisk attaches a user's persistent home.img to a microVM as /root.
//
// Firecracker can't bind-mount a host directory into the guest (no shared FS),
// and bind-mounting the raw .img *file* fails ("Is a directory"). The working
// path — proven live on the spike box — is a real block device fed through
// Kata's direct-volume API:
//
//  1. losetup the .img            -> /dev/loopN (a real block device)
//  2. kata-runtime direct-volume add --volume-path <P> --mount-info {block,...}
//  3. the container bind-mounts <P> -> /root; Kata hot-plugs the disk as
//     virtio-blk and the guest mounts its ext4 there.
//
// Detach reverses it. The .img is a standalone, durable artifact: destroy the
// VM, keep the home; re-attach the same .img to a new (or bigger) VM and the
// files are intact — that's sandbox migration.
type homeDisk struct {
	kataRuntime string // path to kata-runtime (direct-volume add/remove)
	volRoot     string // base dir for per-sandbox volume paths
}

func newHomeDisk(kataRuntime, volRoot string) *homeDisk {
	return &homeDisk{kataRuntime: kataRuntime, volRoot: volRoot}
}

// volumePath is the stable per-sandbox mount source Kata keys its metadata on.
func (h *homeDisk) volumePath(sandboxID string) string {
	return filepath.Join(h.volRoot, sandboxID)
}

// Attach loop-mounts img, registers it as a Kata direct-volume, and returns the
// volume path to bind to /root. Safe on retries: a stale registration/loop for
// this sandbox is cleared first.
func (h *homeDisk) Attach(sandboxID, img string) (string, error) {
	vp := h.volumePath(sandboxID)
	h.Detach(sandboxID) // clear any stale loop/registration from a crash

	if err := os.MkdirAll(vp, 0o755); err != nil {
		return "", fmt.Errorf("mkdir volume path: %w", err)
	}
	out, err := exec.Command("losetup", "--find", "--show", img).Output()
	if err != nil {
		return "", fmt.Errorf("losetup %s: %w", img, err)
	}
	loop := strings.TrimSpace(string(out))
	// Record the loop device ourselves so Detach doesn't depend on Kata's
	// private direct-volume metadata layout (which could change between
	// versions). The Kata readback stays as a fallback.
	os.WriteFile(filepath.Join(vp, "loop"), []byte(loop), 0o644)

	mountInfo, _ := json.Marshal(map[string]any{
		"volume-type": "block",
		"device":      loop,
		"fstype":      "ext4",
		"metadata":    map[string]any{},
		"options":     []string{},
	})
	if out, err := exec.Command(h.kataRuntime, "direct-volume", "add",
		"--volume-path", vp, "--mount-info", string(mountInfo)).CombinedOutput(); err != nil {
		// Add can fail after writing partial metadata; undo everything so the
		// caller (which installs its detach hook only after Attach returns)
		// isn't left with a leaked loop / stale registration / volume dir.
		exec.Command("losetup", "-d", loop).Run()
		exec.Command(h.kataRuntime, "direct-volume", "remove", "--volume-path", vp).Run()
		os.RemoveAll(vp)
		return "", fmt.Errorf("direct-volume add: %v: %s", err, out)
	}
	return vp, nil
}

// Detach releases everything Attach set up, given only the sandbox id: it reads
// the loop device back from Kata's mountInfo.json, detaches it, removes the
// registration, and deletes the volume dir. Best effort — every step no-ops if
// already gone (partial-create cleanup, double delete).
func (h *homeDisk) Detach(sandboxID string) {
	vp := h.volumePath(sandboxID)
	if loop := h.recordedLoop(vp); loop != "" {
		exec.Command("losetup", "-d", loop).Run()
	}
	exec.Command(h.kataRuntime, "direct-volume", "remove", "--volume-path", vp).Run()
	os.RemoveAll(vp)
}

// recordedLoop returns the loop device backing this volume. Prefers our own
// record (written at Attach); falls back to Kata's direct-volume metadata
// (keyed by base64(volumePath)) for sandboxes attached before this existed.
func (h *homeDisk) recordedLoop(volPath string) string {
	if b, err := os.ReadFile(filepath.Join(volPath, "loop")); err == nil {
		if loop := strings.TrimSpace(string(b)); loop != "" {
			return loop
		}
	}
	key := base64.StdEncoding.EncodeToString([]byte(volPath))
	data, err := os.ReadFile(filepath.Join(
		"/run/kata-containers/shared/direct-volumes", key, "mountInfo.json"))
	if err != nil {
		return ""
	}
	var info struct {
		Device string `json:"device"`
	}
	json.Unmarshal(data, &info)
	return info.Device
}

// --- exec output capture & helpers ---

// outputBuffer is a tiny thread-safe io.Writer for capturing exec output.
type outputBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (b *outputBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *outputBuffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]byte, len(b.buf))
	copy(out, b.buf)
	return out
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
