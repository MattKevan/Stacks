import Foundation
import StacksCore
import Testing
@testable import Stacks

/// App-layer orchestration tests for the sidebar selection model: device,
/// remote, and home-library contexts are mutually exclusive. Regression
/// coverage for the "Kindle connected → Shared/home rows don't switch"
/// defect: `selectCategory`/`selectRemote` must exit device mode, or the
/// sidebar highlight and the detail pane disagree (the device view stays
/// up while the Shared row highlights, and the Library rows bounce back to
/// the device selection).
@MainActor
@Suite
struct LibrarySessionSelectionTests {
    private func makeSession() async throws -> (LibrarySession, LibraryConnection) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deviceID = UUID()
        _ = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: deviceID
        )
        let connection = try await LibraryConnection(
            openAt: root, indexesDirectory: indexes, deviceID: deviceID
        )
        let session = LibrarySession(
            deviceID: UUID(),
            bookmarks: LibraryBookmarkStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        session.home = connection
        return (session, connection)
    }

    @Test
    func homeCategorySelectionExitsDeviceMode() async throws {
        let (session, connection) = try await makeSession()
        defer { connection.stop() }
        // A connected, selected Kindle: the sidebar getter reports it as the
        // context. The device id is fabricated — selection state is what
        // matters, not a live transport.
        session.selectedDeviceID = UUID()

        // Sidebar click on "All Books" / a Library-section category.
        session.selectCategory(nil)

        #expect(session.selectedDeviceID == nil)
        #expect(session.activeRemoteID == nil)
        #expect(session.activeLibraryID == session.home?.id)
        // The browser context is home again.
        #expect(session.browser === session.home)
    }

    @Test
    func remoteSelectionExitsDeviceMode() async throws {
        let (session, connection) = try await makeSession()
        defer { connection.stop() }
        session.selectedDeviceID = UUID()

        // Sidebar click on a Shared-section remote (nil id = the "return to
        // home" transition, which runs the same device-clearing line as a
        // real remote id — the membership check only decides activeRemoteID).
        session.selectRemote(nil)

        #expect(session.selectedDeviceID == nil)
        #expect(session.activeRemoteID == nil)
    }

    @Test
    func deviceSelectionClearsRemoteAndLibraryContext() async throws {
        let (session, connection) = try await makeSession()
        defer { connection.stop() }
        session.selectCategory(.author)
        // A remote is the browser context (fabricated id — only the
        // clearing matters, not membership).
        session.activeRemoteID = UUID()

        // Selecting a device is the reverse transition: it must clear the
        // remote context so the device listing is the browser surface.
        session.selectDevice(UUID())

        #expect(session.activeRemoteID == nil)
    }
}
