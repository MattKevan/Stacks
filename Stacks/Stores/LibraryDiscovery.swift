import CryptoKit
import Darwin
import Foundation
import Network
import Observation
import StacksCore

/// One library discovered on the LAN via Bonjour (`_stacks._tcp`), or typed
/// in manually as host:port.
public struct DiscoveredLibrary: Identifiable, Equatable, Sendable {
    /// The library's manifest id (TXT record for Bonjour discovery). Manual
    /// connections use a stable id derived from the host:port so credentials
    /// and the offline queue survive reconnect.
    public let id: UUID
    /// Display name. Manual connections start as the host and adopt the
    /// server's real name once `/api/identity` answers.
    public var name: String
    public let host: String
    public let port: Int

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    /// A manual host:port entry (no Bonjour TXT): id is the SHA-256 of the
    /// address, stable across sessions.
    public init(manualHost host: String, port: Int) {
        let digest = SHA256.hash(data: Data("stacks://\(host):\(port)".utf8))
        let bytes = Array(digest.prefix(16))
        self.id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.name = host
        self.host = host
        self.port = port
    }

    /// Bonjour-discovered values (TXT record carries the manifest id + name).
    public init(id: UUID, name: String, host: String, port: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses for `_stacks._tcp` services on the LAN and resolves them to
/// `DiscoveredLibrary` values. Drives the sidebar's Shared section.
@MainActor
@Observable
public final class LibraryDiscovery {
    public private(set) var libraries: [DiscoveredLibrary] = []
    /// Library ids never shown in the list — the app sets this to its own
    /// home library id so its OWN share never appears in the Shared section
    /// (only other libraries on the network should).
    public var excludedIDs: Set<UUID> = []
    /// Non-nil while browsing is active (the privacy-prompt gate surfaced
    /// as `.waiting(.dns(kDNSServiceErr_PolicyDenied))` is reported here).
    public private(set) var browseError: String?

    private var browser: NWBrowser?
    /// Service instance name → resolved library (kept until the service
    /// stops advertising, so re-browses don't flicker).
    private var resolved: [String: DiscoveredLibrary] = [:]
    /// In-flight resolutions, keyed by service name — an NWConnection must
    /// be retained until it settles, and each service resolves at most once.
    private var pendingConnections: [String: NWConnection] = [:]
    /// The service names currently advertised (from the last browse change).
    private var currentNames: Set<String> = []

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_stacks._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .waiting(let error):
                    self?.browseError = error.localizedDescription
                case .failed(let error):
                    self?.browseError = error.localizedDescription
                    self?.browser = nil
                case .ready, .cancelled, .setup:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.update(results: results)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for connection in pendingConnections.values {
            connection.cancel()
        }
        pendingConnections = [:]
        resolved = [:]
        currentNames = []
        libraries = []
        browseError = nil
    }

    private func update(results: Set<NWBrowser.Result>) {
        var names = Set<String>()
        for result in results {
            guard case .service(name: let name, type: _, domain: _, interface: _) = result.endpoint else {
                continue
            }
            names.insert(name)
            // Resolve each advertised service once (TXT + host:port); a
            // service already resolved just re-appears via refreshLibraries.
            if resolved[name] == nil && pendingConnections[name] == nil {
                resolve(result)
            }
        }
        currentNames = names
        refreshLibraries()
    }

    /// Recomputes the visible list from what is resolved AND still advertised.
    private func refreshLibraries() {
        libraries = resolved
            .filter {
                currentNames.contains($0.key)
                    && !excludedIDs.contains($0.value.id)
                    // The app's own share never appears: it resolves to
                    // loopback or the device's own LAN address.
                    && !Self.isLoopback($0.value.host)
                    && !Self.localAddresses.contains($0.value.host)
            }
            .values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Whether a host is the loopback address (the app's own share resolves
    /// to 127.0.0.1 / ::1 on the local interface).
    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    /// This device's own IP addresses (IPv4 + IPv6, non-loopback, scope
    /// suffixes stripped) — the app's own share can resolve via the LAN
    /// interface to one of these instead of loopback.
    private static let localAddresses: Set<String> = {
        var addresses = Set<String>()
        var interface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interface) == 0 else { return addresses }
        defer { freeifaddrs(interface) }
        var cursor = interface
        while let current = cursor {
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
                    addresses.insert(value)
                }
            }
            cursor = current.pointee.ifa_next
        }
        return addresses
    }()

    private func resolve(_ result: NWBrowser.Result) {
        guard case .service(name: let name, type: _, domain: _, interface: _) = result.endpoint else {
            return
        }
        // Resolve the service to a concrete host:port (the connection must
        // stay retained until it settles).
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        pendingConnections[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let hostAndPort: (host: String, port: Int)?
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    // IPv4/IPv6 descriptions are clean; strip any interface
                    // scope suffix ("%en0") defensively.
                    let hostString = host.debugDescription.split(separator: "%").first
                        .map(String.init) ?? host.debugDescription
                    hostAndPort = (hostString, Int(port.rawValue))
                } else {
                    hostAndPort = nil
                }
                if let hostAndPort {
                    Task { @MainActor in
                        guard let self else { return }
                        self.pendingConnections[name] = nil
                        self.resolved[name] = await Self.fetchLibrary(
                            host: hostAndPort.host, port: hostAndPort.port, fallbackName: name
                        )
                        self.refreshLibraries()
                    }
                }
                connection.cancel()
            case .failed:
                Task { @MainActor in
                    self?.pendingConnections[name] = nil
                }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Fetches the server's identity (authoritative library id + display
    /// name) over HTTP — browse results carry no TXT record in this SDK, so
    /// `/api/identity` is the source of truth. A passworded server (401)
    /// yields a provisional entry with a stable derived id and the service
    /// name; the connect flow then prompts for credentials.
    private static func fetchLibrary(host: String, port: Int, fallbackName: String) async -> DiscoveredLibrary {
        var provisional = DiscoveredLibrary(manualHost: host, port: port)
        provisional.name = fallbackName
        guard let probe = try? RemoteLibrary(configuration: .init(
            baseURL: provisional.baseURL,
            queueDirectory: RemoteLibraryBrowser.queueDirectory(libraryID: provisional.id)
        )),
        let identity = try? await probe.fetchIdentity() else {
            return provisional
        }
        return DiscoveredLibrary(id: identity.id, name: identity.name, host: host, port: port)
    }
}
