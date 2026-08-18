import AppKit
import StacksCore
import Foundation
import Observation

/// View-mode enum moved out of LibrarySession so any browser can use it.
enum BrowserViewMode: String, CaseIterable, Identifiable {
    case table, grid
    var id: String { rawValue }
}

/// One open library connection: repository + browser state. The owning app
/// instance is the library's single writer; the journal is authoritative and
/// the catalog is a disposable index. Network connections to remote libraries
/// arrive in a later slice.
@MainActor
@Observable
final class LibraryConnection {
    let id: UUID                  // manifest.id
    /// Protocol witness: the browser surface sees the repository as optional
    /// (remote browsers have none); internal code uses `coreRepository`.
    var repository: LibraryRepository? { coreRepository }
    let coreRepository: LibraryRepository

    // Rebuild state
    var rebuildProgress: Double?
    var isRebuilding = false
    let cancelFlag = RebuildCancelFlag()

    // Browser state
    var books: [IndexedBook] = []
    var authors: [(value: String, count: Int)] = []
    var series: [(value: String, count: Int)] = []
    var tags: [(value: String, count: Int)] = []
    var formats: [(value: String, count: Int)] = []
    var deletedBooks: [IndexedBook] = []
    var missingFiles: [(book: IndexedBook, filename: String)] = []
    var facetNavigation = FacetNavigation()
    /// True while the Audiobooks sidebar context is active: the book list is
    /// filtered to books that have an audiobook format and the facet middle
    /// column is hidden (facet selection stays cleared in this mode).
    var isShowingAudiobooks = false
    /// Toolbar sort order; re-sorts the loaded books immediately on change.
    var sortOrder: BrowserSortOrder = .name {
        didSet {
            guard oldValue != sortOrder else { return }
            sortBooks()
        }
    }
    var searchText = "" {
        didSet {
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await refreshBooks()
            }
        }
    }
    var selection = Set<UUID>()
    /// The anchor for ⇧-click range selection in the grid. Ignored by the
    /// table view (which manages its own selection semantics natively).
    var selectionAnchor: UUID?
    /// True while a grid marquee drag is in flight; suppresses the inspector's
    /// click-driven auto-show so a mid-drag single selection doesn't pop it open.
    var isMarqueeSelecting = false
    var viewMode: BrowserViewMode = .grid
    /// Books queued for the metadata editor (home library only in this slice).
    var metadataEditQueue: [IndexedBook]?
    /// Book ids awaiting delete confirmation; nil when nothing is pending.
    /// Set by `requestDelete`, consumed by the confirmation alert, then
    /// cleared before `delete(ids:)` runs.
    var pendingDelete: Set<UUID>?

    private var searchTask: Task<Void, Never>?
    let deviceID: UUID
    private let indexesDirectory: URL

    /// Session wiring — set once by `LibrarySession` after creating the
    /// connection. Keeps the connection decoupled from the session hub.
    /// - `onLoadFailure`: a browse/load failure that takes down the loaded
    ///   state.
    /// - `onError`: an error worth surfacing in the session's alert.
    /// - `onSelectionChange`: a library-side selection change; the session
    ///   clears the device selection domain.
    var onLoadFailure: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onSelectionChange: (() -> Void)?

    var name: String { coreRepository.root.lastPathComponent }
    /// The journal's current sequence number (diagnostics; refreshed by
    /// `reloadDiagnostics`).
    var journalSeq: Int64 = 0
    /// Shared-FS availability is gone with the sync layer; the single writer
    /// owns its library, so the local connection is always available. The
    /// network slice re-adds live status for remote connections.
    var isLibraryUnavailable: Bool { false }
    /// The library books backing the current selection, in catalog order —
    /// the order the batch metadata editor walks its “1 of N” queue in.
    var selectionBooks: [IndexedBook] { books.filter { selection.contains($0.id) } }

    init(openAt url: URL, indexesDirectory: URL, deviceID: UUID) async throws {
        let repository = try await LibraryRepository.open(
            at: url, indexesDirectory: indexesDirectory, deviceID: deviceID
        )
        self.coreRepository = repository
        self.id = coreRepository.manifest.id
        self.deviceID = deviceID
        self.indexesDirectory = indexesDirectory
        await refreshAll()
    }

    /// Cancels the pending search debounce. Called when the connection is
    /// dropped (library closed or switched).
    func stop() {
        searchTask?.cancel()
        searchTask = nil
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        isRebuilding = true
        rebuildProgress = 0
        defer {
            isRebuilding = false
            rebuildProgress = nil
            cancelFlag.requested = false
        }
        do {
            _ = try await coreRepository.rebuildCatalog(
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.rebuildProgress = value
                    }
                },
                cancelled: { [cancelFlag] in cancelFlag.requested }
            )
        } catch LibraryRepositoryError.rebuildCancelled {
            onError?("Rebuild cancelled.")
        } catch {
            onError?(error.localizedDescription)
        }
        await refreshAll()
    }

    func cancelRebuild() {
        cancelFlag.requested = true
    }

    func reloadDiagnostics() async {
        missingFiles = (try? await coreRepository.missingFormatFiles()) ?? []
        journalSeq = await coreRepository.journalSeq()
        await refreshDeleted()
    }

    // MARK: - Loading

    func refreshAll() async {
        await refreshBooks()
        await refreshFacets()
        await refreshDeleted()
    }

    func refreshBooks() async {
        do {
            let result: [IndexedBook]
            if let facet = facetNavigation.activeFacet {
                result = try await coreRepository.books(facetType: facet.type, value: facet.value)
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = try await coreRepository.books()
            } else {
                // A malformed FTS5 query (unclosed quote, stray operator) must not
                // take down the loaded browser: on a search error, show no results
                // while keeping the library state intact.
                do {
                    result = try await coreRepository.search(searchText)
                } catch {
                    books = []
                    sortBooks()
                    return
                }
            }
            // The Audiobooks context narrows whatever the base query returned
            // (all books or search matches) to books with an audio format.
            books = isShowingAudiobooks
                ? result.filter { $0.formats.contains { AudioFormats.isAudio($0.kind) } }
                : result
        } catch {
            onLoadFailure?(error.localizedDescription)
        }
        sortBooks()
    }

    /// Applies the toolbar sort order to the loaded books (SQL orders by
    /// title; client-side re-sort keeps one code path for all branches).
    private func sortBooks() {
        switch sortOrder {
        case .name:
            books.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateAdded:
            books.sort { ($0.addedMilliseconds ?? 0) > ($1.addedMilliseconds ?? 0) }
        }
    }

    func refreshFacets() async {
        authors = (try? await coreRepository.facetCounts(.author)) ?? []
        series = (try? await coreRepository.facetCounts(.series)) ?? []
        tags = (try? await coreRepository.facetCounts(.tag)) ?? []
        formats = (try? await coreRepository.facetCounts(.format)) ?? []
    }

    func refreshDeleted() async {
        deletedBooks = (try? await coreRepository.deletedBooks()) ?? []
    }

    // MARK: - Facets and search

    /// Sidebar click on a facet category (Authors/Series/Tags/Formats).
    /// `nil` selects All Books. Selecting any library view deselects a
    /// connected device — the two selection domains are mutually exclusive.
    /// Any category click also exits the Audiobooks context (All Books and
    /// the categories are one domain; Audiobooks is its own view).
    func selectCategory(_ type: FacetType?) {
        onSelectionChange?()
        isShowingAudiobooks = false
        facetNavigation.selectCategory(type)
        Task { await refreshBooks() }
    }

    /// Sidebar click on the Audiobooks row: filters the book list to books
    /// with an audio format and clears any facet selection (the facet middle
    /// column hides for this view). The reverse transition — clicking any
    /// category or All Books — exits via `selectCategory`.
    func showAudiobooks(_ show: Bool = true) {
        onSelectionChange?()
        guard show != isShowingAudiobooks else { return }
        isShowingAudiobooks = show
        if show {
            facetNavigation.clear()
        }
        Task { await refreshBooks() }
    }

    /// Middle-column click on a specific value. Re-clicking the same value
    /// toggles it off, back to all books.
    func selectValue(_ value: String?) {
        facetNavigation.selectValue(value)
        Task { await refreshBooks() }
    }

    /// macOS grid-click semantics: plain click replaces, ⌘ toggles, ⇧ selects
    /// the anchor→clicked range. Reads the modifier flags at gesture time.
    func selectInGrid(_ book: IndexedBook) {
        let flags = NSEvent.modifierFlags
        let modifier: GridSelectionModifier = flags.contains(.command)
            ? .command
            : (flags.contains(.shift) ? .shift : .none)
        let result = GridSelectionSemantics.applying(
            click: book.id,
            modifier: modifier,
            anchor: selectionAnchor,
            visible: books.map(\.id),
            selection: selection
        )
        selection = result.selection
        if let anchor = result.anchor {
            selectionAnchor = anchor
        }
    }

    /// Empty-space click: clear the selection and the range anchor.
    func clearGridSelection() {
        selection = []
        selectionAnchor = nil
    }

    // MARK: - Delete / restore

    /// Asks for confirmation before deleting the given books: stores the ids
    /// in `pendingDelete` for the confirmation alert. The actual `delete(ids:)`
    /// runs only after the user confirms.
    func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    func delete(ids: Set<UUID>) async {
        for id in ids {
            do {
                try await coreRepository.deleteBook(id: id)
            } catch {
                onError?(error.localizedDescription)
            }
        }
        selection.removeAll()
        await refreshAll()
    }

    func restore(id: UUID) async {
        do {
            _ = try await coreRepository.restoreBook(id: id)
        } catch {
            onError?(error.localizedDescription)
        }
        await refreshAll()
    }

    // MARK: - Open / reveal

    func open(id: UUID) async {
        do {
            guard let book = try await coreRepository.book(id: id) else { return }
            var url = try await coreRepository.formatFileURL(id: id)
            // Mixed-format books (ebook + audiobook) open the audio file from
            // the Audiobooks context — the view is about listening.
            if isShowingAudiobooks, let audioURL = audioFormatFileURL(for: book) {
                url = audioURL
            }
            guard let url else { return }
            NSWorkspace.shared.open(url)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func reveal(id: UUID) async {
        do {
            guard let url = try await coreRepository.bookFolderURL(id: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// The first existing format file for a book, used to make library rows
    /// draggable (drag onto a device row sends that file). Computed directly
    /// from the layout (pure path math, mirrors `BookFolder.formatFileURL`) so
    /// the synchronous drag handler needs no actor hop. In the Audiobooks
    /// context the audio file is preferred (a mixed-format book drags its
    /// audiobook).
    func formatFileURL(for book: IndexedBook) -> URL? {
        if isShowingAudiobooks, let url = audioFormatFileURL(for: book) {
            return url
        }
        let root = LibraryLayout(root: coreRepository.root).root
        for format in book.formats {
            let url = root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: format.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// The first existing audiobook format file for a book, or nil when it
    /// has none on disk.
    private func audioFormatFileURL(for book: IndexedBook) -> URL? {
        let root = LibraryLayout(root: coreRepository.root).root
        for format in book.formats where AudioFormats.isAudio(format.kind) {
            let url = root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: format.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
