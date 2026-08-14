import Foundation
import Observation
import StacksCore

/// Owns the in-process `LibraryServer` + Bonjour advertising driven by the
/// Settings → Sharing pane. The app is one writer among many: when sharing is
/// on, the app's local edits and the server's journal stay in sync because
/// the app routes its edits through the same repository the server opens —
/// the server is the ordering authority, and the app is a privileged client
/// on the same journal.
@MainActor
@Observable
final class SharingService {
    private(set) var isSharing = false
    private(set) var lastError: String?
    private var server: LibraryServer?

    /// The port the active server binds (set at start; drives the copy-URL).
    private var port = 8080
    /// The feature flags of the running server; start() restarts when a
    /// caller toggles OPDS/sync while the server is already up.
    private var serveSync = true
    private var serveOPDS = false

    /// True while the running server serves the Stacks sync API.
    var isServingSync: Bool { isSharing && serveSync }
    /// True while the running server serves the OPDS catalog.
    var isServingOPDS: Bool { isSharing && serveOPDS }

    /// Starts sharing the given (home) library. Idempotent while sharing
    /// with the same configuration; restarts (brief downtime) when the
    /// feature flags or port change. Serves the repository the app already
    /// has open: one journal, one writer — local edits flow into the served
    /// sync stream and client commands serialize through the same journal.
    func start(
        library: LibraryConnection,
        port: Int,
        advertiseBonjour: Bool,
        username: String?,
        password: String?,
        serveSync: Bool,
        serveOPDS: Bool
    ) async {
        if isSharing, self.port == port, self.serveSync == serveSync, self.serveOPDS == serveOPDS {
            return
        }
        if isSharing {
            await stop()
        }
        self.port = port
        self.serveSync = serveSync
        self.serveOPDS = serveOPDS
        let server = await LibraryServer(repository: library.coreRepository, configuration: .init(
            port: port,
            libraryPath: library.coreRepository.root.path,
            indexesDirectory: nil,
            username: username,
            password: password,
            advertiseBonjour: advertiseBonjour,
            displayName: library.name,
            serveSync: serveSync,
            serveOPDS: serveOPDS
        ))
        do {
            try await server.start()
            self.server = server
            isSharing = true
            lastError = nil
        } catch {
            isSharing = false
            lastError = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    /// Stops sharing; safe to call while not sharing.
    func stop() async {
        await server?.stop()
        server = nil
        isSharing = false
    }

    /// The OPDS catalog address for OTHER devices on the network
    /// (e.g. `http://192.168.1.20:8080/opds`) — the URL a reader enters.
    var opdsAddressString: String {
        addressString + "/opds"
    }

    /// The LAN address clients connect to, e.g. `http://192.168.1.20:8080`.
    var addressString: String {
        guard let name = Host.current().localizedName else { return "http://localhost:\(port)" }
        // localizedName can contain spaces or non-hostname chars; keep the
        // copy button honest by resolving the first IPv4 address instead.
        var hint = "localhost"
        var addr: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(name, nil, nil, &addr) == 0, let addr {
            var pointer: UnsafeMutablePointer<addrinfo>? = addr
            while let current = pointer {
                if current.pointee.ai_family == AF_INET {
                    var address = current.pointee.ai_addr
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if let address {
                        if getnameinfo(address, socklen_t(current.pointee.ai_addrlen),
                                       &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            hint = String(cString: hostBuffer)
                            break
                        }
                    }
                }
                pointer = current.pointee.ai_next
            }
            freeaddrinfo(addr)
        }
        return "http://\(hint):\(port)"
    }
}

extension LibrarySession {
    /// Starts or stops the shared server to match the current settings — the
    /// single path for the Sharing pane's toggles, launch auto-start, and
    /// opening a library. The sync API and OPDS catalog are served
    /// independently: either preference on starts the server with that
    /// surface enabled. Returns false when sharing was requested but no home
    /// library is open (the pane surfaces the error; launch stays silent).
    @discardableResult
    func reconcileSharing() async -> Bool {
        let share = AppSettings.shareLibraryOverNetwork()
        let opds = AppSettings.shareOPDSOverNetwork()
        if share || opds {
            guard let home else { return false }
            let password = ShareCredentials.load()
            await sharing.start(
                library: home,
                port: AppSettings.sharePort(),
                advertiseBonjour: AppSettings.advertiseWithBonjour(),
                username: password == nil ? nil : AppSettings.shareUsername(),
                password: password,
                serveSync: share,
                serveOPDS: opds
            )
        } else {
            await sharing.stop()
        }
        return true
    }
}
