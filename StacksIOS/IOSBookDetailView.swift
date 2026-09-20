import StacksKit
import StacksSync
import SwiftUI

/// A book's detail screen: the same metadata the Mac shows in its right-hand
/// inspector (`BookInspectorView`), plus the actions that only make sense with
/// a second library in reach —
///
/// - **remote books** can be downloaded into the phone's own library;
/// - **home books** can be opened, or handed to another app (a reader) via the
///   share sheet.
///
/// Editing stays on the Mac: the editor surfaces are built around the home
/// repository's write path.
struct IOSBookDetailView: View {
    @Bindable var session: LibrarySession
    let book: IndexedBook

    @State private var isWorking = false
    @State private var statusMessage: String?

    private var remote: RemoteLibraryBrowser? { session.activeRemote }
    private var isRemoteContext: Bool { remote != nil }
    private var isInHomeLibrary: Bool {
        session.home?.books.contains { $0.id == book.id } ?? false
    }

    var body: some View {
        // The shared inspector IS the metadata body: same grid, same cover,
        // same HTML description handling. It reads the session's selection, so
        // the row tap sets that before pushing.
        BookInspectorView(session: session)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                actions
            }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await open() }
                } label: {
                    Label("Open", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if isRemoteContext || isInHomeLibrary {
                    shareButton
                }
            }
            if isRemoteContext {
                Button {
                    Task { await downloadToPhone() }
                } label: {
                    Label("Download to My Library", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking || session.home == nil)
            }
        }
        .padding()
        .background(.bar)
    }

    /// Hand the book's file to another app (a reader, Files, AirDrop). The
    /// file is materialized beside the library first, because a share needs a
    /// stable URL that outlives the call.
    private var shareButton: some View {
        Group {
            if isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let url = shareURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Materialized in `prepareShare()`; nil until then.
    @State private var shareURL: URL?

    // MARK: - Actions

    private func open() async {
        isWorking = true
        defer { isWorking = false }
        await session.browser?.open(id: book.id)
    }

    /// Downloads the remote book's first format and imports it into the phone's
    /// library through the standard pipeline (metadata extraction + content
    /// dedupe). The import report sheet covers the outcome.
    private func downloadToPhone() async {
        guard let remote, let home = session.home else { return }
        guard let format = book.formats.first else {
            statusMessage = "This book has no downloadable format."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await remote.remote.downloadFormat(
                id: book.id, format: format.kind.lowercased()
            )
            await session.importFiles(urls: [url])
            session.presentImportReport()
        } catch {
            remote.noteUnreachable(error)
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
        _ = home
    }

    /// Copies the book's file next to the library so it can be shared, then
    /// publishes the URL to the view.
    func prepareShare() async {
        guard shareURL == nil, let browser = session.browser else { return }
        if let source = browser.formatFileURL(for: book) {
            shareURL = source
            return
        }
        // Remote book: fetch it, then share the downloaded copy.
        guard let remote else { return }
        guard let format = book.formats.first else { return }
        do {
            shareURL = try await remote.remote.downloadFormat(
                id: book.id, format: format.kind.lowercased()
            )
        } catch {
            statusMessage = "Couldn't fetch the file to share."
        }
    }
}
