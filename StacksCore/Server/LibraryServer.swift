import Foundation
import Hummingbird
import NIOCore
import Logging
import ServiceLifecycle
import StacksKit
import StacksSync

/// The shared library server: the journal engine exposed over HTTP. One
/// instance per library; the owning process (macOS app or the headless CLI)
/// is the single writer — clients push commands and pull records, the server
/// serializes appends and never merges.
/// Errors thrown during server construction.
public enum ServerConfigurationError: Error, Equatable {
    /// The standalone init needs an indexes directory; the embedded init
    /// (existing repository) does not take one.
    case missingIndexesDirectory
}

/// The advertising surface shared by the two platform backends: macOS uses
/// Network.framework (`BonjourAdvertiser`), Linux shells out to Avahi's
/// `avahi-publish-service` (`AvahiAdvertiser`). Both publish the same
/// `_stacks._tcp` service with the same TXT records, so clients see
/// every server identically.
protocol LibraryAdvertiser: AnyObject {
    func start()
    func stop()
}

public actor LibraryServer {
    private let repository: LibraryRepository
    private let configuration: ServerConfiguration

    /// The standalone path: the server opens the library itself (headless
    /// CLI, tests). Indexes must be server-owned.
    public init(configuration: ServerConfiguration) async throws {
        self.configuration = configuration
        guard let indexesDirectory = configuration.indexesDirectory else {
            throw ServerConfigurationError.missingIndexesDirectory
        }
        let root = URL(fileURLWithPath: configuration.libraryPath)
        repository = try await LibraryRepository.open(
            at: root,
            indexesDirectory: indexesDirectory,
            deviceID: UUID()
        )
    }

    /// The embedded path (macOS app's Sharing pane): serves the repository
    /// the app already has open. One repository, one journal, one writer —
    /// the app's local edits flow into the served sync stream automatically
    /// and clients' pushed commands serialize through the same journal.
    public init(repository: LibraryRepository, configuration: ServerConfiguration) async {
        self.repository = repository
        self.configuration = configuration
    }

    /// Builds the Hummingbird application (testable in-process via
    /// HummingbirdTesting; the CLI runs it with `run()`).
    public func makeApplication() throws -> some ApplicationProtocol {
        // OPDS readers (KOReader does this before every feed fetch) issue a
        // HEAD before the GET; without this a HEAD gets a 404.
        let router = Router(options: .autoGenerateHeadEndpoints)
        router.middlewares.add(BasicAuthMiddleware(
            username: configuration.username, password: configuration.password
        ))
        let repository = self.repository
        let displayName = self.displayName

        // MARK: - Sync protocol
        if configuration.serveSync {

        router.get("api/identity") { _, _ -> LibraryIdentity in
            LibraryIdentity(
                id: repository.manifest.id,
                name: displayName,
                version: repository.manifest.formatVersion
            )
        }

        router.get("api/sync") { request, _ -> SyncPullResponse in
            let after = request.uri.queryParameters.get("after").flatMap(Int64.init) ?? 0
            let seq = await repository.journalSeq()
            let commands = try await repository.journalRecords(after: after)
            return SyncPullResponse(seq: seq, commands: commands)
        }

        router.post("api/commands") { request, context -> SyncPushResponse in
            // The context decoder (ISO-8601 dates) matches the response
            // encoder — the push and pull use the same date representation.
            let payload = try await request.decode(as: SyncPushRequest.self, context: context)
            var applied: [Int64] = []
            var errors: [SyncPushResponse.CommandError] = []
            for (index, command) in payload.commands.enumerated() {
                let journalCommand = JournalCommand(id: command.id, seq: 0, ts: .now, op: command.op)
                do {
                    if let seq = try await repository.ingest(journalCommand) {
                        applied.append(seq)
                    }
                } catch {
                    errors.append(SyncPushResponse.CommandError(
                        index: index, message: error.localizedDescription
                    ))
                }
            }
            return SyncPushResponse(applied: applied, errors: errors)
        }

        router.post("api/stage") { request, _ -> StageResponse in
            guard let commandID = request.uri.queryParameters.get("command").flatMap(UUID.init(uuidString:)),
                  let stagedName = request.uri.queryParameters.get("name"),
                  !stagedName.isEmpty else {
                throw HTTPError(.badRequest, message: "command and name query parameters are required")
            }
            var request = request
            let buffer = try await request.collectBody(upTo: 2 << 30)
            let data = Data(buffer: buffer)
            try await repository.stageUploadedFile(data, commandID: commandID, stagedName: stagedName)
            return StageResponse(stagedName: stagedName, size: Int64(data.count))
        }

        // MARK: - Files

        // Two download shapes share one implementation: `?format=` (the app and
        // sync clients) and the extension-terminated `…/download/<filename>`
        // that OPDS readers need, since they infer the format from the URL's
        // last path extension.
        let fileResponse: @Sendable (UUID, String?) async throws -> Response = { bookID, format in
            try await Self.bookFileResponse(repository: repository, bookID: bookID, format: format)
        }

        router.get("api/books/:id/download") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
                throw HTTPError(.badRequest)
            }
            return try await fileResponse(id, request.uri.queryParameters.get("format"))
        }

        // OPDS acquisition target: the trailing name is informational, but it
        // must be a single path segment ending in the format's extension.
        router.get("api/books/:id/download/:filename") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)),
                  let rawName = context.parameters.get("filename"),
                  let filename = rawName.removingPercentEncoding,
                  !filename.isEmpty,
                  !filename.contains("/"),
                  !filename.contains("..") else {
                throw HTTPError(.badRequest)
            }
            let ext = (filename as NSString).pathExtension.lowercased()
            return try await fileResponse(id, ext.isEmpty ? nil : ext)
        }

        router.get("api/books/:id/cover") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)),
                  let book = try await repository.book(id: id),
                  book.coverHash != nil else {
                throw HTTPError(.notFound)
            }
            let root = LibraryLayout(root: repository.root).root
            let coverURL = root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: "cover.jpg")
            guard FileManager.default.fileExists(atPath: coverURL.path),
                  let data = try? Data(contentsOf: coverURL) else {
                throw HTTPError(.notFound)
            }
            var response = Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
            response.headers[.contentType] = "image/jpeg"
            return response
        }
        }

        // MARK: - OPDS (third-party readers)
        if configuration.serveOPDS {

        // Every OPDS body is Atom or an OpenSearch description; the matching
        // Content-Type (with charset) goes on the wire, not text/plain.
        router.get("opds") { request, _ -> Response in
            Self.opdsResponse(
                OPDSFeed.root(
                    title: displayName,
                    baseURL: "http://\(request.head.authority ?? "localhost")"
                ),
                contentType: OPDSFeed.navigationContentType
            )
        }

        // The OpenSearch Description Document the root feed's `rel="search"`
        // points at.
        router.get("opds/search.xml") { request, _ -> Response in
            Self.opdsResponse(
                OPDSFeed.openSearchDescription(baseURL: "http://\(request.head.authority ?? "localhost")"),
                contentType: OPDSFeed.openSearchContentType
            )
        }

        router.get("opds/books") { request, _ -> Response in
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.books()
            return Self.opdsResponse(
                OPDSFeed.booksFeed(
                    title: "All Books", books: books,
                    baseURL: "http://\(request.head.authority ?? "localhost")",
                    page: page, pageHref: "/opds/books"
                ),
                contentType: OPDSFeed.acquisitionContentType
            )
        }

        router.get("opds/newest") { request, _ -> Response in
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.books()
                .sorted { ($0.addedMilliseconds ?? 0) > ($1.addedMilliseconds ?? 0) }
            return Self.opdsResponse(
                OPDSFeed.booksFeed(
                    title: "Newest", books: books,
                    baseURL: "http://\(request.head.authority ?? "localhost")",
                    page: page, pageHref: "/opds/newest"
                ),
                contentType: OPDSFeed.acquisitionContentType
            )
        }

        router.get("opds/search") { request, _ -> Response in
            guard let query = request.uri.queryParameters.get("q"), !query.isEmpty else {
                throw HTTPError(.badRequest)
            }
            let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
            let books = try await repository.search(query)
            return Self.opdsResponse(
                OPDSFeed.booksFeed(
                    title: "Search: \(query)", books: books,
                    baseURL: "http://\(request.head.authority ?? "localhost")",
                    page: page, pageHref: "/opds/search"
                ),
                contentType: OPDSFeed.acquisitionContentType
            )
        }

        for (path, facetType, title) in [
            ("opds/authors", FacetType.author, "Authors"),
            ("opds/series", FacetType.series, "Series"),
            ("opds/tags", FacetType.tag, "Tags"),
            ("opds/formats", FacetType.format, "Formats"),
        ] {
            // The navigation feed listing every value of the facet — the
            // root feed links here, so a missing route 404s in readers.
            router.get(RouterPath(path)) { request, _ -> Response in
                let values = try await repository.facetCounts(facetType)
                return Self.opdsResponse(
                    OPDSFeed.facetFeed(
                        title: title, values: values,
                        baseURL: "http://\(request.head.authority ?? "localhost")",
                        href: "/\(path)"
                    ),
                    contentType: OPDSFeed.navigationContentType
                )
            }
            router.get(RouterPath("\(path)/:value")) { request, context -> Response in
                guard let raw = context.parameters.get("value"),
                      let value = raw.removingPercentEncoding else {
                    throw HTTPError(.badRequest)
                }
                let page = max(1, request.uri.queryParameters.get("page").flatMap(Int.init) ?? 1)
                let books = try await repository.books(facetType: facetType, value: value)
                return Self.opdsResponse(
                    OPDSFeed.booksFeed(
                        title: "\(title): \(value)", books: books,
                        baseURL: "http://\(request.head.authority ?? "localhost")",
                        page: page, pageHref: "/\(path)/\(OPDSFeed.percentEncode(value))"
                    ),
                    contentType: OPDSFeed.acquisitionContentType
                )
            }
        }

        router.get("opds/books/:id") { request, context -> Response in
            guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)),
                  let book = try await repository.book(id: id) else {
                throw HTTPError(.notFound)
            }
            return Self.opdsResponse(
                OPDSFeed.booksFeed(
                    title: book.title, books: [book],
                    baseURL: "http://\(request.head.authority ?? "localhost")",
                    pageHref: "/opds/books/\(book.id.uuidString)"
                ),
                contentType: OPDSFeed.acquisitionContentType
            )
        }
        }

        return Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)))
    }

    private var advertiser: (any LibraryAdvertiser)?
    private var serviceGroup: ServiceGroup?
    private var runTask: Task<Void, Never>?

    /// Runs the server until shutdown — the CLI's `serve` path. Advertises
    /// the library first when configured (Network.framework on macOS, Avahi
    /// on Linux).
    public func run() async throws {
        if configuration.advertiseBonjour {
            startAdvertising()
        }
        let app = try makeApplication()
        try await app.runService()
        advertiser?.stop()
    }

    /// Non-blocking start for in-process embedding (the macOS app's Sharing
    /// pane). Owns the service group so `stop()` can trigger graceful
    /// shutdown; advertises the library when configured.
    public func start() async throws {
        let app = try makeApplication()
        if configuration.advertiseBonjour {
            startAdvertising()
        }
        let group = ServiceGroup(services: [app], logger: Logger(label: "Stacks.LibraryServer"))
        serviceGroup = group
        runTask = Task { try? await group.run() }
    }

    /// Gracefully shuts the embedded server down.
    public func stop() async {
        await serviceGroup?.triggerGracefulShutdown()
        runTask?.cancel()
        advertiser?.stop()
        advertiser = nil
        serviceGroup = nil
        runTask = nil
    }

    /// Publishes the `_stacks._tcp` service with the platform's
    /// advertising backend.
    private func startAdvertising() {
        #if canImport(Network)
        let advertiser = BonjourAdvertiser(
            displayName: displayName, libraryID: libraryID, port: configuration.port,
            serveSync: configuration.serveSync, serveOPDS: configuration.serveOPDS
        )
        #else
        let advertiser = AvahiAdvertiser(
            displayName: displayName, libraryID: libraryID, port: configuration.port,
            serveSync: configuration.serveSync, serveOPDS: configuration.serveOPDS
        )
        #endif
        advertiser.start()
        self.advertiser = advertiser
    }

    /// Serves a book's stored format file. `format` is matched against the
    /// format kind case-insensitively — a file extension works because kinds
    /// are uppercased extensions; nil (or no match) falls back to the first
    /// stored format, matching the long-standing `?format=` behaviour.
    private static func bookFileResponse(
        repository: LibraryRepository,
        bookID: UUID,
        format: String?
    ) async throws -> Response {
        guard let book = try await repository.book(id: bookID) else {
            throw HTTPError(.notFound)
        }
        guard let match = book.formats.first(where: {
            $0.kind.lowercased() == format?.lowercased()
        }) ?? book.formats.first else {
            throw HTTPError(.notFound)
        }
        let root = LibraryLayout(root: repository.root).root
        let url = root
            .appending(path: book.relativePath, directoryHint: .isDirectory)
            .appending(path: match.filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            throw HTTPError(.notFound)
        }
        var response = Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
        response.headers[.contentType] = BookMediaType.mimeType(forKind: match.kind)
        response.headers[.contentDisposition] = "attachment; filename=\"\(headerSafe(match.filename))\""
        return response
    }

    /// Wraps a feed body with its OPDS/OpenSearch `Content-Type` (UTF-8).
    private static func opdsResponse(_ xml: String, contentType: String) -> Response {
        var response = Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(string: xml)))
        response.headers[.contentType] = "\(contentType);charset=utf-8"
        return response
    }

    /// Removes characters that would break a quoted `Content-Disposition`
    /// filename parameter (quotes, backslashes, line breaks).
    private static func headerSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// The opened library's manifest id (Bonjour TXT, diagnostics).
    public var libraryID: UUID { repository.manifest.id }
    /// The library's display name (folder name unless configured otherwise).
    public var displayName: String {
        configuration.displayName
            ?? URL(fileURLWithPath: configuration.libraryPath).lastPathComponent
    }
}
