package vm

import (
	"context"
	"fmt"
	"os/exec"

	gocni "github.com/containerd/go-cni"
)

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
