//! TAP network setup for VMs
//!
//! Creates TAP devices using direct ioctl (works with CAP_NET_ADMIN capability).
//! Bridge + NAT are owned by the `sandbox-bridge.service` systemd unit
//! (see `sandbox-manager/systemd/`).

use anyhow::{bail, Context, Result};
use std::ffi::CString;
use std::net::Ipv4Addr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

// TUN/TAP ioctl constants
const TUNSETIFF: libc::c_ulong = 0x400454ca;
const TUNSETPERSIST: libc::c_ulong = 0x400454cb;
const IFF_TAP: libc::c_short = 0x0002;
const IFF_NO_PI: libc::c_short = 0x1000;

// Socket ioctl constants
const SIOCBRADDIF: libc::c_ulong = 0x89a2;
const SIOCGIFFLAGS: libc::c_ulong = 0x8913;
const SIOCSIFFLAGS: libc::c_ulong = 0x8914;

/// ifreq with ifr_flags union variant
#[repr(C)]
struct IfReqFlags {
    ifr_name: [libc::c_char; libc::IFNAMSIZ],
    ifr_flags: libc::c_short,
    _pad: [u8; 22],
}

/// ifreq with ifr_ifindex union variant (for SIOCBRADDIF)
#[repr(C)]
struct IfReqIndex {
    ifr_name: [libc::c_char; libc::IFNAMSIZ],
    ifr_ifindex: libc::c_int,
    _pad: [u8; 20],
}

// Compile-time size check: both must be 40 bytes (standard ifreq size on x86_64)
const _: () = assert!(std::mem::size_of::<IfReqFlags>() == 40);
const _: () = assert!(std::mem::size_of::<IfReqIndex>() == 40);

fn write_ifr_name(buf: &mut [libc::c_char; libc::IFNAMSIZ], name: &str) {
    let bytes = name.as_bytes();
    let len = bytes.len().min(libc::IFNAMSIZ - 1);
    for (i, &b) in bytes[..len].iter().enumerate() {
        buf[i] = b as libc::c_char;
    }
}

fn if_nametoindex(name: &str) -> Result<u32> {
    let c_name = CString::new(name).context("invalid interface name")?;
    let idx = unsafe { libc::if_nametoindex(c_name.as_ptr()) };
    if idx == 0 {
        bail!("interface {} not found", name);
    }
    Ok(idx)
}

/// Safe wrapper to open a fd, returning error instead of wrapping -1
fn open_fd(path: &[u8], flags: libc::c_int) -> Result<OwnedFd> {
    let fd = unsafe { libc::open(path.as_ptr() as *const libc::c_char, flags) };
    if fd < 0 {
        bail!("{}", std::io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn new_socket() -> Result<OwnedFd> {
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        bail!("socket(): {}", std::io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Check ioctl return, return last OS error on failure
fn check_ioctl(ret: libc::c_int, op: &str) -> Result<()> {
    if ret < 0 {
        bail!("{}: {}", op, std::io::Error::last_os_error());
    }
    Ok(())
}

/// Set IFF_UP on an existing interface (idempotent). Requires CAP_NET_ADMIN.
fn bring_iface_up(name: &str) -> Result<()> {
    let sock = new_socket().context("socket for iface up")?;
    let mut ifr = IfReqFlags {
        ifr_name: [0; libc::IFNAMSIZ],
        ifr_flags: 0,
        _pad: [0; 22],
    };
    write_ifr_name(&mut ifr.ifr_name, name);

    check_ioctl(
        unsafe { libc::ioctl(sock.as_raw_fd(), SIOCGIFFLAGS, &mut ifr as *mut IfReqFlags) },
        "SIOCGIFFLAGS",
    )
    .with_context(|| format!("get flags for {}", name))?;

    if (ifr.ifr_flags & libc::IFF_UP as libc::c_short) != 0 {
        return Ok(());
    }
    ifr.ifr_flags |= libc::IFF_UP as libc::c_short;

    check_ioctl(
        unsafe { libc::ioctl(sock.as_raw_fd(), SIOCSIFFLAGS, &ifr as *const IfReqFlags) },
        "SIOCSIFFLAGS",
    )
    .with_context(|| format!("bring up {}", name))
}

/// Network configuration for a VM
#[derive(Debug, Clone)]
pub struct VmNetwork {
    pub tap_name: String,
    pub guest_ip: Ipv4Addr,
    pub guest_mac: String,
    pub gateway_ip: Ipv4Addr,
    pub netmask: Ipv4Addr,
}

/// Network manager for VM TAP devices.
///
/// IP allocation is **stateless** in the manager: claims live in Redis under
/// `sandbox:network:ip:<ipv4>` (see `redis::ip_claim`). This means concurrent
/// managers can't double-allocate, and a manager restart never re-issues an
/// IP that's still in use by a re-attached VM.
pub struct NetworkManager {
    bridge_name: String,
    bridge_ip: Ipv4Addr,
    /// Subnet mask (e.g. `255.255.0.0` for /16). Passed into the guest's
    /// kernel cmdline so it computes the right broadcast/route.
    netmask: Ipv4Addr,
    /// First assignable host address (e.g. `10.42.0.2`).
    range_start: u32,
    /// Last assignable host address (broadcast - 1).
    range_end: u32,
    redis: crate::redis::RedisClient,
}

impl NetworkManager {
    pub fn new(bridge_name: &str, subnet: &str, redis: crate::redis::RedisClient) -> Result<Self> {
        // Parse `a.b.c.d/prefix`. Only /16 has been deployed; for safety we
        // compute the actual subnet bounds rather than hardcoding `.0.2..`.
        let (addr_str, prefix_str) = subnet.split_once('/').context("subnet missing /prefix")?;
        let base_ip: Ipv4Addr = addr_str.parse().context("invalid subnet address")?;
        let prefix: u32 = prefix_str.parse().context("invalid subnet prefix")?;
        if !(8..=30).contains(&prefix) { bail!("subnet prefix /{prefix} out of supported range /8../30"); }

        let mask: u32 = if prefix == 0 { 0 } else { u32::MAX << (32 - prefix) };
        let network = u32::from(base_ip) & mask;
        let broadcast = network | !mask;

        // .1 = bridge, .2..broadcast-1 = guests
        let bridge_ip = Ipv4Addr::from(network + 1);
        let range_start = network + 2;
        let range_end = broadcast.saturating_sub(1);
        if range_start > range_end { bail!("subnet too small for guest IPs"); }

        Ok(Self {
            bridge_name: bridge_name.to_string(),
            bridge_ip,
            netmask: Ipv4Addr::from(mask),
            range_start,
            range_end,
            redis,
        })
    }

    /// Validate that the bridge exists, then ensure it is administratively UP.
    /// Bridge + NAT are owned by the `sandbox-bridge.service` systemd unit;
    /// bringing it UP only needs CAP_NET_ADMIN, which sandbox-manager already has.
    pub fn init_bridge(&self) -> Result<()> {
        if_nametoindex(&self.bridge_name).with_context(|| {
            format!(
                "Bridge {} not found. Install + start the systemd unit:\n  \
                 sudo sandbox-manager/systemd/install.sh\n  \
                 sudo systemctl status sandbox-bridge.service",
                self.bridge_name,
            )
        })?;

        bring_iface_up(&self.bridge_name)
            .with_context(|| format!("bring up bridge {}", self.bridge_name))?;

        tracing::info!("Network bridge {} validated and UP (IP {})", self.bridge_name, self.bridge_ip);
        Ok(())
    }

    /// Allocate a guest IP by claiming the lowest free address in the subnet
    /// via Redis `SET NX`. O(N) on the address space worst-case, but in
    /// practice O(1) since claims are dense from the bottom.
    ///
    /// Returns `Err` only if the subnet is exhausted or Redis is unreachable.
    pub async fn allocate(&self, vm_id: &str) -> Result<VmNetwork> {
        let mut guest_ip: Option<Ipv4Addr> = None;
        for ip_u32 in self.range_start..=self.range_end {
            let candidate = Ipv4Addr::from(ip_u32);
            if self.redis.ip_claim(candidate, vm_id).await? {
                guest_ip = Some(candidate);
                break;
            }
        }
        let guest_ip = guest_ip.context("subnet exhausted: no free guest IPs")?;

        // TAP name max 15 chars for Linux IFNAMSIZ
        let tap_name = format!("tap-{}", &vm_id[..8.min(vm_id.len())]);

        let octets = guest_ip.octets();
        let guest_mac = format!(
            "AA:FC:{:02X}:{:02X}:{:02X}:{:02X}",
            octets[0], octets[1], octets[2], octets[3]
        );

        Ok(VmNetwork {
            tap_name,
            guest_ip,
            guest_mac,
            gateway_ip: self.bridge_ip,
            netmask: self.netmask,
        })
    }

    /// Release an IP back to the pool *if* the caller still owns the claim.
    /// Idempotent. Prevents a late cleanup from clobbering a reused IP.
    pub async fn release_ip(&self, ip: Ipv4Addr, sandbox_id: &str) -> Result<()> {
        self.redis.ip_release_if_owner(ip, sandbox_id).await
    }

    /// Create TAP device, attach to bridge, bring UP. All via ioctl (no child processes).
    /// Transactional: any failure after the TAP is made persistent triggers `destroy_tap`
    /// so we never leak orphan persistent TAPs in the kernel. Pre-persist failures don't
    /// need rollback — the TAP dies with the fd.
    pub fn create_tap(&self, network: &VmNetwork) -> Result<()> {
        let mut persisted = false;
        match self.create_tap_inner(network, &mut persisted) {
            Ok(()) => Ok(()),
            Err(e) => {
                if persisted {
                    if let Err(cleanup_err) = self.destroy_tap(&network.tap_name) {
                        tracing::warn!(
                            "create_tap rollback failed for {}: {:#}",
                            network.tap_name, cleanup_err
                        );
                    }
                }
                Err(e)
            }
        }
    }

    fn create_tap_inner(&self, network: &VmNetwork, persisted: &mut bool) -> Result<()> {
        // 1. Open /dev/net/tun
        let tun_fd = open_fd(b"/dev/net/tun\0", libc::O_RDWR | libc::O_CLOEXEC)
            .context("open /dev/net/tun")?;

        // 2. Create TAP via TUNSETIFF
        let mut ifr = IfReqFlags {
            ifr_name: [0; libc::IFNAMSIZ],
            ifr_flags: IFF_TAP | IFF_NO_PI,
            _pad: [0; 22],
        };
        write_ifr_name(&mut ifr.ifr_name, &network.tap_name);

        check_ioctl(
            unsafe { libc::ioctl(tun_fd.as_raw_fd(), TUNSETIFF, &mut ifr as *mut IfReqFlags) },
            "TUNSETIFF",
        )
        .with_context(|| format!("create TAP {}", network.tap_name))?;

        // 3. Make persistent (so TAP survives fd close).
        // From here on, any failure must roll back via destroy_tap (handled by create_tap).
        check_ioctl(
            unsafe { libc::ioctl(tun_fd.as_raw_fd(), TUNSETPERSIST, 1 as libc::c_int) },
            "TUNSETPERSIST",
        )
        .with_context(|| format!("persist TAP {}", network.tap_name))?;
        *persisted = true;

        drop(tun_fd);

        // 4. Attach to bridge via SIOCBRADDIF
        let sock = new_socket().context("socket for TAP config")?;
        let tap_idx = if_nametoindex(&network.tap_name)
            .with_context(|| format!("TAP {} disappeared after creation", network.tap_name))?;

        let mut br_ifr = IfReqIndex {
            ifr_name: [0; libc::IFNAMSIZ],
            ifr_ifindex: tap_idx as libc::c_int,
            _pad: [0; 20],
        };
        write_ifr_name(&mut br_ifr.ifr_name, &self.bridge_name);

        check_ioctl(
            unsafe { libc::ioctl(sock.as_raw_fd(), SIOCBRADDIF, &br_ifr as *const IfReqIndex) },
            "SIOCBRADDIF",
        )
        .with_context(|| format!("attach {} to {}", network.tap_name, self.bridge_name))?;

        // 5. Bring TAP UP
        drop(sock);
        bring_iface_up(&network.tap_name)?;

        tracing::info!(
            "Created TAP {} on {} for VM {}",
            network.tap_name, self.bridge_name, network.guest_ip
        );
        Ok(())
    }

    /// Destroy TAP device by clearing persistent flag.
    /// Returns Err if /dev/net/tun cannot be opened or TUNSETIFF/TUNSETPERSIST fail —
    /// callers can log/metric, but in cleanup paths we still want best-effort behaviour.
    pub fn destroy_tap(&self, tap_name: &str) -> Result<()> {
        let tun_fd = open_fd(b"/dev/net/tun\0", libc::O_RDWR | libc::O_CLOEXEC)
            .with_context(|| format!("open /dev/net/tun for destroy {}", tap_name))?;

        let mut ifr = IfReqFlags {
            ifr_name: [0; libc::IFNAMSIZ],
            ifr_flags: IFF_TAP | IFF_NO_PI,
            _pad: [0; 22],
        };
        write_ifr_name(&mut ifr.ifr_name, tap_name);

        check_ioctl(
            unsafe { libc::ioctl(tun_fd.as_raw_fd(), TUNSETIFF, &mut ifr as *mut IfReqFlags) },
            "TUNSETIFF (destroy)",
        )
        .with_context(|| format!("attach to TAP {} for destroy", tap_name))?;

        check_ioctl(
            unsafe { libc::ioctl(tun_fd.as_raw_fd(), TUNSETPERSIST, 0 as libc::c_int) },
            "TUNSETPERSIST(0)",
        )
        .with_context(|| format!("clear persist on TAP {}", tap_name))?;

        tracing::debug!("Destroyed TAP {}", tap_name);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ifreq_sizes() {
        assert_eq!(std::mem::size_of::<IfReqFlags>(), 40);
        assert_eq!(std::mem::size_of::<IfReqIndex>(), 40);
    }
}
