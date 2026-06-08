package sandbox

import "time"

// State is the lifecycle of a sandbox. Kept string-compatible with the old
// Rust service's wire format ("creating"/"running"/...) because the backend
// and frontend parse these over the Redis event channel.
type State string

const (
	StateCreating    State = "creating"
	StateRunning     State = "running"
	StateTerminating State = "terminating"
	StateError       State = "error"
)

// Sandbox is the inventory record persisted in Redis at `sandbox:<id>` and
// published to `sandbox:events:<userId>`. Field names (JSON) match the old
// SandboxInfo so the backend's subscriber needs no change.
//
// Dropped vs the old model: pid (containerd owns the process), ip allocation
// internals (CNI owns it; we keep the resolved IP only), Lite (VM-only now),
// pause/balloon. `device_id` stays for backend Device cleanup. `kind` is kept
// (always "vm") because the backend's tier alignment still keys off it.
type Sandbox struct {
	ID       string `json:"id"`
	UserID   string `json:"user_id"`
	Template string `json:"template"`
	Size     string `json:"size"`
	// Kind is always "vm": this manager is VM-only (Lite was dropped in the Go
	// rewrite). The backend still distinguishes vm/lite in its tier alignment
	// (`syncToTier` matches `kind === 'vm'`), so we must emit it — a missing
	// kind makes the backend never recognise an existing VM as aligned and it
	// loops creating new ones (→ 409 "user already has an active sandbox").
	Kind         string  `json:"kind"`
	State        State   `json:"state"`
	IPAddress    string  `json:"ip_address,omitempty"`
	CostPerMin   float64 `json:"cost_per_minute"`
	Error        string  `json:"error,omitempty"`
	DeviceID     string  `json:"device_id,omitempty"`
	CreatedAt    int64   `json:"created_at"`
	LastActivity int64   `json:"last_activity"`
}

// IsActive reports whether the sandbox holds resources / counts against quota.
// Terminating MUST count: until the VM is actually gone, the user must not be
// able to create another, and it must not be dropped from sandbox:active.
func (s *Sandbox) IsActive() bool {
	return s.State == StateRunning || s.State == StateCreating || s.State == StateTerminating
}

func NowMillis() int64 { return time.Now().UnixMilli() }
