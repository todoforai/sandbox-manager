package vm

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

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
