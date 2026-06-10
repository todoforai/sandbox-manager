package store

import (
	"encoding/json"
	"testing"
)

func TestIsActive(t *testing.T) {
	cases := map[State]bool{
		StateCreating:    true,
		StateRunning:     true,
		StateTerminating: true, // must hold quota until the VM is actually gone
		StateError:       false,
	}
	for state, want := range cases {
		sb := &Sandbox{State: state}
		if got := sb.IsActive(); got != want {
			t.Errorf("IsActive(%s) = %v, want %v", state, got, want)
		}
	}
}

// The JSON field names are a wire contract with the backend's
// SandboxEventSubscriber — a rename breaks tier sync silently.
func TestSandboxWireFormat(t *testing.T) {
	sb := &Sandbox{
		ID: "i", UserID: "u", Template: "t", Size: "s", Kind: "vm",
		State: StateRunning, IPAddress: "10.88.0.2", CostPerMin: 0.005,
		Error: "e", DeviceID: "d", CreatedAt: 1, LastActivity: 2,
	}
	js, err := json.Marshal(sb)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	json.Unmarshal(js, &m)
	for _, key := range []string{
		"id", "user_id", "template", "size", "kind", "state", "ip_address",
		"cost_per_minute", "error", "device_id", "created_at", "last_activity",
	} {
		if _, ok := m[key]; !ok {
			t.Errorf("wire format missing %q (backend contract)", key)
		}
	}
}
