import Foundation

#if !canImport(Network)
// macOS-only content lives above; this file only exists on Linux.

#if canImport(Glibc)
import Glibc  // kill(2): SIGTERM is ignored by avahi-publish-service
#endif

/// Advertises a library over mDNS/DNS-SD on Linux via `avahi-publish-service`
/// (the standard Avahi CLI, `avahi-utils` package). Publishes the same
/// `_stacks._tcp` service with the same TXT records as the macOS
/// Network.framework advertiser, so clients (including the macOS app's
/// Shared sidebar, which browses `_stacks._tcp`) discover Linux servers
/// exactly like Mac ones.
///
/// Requires `avahi-daemon` running and `avahi-utils` installed. When either
/// is missing, `start()` degrades silently — the server still works, clients
/// just reach it by host:port.
final class AvahiAdvertiser: LibraryAdvertiser {
    private let displayName: String
    private let libraryID: UUID
    private let port: Int
    private let serveSync: Bool
    private let serveOPDS: Bool
    private var process: Process?

    init(displayName: String, libraryID: UUID, port: Int, serveSync: Bool = true, serveOPDS: Bool = true) {
        self.displayName = displayName
        self.libraryID = libraryID
        self.port = port
        self.serveSync = serveSync
        self.serveOPDS = serveOPDS
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avahi-publish-service")
        var arguments = [
            "-s", displayName,
            "_stacks._tcp",
            String(port),
            "id=\(libraryID.uuidString)",
            "v=1",
            "name=\(displayName)",
        ]
        if serveSync {
            arguments.append("api=/api")
        }
        if serveOPDS {
            arguments.append("path=/opds")
        }
        process.arguments = arguments
        // avahi-publish-service blocks until terminated; the server owns the
        // process for the service's lifetime.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
        } catch {
            // avahi-utils missing or avahi-daemon not running: advertiseBonjour
            // silently degrades to host:port access.
            self.process = nil
        }
    }

    /// Terminates the publisher.
    ///
    /// `avahi-publish-service` ignores SIGTERM, so a SIGTERM-only stop leaves
    /// it running: systemd waits out `TimeoutStopSec` (90s) before SIGKILLing
    /// the leftover on restart, and an ungraceful server exit orphans a live
    /// `_stacks._tcp` record pointing at a dead port. Give the polite signal a
    /// moment, then escalate.
    func stop() {
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            // Reap it: the signal is asynchronous, so without this the child
            // can outlive stop() and a restart races the old publisher for the
            // service name.
            process.waitUntilExit()
        }
    }
}
#endif
