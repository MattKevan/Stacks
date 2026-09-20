import AppKit
import Observation
import StacksDevices
import StacksKit

/// The macOS-only feature cluster the shared session deliberately knows nothing
/// about: the MTP/IOUSBHost device store and the in-process library server.
/// Created by the app, injected into the environment, and read by the macOS
/// shell views. The iOS app simply never constructs one, which is why the
/// shared `LibrarySession` has no device or sharing concept.
@MainActor
@Observable
final class MacFeatures {
    let devices = DeviceManager()
    let sharing = SharingService()

    /// Wires the shared session's platform hooks to these stores. Called once
    /// at launch, before the first library opens.
    func attach(to session: LibrarySession) {
        session.onDeviceContextCleared = { [weak self] in
            self?.devices.selectedDeviceID = nil
        }
        session.onHomeChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await session.reconcileSharing(self.sharing) }
        }
    }
}

extension SystemNotifier {
    /// "Sent to device" summary with the unsent items listed (truncated).
    /// macOS-only: `SendReport` belongs to the device layer.
    static func postSendCompletion(report: SendReport) async -> Bool {
        var body = report.summary
        let issues = report.noCompatible + report.failed
        if !issues.isEmpty {
            let names = issues.prefix(4).map(\.title)
            body += " — not sent: " + truncated(names, extra: issues.count - names.count)
        }
        return await post(title: "Sent to device", body: body)
    }
}

// MARK: - macOS-only session actions

extension LibrarySession {
    /// Create New Library: NSSavePanel lets the user choose WHERE the library
    /// lives and NAME its folder. The open-panel flow this replaces could only
    /// pick an existing folder — it either created the library inside an
    /// arbitrary folder or hit `libraryAlreadyExists`. The panel returns
    /// <location>/<name>; the folder is created by `LibraryRepository.create`.
    func createNewLibrary() {
        let panel = NSSavePanel()
        panel.title = "Create New Library"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "My Library"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await createLibrary(at: url) }
    }

    // MARK: - Send to device

    /// Resolves each selected book's best stored format file (in the selected
    /// device's format-priority order) and sends them to the device. Books
    /// with no supported stored format get an explicit "no compatible format"
    /// row in the send report.
    func sendSelectionToDevice(using devices: DeviceManager) async {
        guard let repository = connection?.repository else { return }
        let folder = BookFolder(layout: .init(root: repository.root))
        let selectedBooks = books.filter { selection.contains($0.id) }
        var requests: [SendRequest] = []
        var noCompatible: [SendItem] = []
        for book in selectedBooks {
            var hasSupportedFormat = false
            for format in devices.selectedDevice?.profile.supportedFormats ?? [] {
                guard let record = book.formats.first(where: { $0.kind.lowercased() == format }) else {
                    continue
                }
                let url = await folder.formatFileURL(relativePath: book.relativePath, filename: record.filename)
                if FileManager.default.fileExists(atPath: url.path) {
                    requests.append(SendRequest(title: book.title, authors: book.authors, sourceURL: url, format: format))
                    hasSupportedFormat = true
                    break
                }
            }
            if !hasSupportedFormat {
                noCompatible.append(SendItem(title: book.title, status: .noCompatibleFormat))
            }
        }
        await devices.send(requests, noCompatible: noCompatible)
    }

    /// Sends files dropped onto a sidebar device row (Finder-style drag). Each
    /// URL is sent as-is when its extension is a format the device accepts;
    /// unsupported formats surface as "no compatible format" in the report.
    func sendFiles(urls: [URL], using devices: DeviceManager) async {
        var requests: [SendRequest] = []
        for url in urls {
            let format = url.pathExtension.lowercased()
            guard !format.isEmpty else { continue }
            requests.append(SendRequest(
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                format: format
            ))
        }
        await devices.send(requests)
    }

    /// Finder-style drag from a sidebar device row: clear the library
    /// selection, select the target device, then send the dropped files.
    /// Awaiting the device selection ensures the send targets the right
    /// device.
    func sendDroppedFiles(urls: [URL], to deviceID: UUID, using devices: DeviceManager) async {
        // Mutate the connection's facet state in place — the session shim
        // returns a copy, so a plain `facetNavigation.clear()` would be dropped.
        connection?.facetNavigation.clear()
        await devices.select(deviceID)
        await sendFiles(urls: urls, using: devices)
    }

    /// Selects a device in the sidebar; choosing a device clears the active
    /// library's facet so the detail area shows the device browser. The actual
    /// state transition (selection + book listing) happens in
    /// `DeviceManager.select` so selecting a device immediately loads its books.
    func selectDevice(_ id: UUID?, using devices: DeviceManager) {
        if id != nil {
            // Device mode: the browser context returns to home — clearing
            // activeLibraryID makes `activeLibrary` resolve to home while a
            // device is selected, so the home toolbar cluster (Add Books),
            // search, and sync bindings stay correct over the device listing.
            // Deselecting returns to home; the remotes' facet state is
            // preserved on their browsers, just not auto-restored.
            activeLibraryID = nil
            activeRemoteID = nil
            activeLibrary?.facetNavigation.clear()
            connection?.isShowingAudiobooks = false
        }
        Task { await devices.select(id) }
    }
}
