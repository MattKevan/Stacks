import Foundation
import Testing
@testable import StacksCore

@Suite
struct BookBrowserModelTests {
    // MARK: - Fixtures

    /// Deterministic book fixture mirroring the fields the browser model
    /// filters and sorts on.
    private func makeBook(
        id: UUID = UUID(),
        title: String,
        authors: [String] = [],
        tags: [String] = [],
        series: String? = nil,
        formats: [BookFormatRecord] = [],
        addedMilliseconds: Int64? = nil
    ) -> IndexedBook {
        IndexedBook(
            id: id,
            title: title,
            authors: authors,
            series: series,
            tags: tags,
            addedMilliseconds: addedMilliseconds,
            formats: formats,
            modifiedMilliseconds: 1,
            isDeleted: false
        )
    }

    private func format(_ kind: String) -> BookFormatRecord {
        BookFormatRecord(kind: kind, filename: "\(kind).epub", contentHash: "h", size: 1)
    }

    // MARK: - Search

    @Test
    func searchMatchesTitleSubstring() {
        var model = BookBrowserModel()
        let books = [
            makeBook(title: "Range: Why Generalists Triumph"),
            makeBook(title: "Deep Work"),
            makeBook(title: "The Range Rover Story"),
        ]
        model.searchText = "range"

        let result = model.books(from: books)
        #expect(result.map(\.title) == [
            "Range: Why Generalists Triumph",
            "The Range Rover Story",
        ])
    }

    @Test
    func searchMatchesAuthor() {
        var model = BookBrowserModel()
        let books = [
            makeBook(title: "Range", authors: ["David Epstein"]),
            makeBook(title: "Deep Work", authors: ["Cal Newport"]),
        ]
        model.searchText = "newport"

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Deep Work"])
    }

    @Test
    func searchMatchesTag() {
        var model = BookBrowserModel()
        let books = [
            makeBook(title: "Range", tags: ["nonfiction", "science"]),
            makeBook(title: "Deep Work", tags: ["productivity"]),
        ]
        model.searchText = "SCIENCE"

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Range"])
    }

    @Test
    func emptyQueryReturnsAllBooks() {
        var model = BookBrowserModel()
        let books = [
            makeBook(title: "Range"),
            makeBook(title: "Deep Work"),
        ]
        model.searchText = "   "

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Deep Work", "Range"])
    }

    // MARK: - Facet filtering

    @Test
    func facetFiltersByAuthor() {
        var model = BookBrowserModel()
        model.facetNavigation.selectCategory(.author)
        model.facetNavigation.selectValue("David Epstein")
        let books = [
            makeBook(title: "Range", authors: ["David Epstein"]),
            makeBook(title: "Talent", authors: ["Geoff Colvin"]),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Range"])
    }

    @Test
    func facetFiltersBySeries() {
        var model = BookBrowserModel()
        model.facetNavigation.selectCategory(.series)
        model.facetNavigation.selectValue("Expanse")
        let books = [
            makeBook(title: "Leviathan Wakes", series: "Expanse"),
            makeBook(title: "Dune", series: "Dune"),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Leviathan Wakes"])
    }

    @Test
    func facetFiltersByTag() {
        var model = BookBrowserModel()
        model.facetNavigation.selectCategory(.tag)
        model.facetNavigation.selectValue("sci-fi")
        let books = [
            makeBook(title: "Leviathan Wakes", tags: ["sci-fi"]),
            makeBook(title: "Range", tags: ["nonfiction"]),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Leviathan Wakes"])
    }

    @Test
    func facetFiltersByFormatCaseInsensitive() {
        var model = BookBrowserModel()
        model.facetNavigation.selectCategory(.format)
        model.facetNavigation.selectValue("epub")
        let books = [
            makeBook(title: "Range", formats: [format("EPUB")]),
            makeBook(title: "Deep Work", formats: [format("PDF")]),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Range"])
    }

    // MARK: - Sorting

    @Test
    func nameSortIsCaseInsensitiveAscending() {
        var model = BookBrowserModel()
        model.sortOrder = .name
        let books = [
            makeBook(title: "zebra"),
            makeBook(title: "Alpha"),
            makeBook(title: "bravo"),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Alpha", "bravo", "zebra"])
    }

    @Test
    func dateAddedSortIsNewestFirst() {
        var model = BookBrowserModel()
        model.sortOrder = .dateAdded
        let books = [
            makeBook(title: "Oldest", addedMilliseconds: 1_000),
            makeBook(title: "Newest", addedMilliseconds: 3_000),
            makeBook(title: "Middle", addedMilliseconds: 2_000),
        ]

        let result = model.books(from: books)
        #expect(result.map(\.title) == ["Newest", "Middle", "Oldest"])
    }
}
