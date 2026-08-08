import ArgumentParser
import Foundation
import StacksCore

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
