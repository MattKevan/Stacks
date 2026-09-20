import StacksKit
import StacksDevices
import StacksSync
import StacksServerKit
import SwiftUI

/// Browser for a connected device's books: table with DRM badges, Import
/// Selected/All (through the existing library import pipeline), Refresh, and
/// Eject. The main content is a stable table / empty / error state — activity
/// (connection status, current operation, queued backlog) lives in the
/// toolbar activity popover (ContentView), never over the content. `onImported`
/// lets the host flip its import-report sheet after a device import completes.
struct DeviceBooksView: View {
    @Environment(MacFeatures.self) private var mac
    @Bindable var session: LibrarySession
    @State private var selection = Set<String>() // DeviceBookRecord ids
    var onImported: () -> Void = {}

    var body: some View {
        Group {
            if let error = mac.devices.deviceError, mac.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Read Device", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Scan Again") { Task { await mac.devices.scanForDevices() } }
                }
            } else if mac.devices.deviceBooks.isEmpty {
                ContentUnavailableView {
                    Label("No Books on Device", systemImage: "books.vertical")
                } description: {
                    Text(
                        mac.devices.isListing
                            ? "Reading the device…"
                            : "Send books from your library, or copy them onto the Kindle another way."
                    )
                }
            } else {
                Table(mac.devices.deviceBooks, selection: $selection) {
                    TableColumn("Title") { record in
                        HStack(spacing: 6) {
                            if record.isEnriched && record.isDRM {
                                Image(systemName: "lock").foregroundStyle(.secondary)
                            }
                            Text(record.title)
                            if !record.isEnriched && selection.contains(record.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .help("Fetching book details…")
                            }
                            if record.format == "KFX" {
                                Text("unsupported").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    TableColumn("Author") { record in Text(record.authors.joined(separator: ", ")) }
                    TableColumn("Format") { record in Text(record.format) }
                    TableColumn("Size") { record in
                        Text(ByteCountFormatter.string(fromByteCount: record.file.size, countStyle: .file))
                    }
                }
            }
        }
        .navigationTitle(mac.devices.devices.first { $0.id == mac.devices.selectedDeviceID }?.name ?? "Device")
        .onChange(of: selection) { _, newSelection in
            // Lazy detail: fetching metadata downloads the file (~24s per book
            // on the Kindle), so enrich only the selected row, never the whole
            // list. The spinner in the row stays until isEnriched flips.
            guard let first = newSelection.first,
                  let record = mac.devices.deviceBooks.first(where: { $0.id == first }),
                  !record.isEnriched else { return }
            Task { await mac.devices.enrich(record) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Import Selected") { importSelected() }
                    .disabled(selection.isEmpty || mac.devices.isBusy)
                    .help(
                        selection.isEmpty
                            ? "Select a book on the device to import it into the library"
                            : "Import the selected book(s) into the library"
                    )
                Button("Import All") { importAll() }
                    .disabled(mac.devices.deviceBooks.isEmpty || mac.devices.isBusy)
                    .help(
                        mac.devices.deviceBooks.isEmpty
                            ? "No books on the device to import"
                            : "Import every book on the device into the library"
                    )
                Button {
                    if let id = mac.devices.selectedDeviceID { Task { await mac.devices.refreshBooks() } }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(mac.devices.isBusy)
                Button {
                    if let id = mac.devices.selectedDeviceID { Task { await mac.devices.eject(id) } }
                } label: { Label("Eject", systemImage: "eject") }
                .disabled(mac.devices.isBusy)
            }
        }
    }

    // MARK: - Import

    private func importFiles(_ files: [DeviceFile]) {
        guard !files.isEmpty else { return }
        Task {
            // The download + conversion phases run as ONE queued device
            // operation; the toolbar activity popover shows "Importing
            // books…" with per-book progress, then "Converting to library
            // format…".
            let converted = await mac.devices.importBooks(files) { urls in
                await session.importFiles(urls: urls)
            }
            // Only flip the host's import-report sheet when conversion actually
            // ran; a failed download surfaces via the device error, not a blank
            // or stale report.
            if converted { onImported() }
        }
    }

    private func importSelected() {
        let files = mac.devices.deviceBooks
            .filter { selection.contains($0.id) }
            .map(\.file)
        importFiles(files)
    }

    private func importAll() {
        importFiles(mac.devices.deviceBooks.map(\.file))
    }
}
