import Foundation
import Observation
import StacksKit
import StacksSync

/// A connected remote library, browsed over the sync protocol. The grid,
/// table, and facet views are generic over `LibraryBrowser`, so a remote
/// behaves like a local library — except covers come from the server and
/// edits/opens go over the network. Read-only metadata editing of remote
/// books is a follow-up; browse, open, and delete are live.
@MainActor
@Observable
final class RemoteLibraryBrowser: LibraryBrowser, Identifiable {
    let id: UUID
    var name: String
    let remote: RemoteLibrary

    var repository: LibraryRepository? { nil }

    private var remoteBooks: [IndexedBook] = []
    /// Incremented whenever `remoteBooks` changes. Every derived list caches
    /// against this rather than comparing the array, so cache validation is
    /// O(1) instead of O(n) — the array compare would cost as much as the work
    /// being cached.
    private var snapshotGeneration = 0
    var pendingDelete: Set<UUID>?
    var isLibraryUnavailable: Bool { false }
    var selection = Set<UUID>()
    var selectionAnchor: UUID?
    var isMarqueeSelecting = false
    var viewMode: BrowserViewMode = .grid
    var metadataEditQueue: [IndexedBook]? = nil

    /// The pure client browse state (search/facet/sort) extracted into core.
    /// Stored (not `let`) so `@Observable` tracks nested mutations — the
    /// grid/table/search views re-render as the model changes.
    private var model = BookBrowserModel()

    /// Facet selection (sidebar category + middle-column value).
    var facetNavigation: FacetNavigation {
        get { model.facetNavigation }
        set { model.facetNavigation = newValue }
    }

    /// The Audiobooks context: filters the pulled snapshot to books with an
    /// audiobook format (core `BookBrowserModel.audioOnly`).
    var isShowingAudiobooks: Bool {
        get { model.audioOnly }
        set { model.audioOnly = newValue }
    }

    /// Search text for the client-side filter.
    var searchText: String {
        get { model.searchText }
        set { model.searchText = newValue }
    }

    /// Toolbar sort order (Name or Date added); applies in grid and table.
    var sortOrder: BrowserSortOrder {
        get { model.sortOrder }
        set { model.sortOrder = newValue }
    }

    /// Commands waiting in the durable offline queue (badge in the Shared
    /// sidebar row).
    func pendingCount() async -> Int {
        await remote.pendingOfflineCount()
    }

    /// Uploads book files to the server: metadata is extracted from each
    /// file (title/authors/series/tags/…), the bytes staged, and an addBook
    /// command pushed — the server materializes the book. Unreachable pushes
    /// queue durably and land on reconnect.
    func importFiles(
        urls: [URL],
        progress: @escaping (Int, Int, String?) -> Void = { _, _, _ in },
        onFailure: @escaping (String) -> Void = { _ in }
    ) async {
        let total = urls.count
        var completed = 0
        for url in urls {
            guard let kind = MetadataExtractor.kind(for: url),
                  let data = try? Data(contentsOf: url) else { continue }
            let extracted = try? MetadataExtractor.extract(from: url, kind: kind)
            let title = extracted?.title ?? url.deletingPathExtension().lastPathComponent
            let filename = url.lastPathComponent
            let staged = JournalCommand.StagedFormat(
                kind: kind.rawValue,
                filename: filename,
                contentHash: BookFolder.contentHash(data),
                size: Int64(data.count),
                stagedName: filename
            )
            // The embedded cover rides along (staged like the format), so
            // uploaded books show a real cover instead of the placeholder.
            var stagedFiles = [filename: data]
            var cover: JournalCommand.StagedCover?
            if let coverData = try? MetadataExtractor.extractCover(from: url, kind: kind) {
                let coverName = "cover.jpg"
                cover = JournalCommand.StagedCover(
                    filename: coverName,
                    contentHash: BookFolder.contentHash(coverData),
                    stagedName: coverName
                )
                stagedFiles[coverName] = coverData
            }
            let addBook = JournalCommand.AddBook(
                bookID: UUID(),
                title: title,
                authors: extracted?.authors ?? [],
                series: extracted?.series,
                seriesIndex: extracted?.seriesIndex,
                tags: extracted?.tags ?? [],
                rating: nil,
                publisher: extracted?.publisher,
                publicationDate: extracted?.publicationDate,
                addedDate: .now,
                languages: extracted?.languages ?? [],
                identifiers: extracted?.identifiers ?? [:],
                comments: extracted?.comments,
                formats: [staged],
                cover: cover
            )
            progress(completed, total, title)
            let outcome = try? await remote.push(
                ClientCommand(id: UUID(), op: .addBook(addBook)),
                stagedFiles: stagedFiles
            )
            switch outcome {
            case .applied, .queued:
                // Applied now, or durably queued for reconnect — either way
                // the book is on its way; the Shared-row badge tracks queued.
                completed += 1
            case nil:
                onFailure("\(title): server rejected the upload")
            }
            progress(completed, total, title)
        }
        if completed > 0 {
            await refreshBooks()
        }
    }

    /// Longest edge for a downloaded cover, matching the local thumbnail
    /// pipeline (`ThumbnailCache`) so remote and home covers render at the same
    /// resolution.
    private static let coverPixelSize = 640

    /// Caps concurrent cover downloads across every remote browser. Four keeps
    /// the grid filling briskly while leaving the connection free for the
    /// sync pull.
    private static let coverGate = AsyncGate(limit: 4)

    private var coverCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 512
        return cache
    }()

    init(discovered: DiscoveredLibrary, credential: RemoteLibrary.Credential?) throws {
        id = discovered.id
        name = discovered.name
        remote = try RemoteLibrary(configuration: .init(
            baseURL: discovered.baseURL,
            credential: credential,
            queueDirectory: Self.queueDirectory(libraryID: discovered.id)
        ))
    }

    /// The durable offline-queue location for this remote library.
    static func queueDirectory(libraryID: UUID) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Stacks", directoryHint: .isDirectory)
            .appending(path: "remote-queues", directoryHint: .isDirectory)
            .appending(path: libraryID.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - LibraryBrowser

    /// Search + facet filtering applied client-side over the pulled books
    /// (the home library filters in SQL; the remote has only the pulled
    /// snapshot, so the same UX is a local filter). The filter+sort itself is
    /// the core `BookBrowserModel` — identical results, now testable.
    ///
    /// Memoized: the view reads `books` many times per render pass, and the
    /// filter+sort is O(n log n) in the library, so recomputing per read made
    /// large remote libraries slow to scroll. The cache is keyed on the model's
    /// inputs and the snapshot identity, so it invalidates exactly when either
    /// changes.
    var books: [IndexedBook] {
        let key = "\(snapshotGeneration)\u{1}\(model.cacheKey)"
        if let cached = booksCache, cached.key == key {
            return cached.books
        }
        let computed = model.books(from: remoteBooks)
        booksCache = (key: key, books: computed)
        return computed
    }

    private var booksCache: (key: String, books: [IndexedBook])?
    var selectionBooks: [IndexedBook] { books.filter { selection.contains($0.id) } }

    var authors: [(value: String, count: Int)] { facetCounts(.author) }
    var series: [(value: String, count: Int)] { facetCounts(.series) }
    var tags: [(value: String, count: Int)] { facetCounts(.tag) }
    var formats: [(value: String, count: Int)] { facetCounts(.format) }

    /// Facet value counts, computed once per snapshot.
    ///
    /// Memoized for the same reason as `books`: the sidebar reads all four
    /// lists and `FacetListView` reads its active one twice per render
    /// (`values` then `filteredValues`), so an unmemoized walk over every book
    /// ran several full O(n) passes — with a sort — on every render pass.
    ///
    /// One pass builds all four maps, and the cache holds them together keyed
    /// on the snapshot, so reading series right after authors costs nothing.
    private func facetCounts(_ type: FacetType) -> [(value: String, count: Int)] {
        if let cached = facetCache, cached.generation == snapshotGeneration {
            return cached.lists[type] ?? []
        }
        let computed = FacetCounts(of: remoteBooks)
        facetCache = (generation: snapshotGeneration, lists: computed.lists)
        return computed.lists[type] ?? []
    }

    private var facetCache: (generation: Int, lists: [FacetType: [(value: String, count: Int)]])?

    /// All four facet lists in a single pass over the books.
    private struct FacetCounts {
        let lists: [FacetType: [(value: String, count: Int)]]

        init(of allBooks: [IndexedBook]) {
            var authors: [String: Int] = [:]
            var series: [String: Int] = [:]
            var tags: [String: Int] = [:]
            var formats: [String: Int] = [:]
            for book in allBooks where !book.isDeleted {
                for author in book.authors { authors[author, default: 0] += 1 }
                if let value = book.series, !value.isEmpty { series[value, default: 0] += 1 }
                for tag in book.tags { tags[tag, default: 0] += 1 }
                for format in book.formats { formats[format.kind, default: 0] += 1 }
            }
            lists = [
                .author: Self.sorted(authors),
                .series: Self.sorted(series),
                .tag: Self.sorted(tags),
                .format: Self.sorted(formats),
            ]
        }

        private static func sorted(_ counts: [String: Int]) -> [(value: String, count: Int)] {
            counts.map { (value: $0.key, count: $0.value) }
                .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        }
    }

    /// Whether the server last answered a request. False once something
    /// fails unreachably — the sidebar shows the drop and edits queue
    /// offline until a successful refresh.
    var isConnected = true

    func refreshBooks() async {
        try? await refreshBooksThrowing()
    }

    /// The throwing variant: the connect flow needs the failure (401 →
    /// credential prompt, unreachable → error) instead of a silent empty
    /// library.
    func refreshBooksThrowing() async throws {
        do {
            try await remote.pull()
            isConnected = true
            remoteBooks = await remote.books()
            // Bumping a counter is the cache key for every derived list below
            // (filtered books, facet counts). Comparing the arrays themselves
            // would be an O(n) element-wise scan on every read — the same order
            // as the work the caches exist to avoid.
            snapshotGeneration &+= 1
            // Housekeeping, once per refresh rather than per cover: an
            // abandoned server's cache should not grow without limit.
            if !hasSweptCovers {
                hasSweptCovers = true
                Task.detached(priority: .background) {
                    await Self.diskCoverCache.sweep()
                }
            }
        } catch {
            noteUnreachable(error)
            throw error
        }
    }

    /// The disk sweep runs once per browser instance (per session), not on
    /// every refresh.
    private var hasSweptCovers = false

    /// Marks the connection dropped when the error is a network failure
    /// (server unreachable). HTTP errors mean the server is up — those are
    /// not a connection drop.
    func noteUnreachable(_ error: Error) {
        if let remoteError = error as? RemoteLibrary.RemoteError,
           case .unreachable(_) = remoteError {
            isConnected = false
        }
    }

    func open(id: UUID) async {
        guard let book = await remote.book(id: id) else { return }
        // Mixed-format books open their audiobook from the Audiobooks context.
        let format = (isShowingAudiobooks
            ? book.formats.first(where: { AudioFormats.isAudio($0.kind) })
            : nil) ?? book.formats.first
        guard let format else { return }
        do {
            let url = try await remote.downloadFormat(id: id, format: format.kind.lowercased())
            PlatformServices.openExternally(url)
        } catch {
            // Surfaced via a session error in a follow-up; silently ignored v1.
        }
    }

    func reveal(id: UUID) async {
        await open(id: id)
    }

    func formatFileURL(for book: IndexedBook) -> URL? {
        nil // remote drag-out is a follow-up
    }

    func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    func delete(ids: Set<UUID>) async {
        for id in ids {
            _ = try? await remote.push(ClientCommand(id: UUID(), op: .deleteBook(.init(bookID: id))))
        }
        selection.removeAll()
        await refreshBooks()
    }

    func restore(id: UUID) async {
        _ = try? await remote.push(ClientCommand(id: UUID(), op: .restoreBook(.init(bookID: id))))
        await refreshBooks()
    }

    func clearGridSelection() {
        selection = []
        selectionAnchor = nil
    }

    func selectCategory(_ type: FacetType?) {
        model.audioOnly = false
        facetNavigation.selectCategory(type)
        Task { await refreshBooks() }
    }

    func selectValue(_ value: String?) {
        facetNavigation.selectValue(value)
        Task { await refreshBooks() }
    }

    func selectInGrid(_ book: IndexedBook) {
        let modifier: GridSelectionModifier = PlatformServices.isCommandDown
            ? .command
            : (PlatformServices.isShiftDown ? .shift : .none)
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

    func coverImage(for book: IndexedBook) async -> PlatformImage? {
        if let cached = coverCache.object(forKey: book.id.uuidString as NSString) {
            return cached
        }
        // Disk before network: covers are immutable per (server, book id), so a
        // persisted copy means a relaunch shows them immediately instead of
        // re-downloading the whole shelf.
        if let image = await Self.diskCoverCache.image(for: book.id, serverID: id) {
            coverCache.setObject(image, forKey: book.id.uuidString as NSString)
            return image
        }
        // Throttled: a grid of visible tiles would otherwise open one cover
        // request per tile at once, saturating the connection and starving the
        // sync pull that refreshes the list. Covers are decorative, so they
        // queue behind a small concurrency limit.
        await Self.coverGate.wait()
        defer { Task { await Self.coverGate.signal() } }
        // Another tile may have completed this fetch while we queued.
        if let cached = coverCache.object(forKey: book.id.uuidString as NSString) {
            return cached
        }
        // NO `coverHash` guard here. `coverHash` is nil for every remote book:
        // the sync API streams journal COMMANDS, and the client's projector
        // rebuilds title/authors/formats from them but never a cover hash. The
        // old guard therefore rejected every remote cover — which is why the
        // grid could show one (a stale cache entry) while the detail view never
        // could. The server is the authority: a 404 means no cover.
        guard let data = try? await remote.downloadCover(id: book.id), !data.isEmpty else {
            return nil
        }
        // Downsample OFF the main actor. `CoverDecoder.decode` is a synchronous
        // ImageIO downsample + PNG re-encode, and this class is @MainActor, so
        // running it here blocked the main thread once per tile as the grid
        // scrolled — the cause of judder on remote libraries, where every tile
        // needs a fetch+decode. Byte-sized input, so the hop is cheap.
        let image = await Self.decodeCover(data)
        guard let image else { return nil }
        coverCache.setObject(image, forKey: book.id.uuidString as NSString)
        // Persist for the next launch. Fire-and-forget: the decode path must
        // not wait on disk I/O.
        let bytes = data
        let serverID = id
        let bookID = book.id
        Task.detached(priority: .utility) {
            await Self.diskCoverCache.store(bytes, for: bookID, serverID: serverID)
        }
        return image
    }

    /// Decodes cover bytes to a display image off the main actor.
    ///
    /// `nonisolated` so it runs on the cooperative pool rather than the main
    /// thread: the decode is CPU-bound (ImageIO downsample + re-encode), and a
    /// grid scrolling through a remote shelf decodes on every tile appearance.
    ///
    /// Sized to the tile, not the source: the iOS grid renders covers at
    /// roughly 256 physical pixels, so decoding to 640 wasted both the decode
    /// and the per-frame resample. macOS keeps the larger size because its
    /// covers scale with the window.
    private nonisolated static func decodeCover(_ data: Data) async -> PlatformImage? {
        let pixelSize = await Self.coverDecodePixelSize
        return await Task.detached(priority: .userInitiated) {
            let decoded = CoverDecoder.decode(data: data, maxPixelSize: pixelSize)
                .flatMap { PlatformImage(data: $0) }
            return decoded ?? PlatformImage(data: data)
        }.value
    }

    /// Longest edge to decode a cover at: the tile's rendered size, with
    /// headroom, rather than the source resolution.
    private static var coverDecodePixelSize: Int {
        #if os(iOS)
        // ~85pt tiles at @3x, doubled for margin (a larger device or a
        // future single-column layout).
        256
        #else
        640
        #endif
    }

    /// On-disk cover cache, shared by every remote browser.
    private static let diskCoverCache = RemoteCoverCache()
}

/// Covers fetched from a remote server, cached on disk.
///
/// In-memory caching alone means every relaunch re-downloads every cover in the
/// shelf. Covers are effectively immutable — a book's cover changes only when
/// its metadata is edited, which the server reports as a new cover — so they
/// are cached per (server id, book id) with no expiry, and bounded by a
/// least-recently-modified sweep rather than a size limit that could evict a
/// cover the user is looking at.
actor RemoteCoverCache {
    /// Covers older than this are swept on write. Long, because they rarely
    /// change and re-downloading is the cost being avoided.
    private static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    /// Upper bound on cached files, so an abandoned server cannot grow without
    /// limit. Well above a typical shelf.
    private static let maxEntries = 5_000

    private var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Stacks", directoryHint: .isDirectory)
            .appending(path: "remote-covers", directoryHint: .isDirectory)
    }

    private func fileURL(for bookID: UUID, serverID: UUID) -> URL {
        directory
            .appending(path: serverID.uuidString, directoryHint: .isDirectory)
            .appending(path: "\(bookID.uuidString).img")
    }

    func image(for bookID: UUID, serverID: UUID) -> PlatformImage? {
        let url = fileURL(for: bookID, serverID: serverID)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Touch so the sweep sees it as recently used.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return PlatformImage(data: data)
    }

    func store(_ data: Data, for bookID: UUID, serverID: UUID) {
        let url = fileURL(for: bookID, serverID: serverID)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Removes covers not read within `maxAge`, then the oldest beyond
    /// `maxEntries`. Called after a write; a no-op on the common path.
    func sweep() {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "img",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate else { continue }
            entries.append((url, modified))
        }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        for entry in entries where entry.modified < cutoff {
            try? fileManager.removeItem(at: entry.url)
        }
        let survivors = entries.filter { $0.modified >= cutoff }
            .sorted { $0.modified > $1.modified }
        for entry in survivors.dropFirst(Self.maxEntries) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
