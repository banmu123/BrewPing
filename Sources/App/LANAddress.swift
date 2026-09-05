import Foundation
import Network
import Darwin

enum LANAddress {
    struct LANInfo {
        let ip: String
        let interfaceName: String
        let nwInterface: NWInterface?
    }

    static func primaryLAN() -> LANInfo? {
        let nw = interfaceViaPathMonitor()
        let candidates = ipv4Candidates()
        let chosen = candidates.first { $0.interface == nw?.name }
            ?? candidates.first { $0.interface.hasPrefix("en") }
            ?? candidates.first
        guard let chosen else { return nil }
        return LANInfo(ip: chosen.ip, interfaceName: chosen.interface, nwInterface: nw)
    }

    private static func interfaceViaPathMonitor() -> NWInterface? {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var found: NWInterface?
        monitor.pathUpdateHandler = { path in
            if found == nil {
                let usable = path.availableInterfaces.filter { $0.type != .loopback }
                found = usable.first { $0.type == .wifi }
                    ?? usable.first { $0.type == .wiredEthernet }
                    ?? usable.first
            }
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue(label: "BrewPing LAN detect"))
        _ = semaphore.wait(timeout: .now() + 2)
        monitor.cancel()
        return found
    }

    private static func ipv4Candidates() -> [(interface: String, ip: String)] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(interface: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let ifa = current.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            candidates.append(
                (interface: String(cString: ifa.ifa_name), ip: String(cString: host))
            )
        }
        return candidates
    }
}
