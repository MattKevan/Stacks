import Foundation
#if canImport(Network)
import Network

/// Advertises a library on the LAN via Bonjour (`_stacks._tcp`) with
/// TXT records: display name, library id, protocol version, and the OPDS +
/// sync API paths (mirrors Calibre's `path=/opds` TXT convention).
///
/// macOS-only: `Network` (Network.framework) is unavailable on Linux, where
/// the headless server runs with `--no-bonjour` and clients reach it by
/// host:port. The whole type is compiled out on Linux; `LibraryServer`
/// guards its usage with the same `canImport(Network)` check.
///
/// Uses `NetService` (macOS): it announces a port WITHOUT binding a socket,
/// so it can sit alongside the Hummingbird listener on the same port. Linux
/// gets an Avahi seam in the port plan.
public final class BonjourAdvertiser: LibraryAdvertiser, @unchecked Sendable {
    private let service: NetService

    public init(displayName: String, libraryID: UUID, port: Int, serveSync: Bool = true, serveOPDS: Bool = true) {
        let service = NetService(
            domain: "local.",
            type: "_stacks._tcp.",
            name: displayName,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: Self.txtRecord(
            name: displayName, libraryID: libraryID, serveSync: serveSync, serveOPDS: serveOPDS
        )))
        self.service = service
    }

    public func start() {
        service.publish()
    }

    public func stop() {
        service.stop()
    }

    /// The advertised TXT record — name, library id, protocol version, and
    /// the OPDS + sync API paths (each only when that surface is served).
    public static func txtRecord(name: String, libraryID: UUID, serveSync: Bool = true, serveOPDS: Bool = true) -> [String: Data] {
        var record: [String: Data] = [
            "name": Data(name.utf8),
            "id": Data(libraryID.uuidString.utf8),
            "v": Data("1".utf8),
        ]
        if serveSync {
            record["api"] = Data("/api".utf8)
        }
        if serveOPDS {
            record["path"] = Data("/opds".utf8)
        }
        return record
    }
}
#endif
