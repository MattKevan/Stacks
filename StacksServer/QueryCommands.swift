import ArgumentParser
import Foundation
import StacksCore

/// `stacks list` — a one-shot, read-only listing of a local library's books.
/// Sort and filter semantics come from `BookBrowserModel`, the same tested
/// code the macOS app and the browse REPL use.
struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List a library's books, one per line."
    )

    @Argument(help: "Path to the library directory")
    var libraryPath: String

    @Option(name: .long, help: "Sort order: name or date (default: name)")
    var sort: String = "name"

    func run() async throws {
        let root = URL(fileURLWithPath: libraryPath)
        let indexes = try serverIndexesDirectory(libraryPath: libraryPath)
        let repository = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        var model = BookBrowserModel()
        model.sortOrder = try Self.sortOrder(for: sort)
        for book in model.books(from: try await repository.books()) {
            print(QueryListing.line(for: book))
        }
    }

    /// Accepts the same values as the browse REPL's `sort` command.
    private static func sortOrder(for raw: String) throws -> BookSortOrder {
        switch raw.lowercased() {
        case "name": return .name
        case "date", "dateadded": return .dateAdded
        default:
            throw ValidationError("Unknown sort '\(raw)' — use name or date")
        }
    }
}

/// `stacks search` — the same one-line listing filtered by a query. Search is
/// a case-insensitive substring over title, authors, tags, and series,
/// matching the browser's search (via `BookBrowserModel`); sort defaults to
/// name. An empty result set is a success (exit 0, no output).
struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search a library's books, one per line."
    )

    @Argument(help: "Path to the library directory")
    var libraryPath: String

    @Argument(help: "Case-insensitive substring over title, authors, tags, or series")
    var query: String

    func run() async throws {
        let root = URL(fileURLWithPath: libraryPath)
        let indexes = try serverIndexesDirectory(libraryPath: libraryPath)
        let repository = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        var model = BookBrowserModel()
        model.searchText = query
        for book in model.books(from: try await repository.books()) {
            print(QueryListing.line(for: book))
        }
    }
}

/// The one-line-per-book format shared by `list` and `search`, matching the
/// browse REPL's `list` output:
/// `<id-prefix>  <title>  (<first author>)  [KIND,...]`.
enum QueryListing {
    static func line(for book: IndexedBook) -> String {
        let author = book.authors.first ?? "Unknown"
        let formats = book.formats.map(\.kind).joined(separator: ",")
        return "\(book.id.uuidString.prefix(8))  \(book.title)  (\(author))  [\(formats)]"
    }
}
