use std::net::Ipv4Addr;

/// Detected LAN interface information.
#[derive(Debug, Clone)]
pub struct LanInfo {
    pub ip: Ipv4Addr,
    pub interface_name: String,
}

/// Detect the primary LAN IP address.
///
/// Strategy:
/// 1. Use `local_ip_address` crate to get the default route IP
/// 2. Validate it's a private/link-local address
/// 3. Fallback to scanning network interfaces
pub fn detect_primary_lan() -> Option<LanInfo> {
    // Phase 1: Try local_ip_address (uses default route)
    if let Ok(ip) = local_ip_address::local_ip() {
        if let std::net::IpAddr::V4(v4) = ip {
            if is_usable_address(v4) {
                return Some(LanInfo {
                    ip: v4,
                    interface_name: "default".to_string(),
                });
            }
        }
    }

    // Phase 2: Scan all interfaces
    detect_from_interfaces()
}

/// Check if an IPv4 address is usable for LAN communication.
fn is_usable_address(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    // Loopback
    if octets[0] == 127 {
        return false;
    }
    // 0.0.0.0
    if octets == [0, 0, 0, 0] {
        return false;
    }
    // Private ranges: 10.x, 172.16-31.x, 192.168.x
    // Also allow link-local 169.254.x
    true
}

/// Detect from system network interfaces.
#[cfg(windows)]
fn detect_from_interfaces() -> Option<LanInfo> {
    use std::net::UdpSocket;
    // On Windows, use the UDP connect trick to find the outgoing interface
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    if let std::net::IpAddr::V4(v4) = addr.ip() {
        if is_usable_address(v4) {
            return Some(LanInfo {
                ip: v4,
                interface_name: "udp-detected".to_string(),
            });
        }
    }
    None
}

#[cfg(not(windows))]
fn detect_from_interfaces() -> Option<LanInfo> {
    // On macOS/Linux, try enumerating interfaces
    if let Ok(addrs) = local_ip_address::list_afinet_netifas() {
        for (name, ip) in addrs {
            if let std::net::IpAddr::V4(v4) = ip {
                if is_usable_address(v4) && !name.contains("lo") {
                    return Some(LanInfo {
                        ip: v4,
                        interface_name: name,
                    });
                }
            }
        }
    }
    None
}
