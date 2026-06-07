package vm

import (
	"context"
	"fmt"

	gocni "github.com/containerd/go-cni"
)

// Network wraps go-cni. This is the entire replacement for the old 352-line
// hand-rolled ioctl TAP/bridge/IP-allocation in network.rs. The conflist at
// /etc/cni/net.d/10-sandbox.conflist (bridge + host-local IPAM + firewall +
// tc-redirect-tap) declares everything; go-cni applies it per microVM.
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

// netnsPath is the network namespace CNI operates on.
//
// TODO(host-verify): with Kata, task.Pid() is the host-side shim/VMM — its
// netns may be the HOST netns, in which case CNI would wire the host, not the
// guest. The likely-correct design is an explicit per-sandbox netns created
// here, run CNI against it, and pass it into the runtime spec. Needs a live
// Kata boot (`ip netns`, process tree, guest connectivity) to confirm before
// trusting this path.
func netnsPath(pid int) string {
	return fmt.Sprintf("/proc/%d/ns/net", pid)
}

// Attach wires networking for the microVM and returns its allocated IPv4.
func (n *Network) Attach(ctx context.Context, id string, pid int) (string, error) {
	res, err := n.cni.Setup(ctx, id, netnsPath(pid))
	if err != nil {
		return "", err
	}
	for _, iface := range res.Interfaces {
		for _, ipc := range iface.IPConfigs {
			if ip4 := ipc.IP.To4(); ip4 != nil {
				return ip4.String(), nil
			}
		}
	}
	return "", nil // attached but no IPv4 surfaced; non-fatal
}

// Detach tears down networking. Idempotent (best-effort on delete).
func (n *Network) Detach(ctx context.Context, id string, pid int) {
	_ = n.cni.Remove(ctx, id, netnsPath(pid))
}
