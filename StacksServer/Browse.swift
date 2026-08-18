import ArgumentParser
import Foundation
import StacksCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

        var connected = false
        do {
            try await remote.pull()
            connected = true
        } catch {
            // Unreachable / auth failures are not fatal — the REPL stays open
            // so `refresh` (or `quit`) still work.
            Self.stderr("Could not reach \(serverURL): \(Self.describe(error))")
        }
        let count = await remote.books().count
        if connected {
            print("Connected to \(serverURL) — \(count) book\(count == 1 ? "" : "s")")
        } else {
            print("Cannot reach \(serverURL) — \(count) book\(count == 1 ? "" : "s") cached")
        }
        fflush(nil)

        while true {
            print("> ", terminator: "")
            fflush(nil)
            guard let raw = readLine(strippingNewline: true) else { break }  // EOF → exit 0
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let tokens = Self.tokenize(line)
            // A quote-only line (e.g. `""` or a lone `"`) tokenizes to
            // nothing — treat it like an empty line instead of indexing past
            // the end of the array.
            guard !tokens.isEmpty else { continue }
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
            fflush(nil)
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
        guard let book = await resolveBookID(input, remote: remote) else { return }
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
    /// opener (`open` on macOS, `xdg-open` on Linux). The temp download is
    /// left in place (like the app's `RemoteLibraryBrowser.open`): the opener
    /// returns before the viewer reads the file, so deleting it would race
    /// the open.
    private func open(_ args: [String], remote: RemoteLibrary) async {
        guard let input = args.first else {
            Self.stderr("Usage: open <id>")
            return
        }
        guard let book = await resolveBookID(input, remote: remote) else { return }
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
        guard let book = await resolveBookID(input, remote: remote) else { return }
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
        let destination = directory.appending(path: format.filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = try await remote.downloadFormat(id: book.id, format: format.kind.lowercased())
            // Move onto the destination volume first (a same-volume rename can
            // never EXDEV), then swap into place — a failed download never
            // destroys a previous copy of the file.
            let staged = directory.appending(
                path: ".\(format.filename).stacks-\(UUID().uuidString.prefix(8))"
            )
            do {
                try FileManager.default.moveItem(at: source, to: staged)
            } catch {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
                throw error
            }
            defer {
                // A final-rename failure leaves only the staged sibling behind;
                // the previous destination is untouched.
                try? FileManager.default.removeItem(at: staged)
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staged, to: destination)
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
                Self.stderr("\(path): unsupported file type (EPUB/PDF/DJVU/MP3/M4B/M4A/AAC)")
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

    /// Resolves a full UUID or an id prefix (as printed by `list`) to a book.
    /// Reports to stderr — and returns nil — when nothing matches or several
    /// books share the prefix (never silently act on the wrong book).
    private func resolveBookID(_ input: String, remote: RemoteLibrary) async -> IndexedBook? {
        if let uuid = UUID(uuidString: input) {
            guard let book = await remote.book(id: uuid) else {
                Self.stderr("No book with id \(input)")
                return nil
            }
            return book
        }
        let needle = input.lowercased()
        let matches = await remote.books()
            .filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            Self.stderr("No book with id \(input)")
            return nil
        default:
            Self.stderr(
                "Ambiguous id '\(input)' — \(matches.count) books match; use a longer prefix or the full id"
            )
            return nil
        }
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
