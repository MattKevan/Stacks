import Darwin
import Foundation

/// The device's own and other hosts' LAN addresses, in display form.
///
/// Extracted from `LibraryDiscovery`'s self-filtering set so the Sharing pane
/// (own addresses) and the sidebar's Get Info (a connected server's address)
/// share one implementation.
enum LocalNetwork {
    /// This device's non-loopback IP addresses, IPv4 before IPv6, scope
    /// suffixes stripped — the addresses a peer on the LAN would use to reach
    /// this machine. Drives the Sharing pane's IP rows and discovery's
    /// self-filter (the app's own share resolves to one of these).
    static var myAddresses: [String] {
        var v4: [String] = []
        var v6: [String] = []
        var interface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interface) == 0 else { return [] }
        defer { freeifaddrs(interface) }
        var cursor = interface
        while let current = cursor {
            // The loopback interface's 127.0.0.1/::1 are never an address to
            // hand another device; skip them outright.
            if current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) != 0 {
                cursor = current.pointee.ifa_next
                continue
            }
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    current.pointee.ifa_addr,
                    socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    // Match the discovery host form: scope suffix stripped.
                    let value = String(cString: host).split(separator: "%").first.map(String.init)
                        ?? String(cString: host)
                    if family == sa_family_t(AF_INET) { v4.append(value) } else { v6.append(value) }
                }
            }
            cursor = current.pointee.ifa_next
        }
        return v4 + v6
    }

    /// The IPv4 subset of `myAddresses` — the addresses worth putting in
    /// front of another device. Link-local IPv6 (`fe80:…`) is unusable
    /// without an interface scope, so it would only confuse.
    static var myIPv4Addresses: [String] {
        myAddresses.filter { $0.contains(".") }
    }

    /// Numeric addresses a host resolves to (IPv4 first), for showing the raw
    /// IP a connected server sits on. Empty when the host cannot be resolved
    /// — the caller falls back to the host as typed.
    static func ipAddresses(of host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }
        var v4: [String] = []
        var v6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr, current.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 {
                let value = String(cString: buffer).split(separator: "%").first.map(String.init)
                    ?? String(cString: buffer)
                if current.pointee.ai_family == AF_INET { v4.append(value) } else { v6.append(value) }
            }
            cursor = current.pointee.ai_next
        }
        return v4 + v6
    }

    /// The host form a URL needs: IPv6 addresses are bracketed.
    static func urlHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}