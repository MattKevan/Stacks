import ArgumentParser
import Foundation
import StacksCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The headless library server CLI — `stacks create|enrich|import-calibre|import|serve|status|browse`.
@main
struct StacksCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stacks",
        abstract: "Create, serve, browse, and inspect Stacks libraries.",
        subcommands: [Create.self, Enrich.self, ImportCalibre.self, Import.self, Serve.self, Status.self, Browse.self]
    )
}

/// The server's disposable index directory. macOS: Application Support.
/// Linux (Plan 3): a sibling `.stacks-server-indexes` directory next to the
/// library (Application Support may be unavailable or unwritable).
func serverIndexesDirectory(libraryPath: String? = nil) throws -> URL {
    if let support = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ) {
        return support.appending(path: "StacksServer", directoryHint: .isDirectory)
    }
    if let libraryPath {
        return URL(fileURLWithPath: libraryPath)
            .deletingLastPathComponent()
            .appending(path: ".stacks-server-indexes", directoryHint: .isDirectory)
    }
    return URL(fileURLWithPath: ".stacks-server-indexes")
}

/// Resolves a library target into an open repository, creating the library
/// when the path is absent or an empty folder was pre-made (`mkdir` then
/// import is a natural workflow). A non-empty folder that is not already a
/// Stacks library is refused — never write a skeleton into user files.
private func openOrCreateLibrary(
    at root: URL,
    indexesDirectory: URL
) async throws -> LibraryRepository {
    let layout = LibraryLayout(root: root)
    let manifestExists = FileManager.default.fileExists(atPath: layout.manifestURL.path)
    if !manifestExists {
        let exists = FileManager.default.fileExists(atPath: root.path)
        if exists {
            // A regular file at the target is refused like a non-empty
            // folder: `create` would otherwise surface a raw Cocoa error
            // instead of a clear validation message.
            let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            guard isDirectory && contents.isEmpty else {
                throw ValidationError(
                    "\(root.path) is not an empty folder or a Stacks library."
                )
            }
        }
        _ = try await LibraryRepository.create(
            at: root, indexesDirectory: indexesDirectory, deviceID: UUID()
        )
    }
    return try await LibraryRepository.open(
        at: root, indexesDirectory: indexesDirectory, deviceID: UUID()
    )
}

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new library at the given path."
    )

    @Argument(help: "Directory for the new library")
    var path: String

    func run() async throws {
        let root = URL(fileURLWithPath: path)
        let indexes = try serverIndexesDirectory()
        let repository = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        print("Created library at \(root.path)")
        print("Library ID: \(repository.manifest.id)")
        print("Format version: \(repository.manifest.formatVersion)")
    }
}

struct Enrich: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch metadata for books missing authors or tags."
    )

    @Argument(help: "Path to the library directory")
    var libraryPath: String

    func run() async throws {
        let root = URL(fileURLWithPath: libraryPath)
        let indexes = try serverIndexesDirectory(libraryPath: libraryPath)
        let repository = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )

        // The same sweep the app runs (Library ▸ Fetch Missing Metadata):
        // missing authors or tags, with all-"Unknown" placeholder authors
        // counted as missing too.
        let books = try await repository.books()
            .filter { EnrichmentPolicy.needsEnrichment($0) }
        print("Enriching \(books.count) books missing authors/tags")

        // Mirror the app's lookup service construction (OpenLibrary, then
        // Google Books) so the headless path behaves like the app.
        let client = URLSessionMetadataHTTPClient()
        let registry = MetadataRegistry(sources: [
            OpenLibrarySource(client: client, userAgent: "Stacks/1.0"),
            GoogleBooksSource(client: client, userAgent: "Stacks/1.0"),
        ])
        let service = MetadataLookupService(registry: registry)

        var applied = 0
        var failed = 0
        for book in books {
            let query = MetadataLookupQuery(
                isbn: book.identifiers["isbn"], title: book.title, authors: book.authors
            )
            let result: MetadataLookupResult
            do {
                result = try await service.lookup(query)
            } catch {
                FileHandle.standardError.write(Data(
                    "  lookup failed: \(book.title) — \(error.localizedDescription)\n".utf8
                ))
                failed += 1
                continue
            }
            guard let candidate = MetadataScoring.autoApply(
                from: MetadataScoring.ranked(result.candidates, for: query),
                for: query
            ) else {
                // Nothing found, or the top result isn't confident enough for
                // auto-apply (see MetadataScoring.autoApply) — leave the book
                // untouched.
                continue
            }

            // Fill only the fields the book is missing — existing values are
            // never clobbered (same semantics as the app's apply path). The
            // metadata sources don't supply tags, so authors and the other
            // empty fields are what a candidate can fill.
            var edit = BookEdit()
            var fillsSomething = false
            if book.title.isEmpty, !candidate.title.isEmpty {
                edit.title = candidate.title
                fillsSomething = true
            }
            if book.authors.isEmpty, !candidate.authors.isEmpty {
                edit.authors = candidate.authors
                fillsSomething = true
            }
            if book.publisher == nil, let publisher = candidate.publisher, !publisher.isEmpty {
                edit.publisher = .set(publisher)
                fillsSomething = true
            }
            if book.publicationDate == nil, let date = candidate.publicationDate {
                edit.publicationDate = .set(date)
                fillsSomething = true
            }
            if book.identifiers["isbn"] == nil, let isbn = candidate.isbn {
                edit.identifiers = book.identifiers.merging(["isbn": isbn]) { _, new in new }
                fillsSomething = true
            }
            guard fillsSomething else { continue }

            do {
                _ = try await repository.updateBook(id: book.id, edit: edit)
                applied += 1
                print("  ✓ \(book.title)")
            } catch {
                FileHandle.standardError.write(Data(
                    "  update failed: \(book.title) — \(error.localizedDescription)\n".utf8
                ))
                failed += 1
            }
        }
        print("Applied: \(applied) of \(books.count)")
        // Matches Import/ImportCalibre: any failed book is a non-zero exit.
        // A lookup that simply finds nothing is not a failure.
        if failed > 0 {
            Foundation.exit(1)
        }
    }
}

struct ImportCalibre: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-calibre",
        abstract: "Create a Stacks library from an existing Calibre library."
    )

    @Argument(help: "Path to the Calibre library (folder containing metadata.db)")
    var calibrePath: String

    @Argument(help: "Path for the new Stacks library")
    var targetPath: String

    @Option(name: .long, help: "Indexes directory (default: next to the target)")
    var indexes: String?

    @Option(name: .long, help: "Import only these Calibre book ids (repeatable)")
    var only: [Int] = []

    func run() async throws {
        // The source is read-only: the reader snapshots metadata.db into a
        // disposable temp copy and never opens the original.
        let reader = try CalibreReader.open(libraryURL: URL(fileURLWithPath: calibrePath))
        defer { try? reader.close() }
        let books = try reader.books(includeBlobCovers: false)

        let indexesDirectory: URL
        if let indexes {
            indexesDirectory = URL(fileURLWithPath: indexes)
        } else {
            indexesDirectory = try serverIndexesDirectory(libraryPath: targetPath)
        }
        let root = URL(fileURLWithPath: targetPath)
        let repository = try await openOrCreateLibrary(
            at: root, indexesDirectory: indexesDirectory
        )

        let sourceName = URL(fileURLWithPath: calibrePath)
            .deletingPathExtension().lastPathComponent
        print("Importing \(books.count) books from Calibre library '\(sourceName)'")
        print("Target: \(root.path) (library \(repository.manifest.id))")

        let service = CalibreImportService(layout: LibraryLayout(root: root))
        // The @Sendable progress closure needs mutable state outside the
        // captured vars — a boxed counter.
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        var failedTitles: [String] = []
        let report = try await service.importBooks(
            books,
            from: calibrePath,
            libraryID: repository.manifest.id.uuidString,
            selection: only.isEmpty ? nil : only,
            into: repository,
            progress: { update in
                // One progress line every 25 books; failures are collected
                // for the final summary.
                if update.completed - counter.value >= 25 {
                    counter.value = update.completed
                    FileHandle.standardError.write(Data(
                        "  [\(update.completed)/\(update.total)] \(update.currentTitle ?? "")\n".utf8
                    ))
                }
            },
            coverProvider: { calibreID in
                try reader.coverData(for: calibreID)
            }
        )

        for item in report.items {
            if case .failed(let message) = item.status {
                failedTitles.append("\(item.title) — \(message)")
            }
        }
        print("Imported: \(report.imported.count)  Duplicates: \(report.duplicates.count)  "
            + "Failed: \(report.failed.count)  Skipped: \(report.skipped.count)")
        for title in failedTitles {
            FileHandle.standardError.write(Data("  failed: \(title)\n".utf8))
        }
        if !report.failed.isEmpty {
            Foundation.exit(1)
        }
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import book files (EPUB/PDF/DJVU/MOBI) into a library."
    )

    @Argument(help: "Path to the library (created if missing)")
    var libraryPath: String

    @Argument(
        parsing: .remaining,
        help: "Book files to import (everything after the library path is treated as a file, even tokens that look like options)"
    )
    var files: [String]

    func run() async throws {
        let root = URL(fileURLWithPath: libraryPath)
        let indexesDirectory = try serverIndexesDirectory(libraryPath: libraryPath)
        let repository = try await openOrCreateLibrary(
            at: root, indexesDirectory: indexesDirectory
        )

        let service = ImportService(layout: LibraryLayout(root: root))
        let report = try await service.importFiles(
            files.map { URL(fileURLWithPath: $0) },
            into: repository
        )

        print("Imported: \(report.imported.count)  Duplicates: \(report.duplicates.count)  "
            + "Failed: \(report.failed.count)")
        for item in report.failed {
            guard case .failed(let message) = item.status else { continue }
            FileHandle.standardError.write(Data(
                "  failed: \(item.sourceURL.path) — \(message)\n".utf8
            ))
        }
        if !report.failed.isEmpty {
            Foundation.exit(1)
        }
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve a library over HTTP (sync protocol + OPDS) with Bonjour advertisement."
    )

    @Argument(help: "Path to the library directory")
    var path: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8080

    @Option(name: .long, help: "Require this username (with --password)")
    var user: String?

    @Option(name: .long, help: "Password for --user")
    var password: String?

    @Option(name: .long, help: "Indexes directory (default: Application Support/StacksServer)")
    var indexes: String?

    @Flag(name: .customLong("no-bonjour"), help: "Do not advertise over Bonjour")
    var noBonjour = false

    @Option(name: .shortAndLong, help: "Display name for Bonjour")
    var name: String?

    func run() async throws {
        let indexesDirectory: URL
        if let indexes {
            indexesDirectory = URL(fileURLWithPath: indexes)
        } else {
            indexesDirectory = try serverIndexesDirectory(libraryPath: path)
        }
        let configuration = ServerConfiguration(
            port: port,
            libraryPath: path,
            indexesDirectory: indexesDirectory,
            username: user,
            password: password,
            advertiseBonjour: !noBonjour,
            displayName: name
        )
        let server = try await LibraryServer(configuration: configuration)
        let displayName = await server.displayName
        print("Serving '\(displayName)' on port \(port)"
            + (user != nil ? " (auth required)" : " (anonymous)"))
        try await server.run()
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a library's identity and journal state."
    )

    @Argument(help: "Path to the library directory")
    var path: String

    func run() async throws {
        let root = URL(fileURLWithPath: path)
        let indexes = try serverIndexesDirectory()
        let repository = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        print("Library: \(root.path)")
        print("ID: \(repository.manifest.id)")
        print("Format version: \(repository.manifest.formatVersion)")
        print("Journal seq: \(await repository.journalSeq())")
        let books = try await repository.books()
        let deleted = try await repository.deletedBooks()
        print("Books: \(books.count) (+ \(deleted.count) deleted)")
    }
}

/// Interactive terminal client for a remote Stacks server. Connects a
/// `RemoteLibrary` over the sync protocol, pulls the book snapshot once, then
/// runs a prompt loop on stdin: `list` (search/facet/sort), `show`, `open`,
/// `download`, `upload`, `refresh`, `quit`. Errors go to stderr and the loop
/// keeps running — only `quit` or EOF exits.
struct Browse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Browse a remote Stacks server interactively."
    )

    @Argument(help: "Server URL (e.g. http://host:port)")
    var serverURL: String

    @Option(name: .long, help: "Username for basic auth")
    var user: String?

    @Option(name: .long, help: "Password for --user")
    var password: String?

    func run() async throws {
        guard let baseURL = URL(string: serverURL) else {
            throw ValidationError("Invalid server URL: \(serverURL)")
        }
        let credential = user.map {
            RemoteLibrary.Credential(username: $0, password: password ?? "")
        }
        let remote = try RemoteLibrary(configuration: .init(
            baseURL: baseURL,
            credential: credential,
            queueDirectory: Self.queueDirectory(for: baseURL)
        ))
        // Session browse state: the sort order chosen with `sort` persists
        // across `list` invocations.
        var model = BookBrowserModel()

        do {
            try await remote.pull()
        } catch {
            // Unreachable / auth failures are not fatal — the REPL stays open
            // so `refresh` (or `quit`) still work.
            Self.stderr("Could not reach \(serverURL): \(Self.describe(error))")
        }
        let count = await remote.books().count
        print("Connected to \(serverURL) — \(count) book\(count == 1 ? "" : "s")")
        fflush(stdout)

        while true {
            print("> ", terminator: "")
            fflush(stdout)
            guard let raw = readLine(strippingNewline: true) else { break }  // EOF → exit 0
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let tokens = Self.tokenize(line)
            let args = Array(tokens.dropFirst())
            switch tokens[0].lowercased() {
            case "list":
                await list(args, remote: remote, model: &model)
            case "sort":
                sort(args, model: &model)
            case "show":
                await show(args, remote: remote)
            case "open":
                await open(args, remote: remote)
            case "download":
                await download(args, remote: remote)
            case "upload":
                await upload(args, remote: remote)
            case "refresh":
                await refresh(remote: remote)
            case "quit":
                return
            default:
                Self.stderr("Unknown command '\(tokens[0])' — try list, sort, show, open, download, upload, refresh, or quit")
            }
            // Flush so a piped stdout shows this command's output before the
            // next prompt (on a TTY stdout is already line-buffered).
            fflush(stdout)
        }
    }

    // MARK: - Commands

    /// `list [--search TEXT] [--author NAME] [--series NAME] [--tag NAME] [--format KIND]`
    private func list(
        _ args: [String],
        remote: RemoteLibrary,
        model: inout BookBrowserModel
    ) async {
        // Every option takes exactly one value; the flags are hand-rolled
        // pairs so values survive tokenization (e.g. `--tag "Science Fiction"`).
        var search: String?
        var facet: (type: FacetType, value: String)?
        var index = 0
        while index < args.count {
            let flag = args[index]
            guard index + 1 < args.count else {
                Self.stderr("Missing value for \(flag)")
                return
            }
            let value = args[index + 1]
            index += 2
            switch flag {
            case "--search":
                search = value
            case "--author":
                facet = (.author, value)
            case "--series":
                facet = (.series, value)
            case "--tag":
                facet = (.tag, value)
            case "--format":
                facet = (.format, value)
            default:
                Self.stderr("Unknown option '\(flag)' for list")
                return
            }
        }
        model.searchText = search ?? ""
        model.facetNavigation.clear()
        if let facet {
            model.facetNavigation.selectCategory(facet.type)
            model.facetNavigation.selectValue(facet.value)
        }
        let books = model.books(from: await remote.books())
        for book in books {
            let author = book.authors.first ?? "Unknown"
            let formats = book.formats.map(\.kind).joined(separator: ",")
            print("\(book.id.uuidString.prefix(8))  \(book.title)  (\(author))  [\(formats)]")
        }
        print("\(books.count) book\(books.count == 1 ? "" : "s")")
    }

    /// `sort name|date` — switches the session sort order.
    private func sort(_ args: [String], model: inout BookBrowserModel) {
        guard let raw = args.first else {
            Self.stderr("Usage: sort name|date")
            return
        }
        let order: BookSortOrder
        switch raw.lowercased() {
        case "name": order = .name
        case "date", "dateadded": order = .dateAdded
        default:
            Self.stderr("Unknown sort '\(raw)' — use name or date")
            return
        }
        model.sortOrder = order
        print("Sorting by \(order == .name ? "name" : "date added")")
    }

    /// `show <id>` — prints a book's full metadata.
    private func show(_ args: [String], remote: RemoteLibrary) async {
        guard let input = args.first else {
            Self.stderr("Usage: show <id>")
            return
        }
        guard let book = await resolveBookID(input, remote: remote) else {
            Self.stderr("No book with id \(input)")
            return
        }
        print("ID: \(book.id.uuidString)")
        print("Title: \(book.title)")
        print("Authors: \(book.authors.isEmpty ? "Unknown" : book.authors.joined(separator: ", "))")
        if let series = book.series, !series.isEmpty {
            let position = book.seriesIndex.map { " (book \(Self.formatNumber($0)))" } ?? ""
            print("Series: \(series)\(position)")
        }
        print("Tags: \(book.tags.isEmpty ? "—" : book.tags.joined(separator: ", "))")
        print("Formats: \(book.formats.isEmpty ? "—" : book.formats.map(\.kind).joined(separator: ", "))")
        if let publisher = book.publisher, !publisher.isEmpty {
            print("Publisher: \(publisher)")
        }
        if let date = book.publicationDate {
            print("Published: \(Self.formatDate(date))")
        }
        if let date = book.addedDate {
            print("Added: \(Self.formatDate(date))")
        }
        if let rating = book.rating {
            print("Rating: \(rating)/5")
        }
        if !book.languages.isEmpty {
            print("Languages: \(book.languages.joined(separator: ", "))")
        }
        if !book.identifiers.isEmpty {
            let identifiers = book.identifiers
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            print("Identifiers: \(identifiers)")
        }
        if let comments = book.comments, !comments.isEmpty {
            print("Comments: \(comments)")
        }
    }

    /// `open <id>` — downloads the first format and opens it with the system
    /// opener (`open` on macOS, `xdg-open` on Linux).
    private func open(_ args: [String], remote: RemoteLibrary) async {
        guard let input = args.first else {
            Self.stderr("Usage: open <id>")
            return
        }
        guard let book = await resolveBookID(input, remote: remote) else {
            Self.stderr("No book with id \(input)")
            return
        }
        guard let format = book.formats.first else {
            Self.stderr("\(book.title) has no downloadable formats")
            return
        }
        do {
            let url = try await remote.downloadFormat(id: book.id, format: format.kind.lowercased())
            try Self.openFile(url)
            print("Opening \(book.title) (\(format.kind))")
        } catch {
            Self.stderr("open failed for \(book.title): \(Self.describe(error))")
        }
    }

    /// `download <id> [dir]` — downloads the first format into `dir`
    /// (default: the current directory), keeping the book's filename.
    private func download(_ args: [String], remote: RemoteLibrary) async {
        guard let input = args.first else {
            Self.stderr("Usage: download <id> [dir]")
            return
        }
        guard let book = await resolveBookID(input, remote: remote) else {
            Self.stderr("No book with id \(input)")
            return
        }
        guard let format = book.formats.first else {
            Self.stderr("\(book.title) has no downloadable formats")
            return
        }
        let directory: URL
        if let dirArg = args.dropFirst().first {
            directory = URL(fileURLWithPath: dirArg)
        } else {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = try await remote.downloadFormat(id: book.id, format: format.kind.lowercased())
            let destination = directory.appending(path: format.filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            // The temp download directory is now empty; drop it.
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            print("Saved \(destination.path)")
        } catch {
            Self.stderr("download failed for \(book.title): \(Self.describe(error))")
        }
    }

    /// `upload <file...>` — extracts metadata from each file and pushes an
    /// `addBook` (with the embedded cover, staged like the app's import path).
    private func upload(_ args: [String], remote: RemoteLibrary) async {
        guard !args.isEmpty else {
            Self.stderr("Usage: upload <file...>")
            return
        }
        for path in args {
            let url = URL(fileURLWithPath: path)
            guard let kind = MetadataExtractor.kind(for: url) else {
                Self.stderr("\(path): unsupported file type (EPUB/PDF/DJVU)")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                Self.stderr("\(path): cannot read file")
                continue
            }
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
            // The embedded cover rides along, staged like the format, so
            // uploaded books show a real cover (mirrors
            // RemoteLibraryBrowser.importFiles minus AppKit).
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
            do {
                switch try await remote.push(
                    ClientCommand(id: UUID(), op: .addBook(addBook)),
                    stagedFiles: stagedFiles
                ) {
                case .applied:
                    print("✓ \(title)")
                case .queued:
                    print("✓ \(title) (queued — will sync when the server is reachable)")
                }
            } catch {
                Self.stderr("\(title): upload failed — \(Self.describe(error))")
            }
        }
        // Reflect the new books in subsequent commands (mirrors the app's
        // refresh-after-import).
        try? await remote.pull()
    }

    /// `refresh` — pulls the journal again and reports the new count.
    private func refresh(remote: RemoteLibrary) async {
        do {
            try await remote.pull()
            let count = await remote.books().count
            print("Refreshed — \(count) book\(count == 1 ? "" : "s")")
        } catch {
            Self.stderr("refresh failed: \(Self.describe(error))")
        }
    }

    // MARK: - Helpers

    /// Resolves a full UUID or an unambiguous id prefix (as printed by
    /// `list`) to a book.
    private func resolveBookID(_ input: String, remote: RemoteLibrary) async -> IndexedBook? {
        if let uuid = UUID(uuidString: input) {
            return await remote.book(id: uuid)
        }
        let needle = input.lowercased()
        for book in await remote.books() where book.id.uuidString.lowercased().hasPrefix(needle) {
            return book
        }
        return nil
    }

    /// Splits a command line into tokens, honoring double-quoted segments so
    /// flag values like `--tag "Science Fiction"` survive.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            switch character {
            case "\"":
                inQuotes.toggle()
            case " " where !inQuotes, "\t" where !inQuotes:
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The durable offline-queue location for this server — a temp path keyed
    /// by host+port so different servers never share a queue. The queue
    /// persists there for the session.
    static func queueDirectory(for baseURL: URL) -> URL {
        let host = baseURL.host ?? "unknown"
        let port = baseURL.port.map(String.init) ?? (baseURL.scheme == "https" ? "443" : "80")
        return FileManager.default.temporaryDirectory
            .appending(path: "stacks-browse", directoryHint: .isDirectory)
            .appending(path: "\(host)-\(port)", directoryHint: .isDirectory)
    }

    /// Opens a file with the platform's system opener.
    static func openFile(_ url: URL) throws {
        #if os(Linux)
        let opener = "/usr/bin/xdg-open"
        #else
        let opener = "/usr/bin/open"
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url.path]
        try process.run()
    }

    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func describe(_ error: Error) -> String {
        if let remoteError = error as? RemoteLibrary.RemoteError {
            switch remoteError {
            case .unreachable: return "server unreachable"
            case .serverError(let code): return "server error (\(code))"
            }
        }
        return error.localizedDescription
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func formatNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
