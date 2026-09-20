import Foundation
import Testing
@testable import StacksKit
@testable import StacksSync
@testable import StacksServerKit

@Suite
struct OPDSFeedTests {
    private func book(id: UUID = UUID(), title: String, authors: [String] = ["Alice"], tags: [String] = [], added: Int64 = 1) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors, tags: tags,
            addedMilliseconds: added, modifiedMilliseconds: 1, isDeleted: false
        )
    }

    @Test
    func rootContainsNavigationEntriesAndSearchLink() {
        let feed = OPDSFeed.root(title: "Matt's Library", baseURL: "http://example.com")
        #expect(feed.contains("<title>Matt&apos;s Library</title>"))
        #expect(feed.contains("<title>All Books</title>"))
        #expect(feed.contains("<title>Authors</title>"))
        #expect(feed.contains("<title>Series</title>"))
        #expect(feed.contains("<title>Tags</title>"))
        #expect(feed.contains("<title>Formats</title>"))
        #expect(feed.contains("<title>Newest</title>"))
        // OPDS 1.2: rel="search" points at an OpenSearch description, not the
        // search URL itself.
        #expect(feed.contains("rel=\"search\" href=\"http://example.com/opds/search.xml\" type=\"application/opensearchdescription+xml\""))
        // Feed and navigation ids are valid, self-contained IRIs.
        #expect(feed.contains("<id>http://example.com/opds</id>"))
        #expect(feed.contains("<id>http://example.com/opds/books</id>"))
    }

    @Test
    func openSearchDescriptionDescribesTheSearchTemplate() {
        let osd = OPDSFeed.openSearchDescription(baseURL: "http://example.com")
        #expect(osd.contains("<OpenSearchDescription xmlns=\"http://a9.com/-/spec/opensearch/1.1/\">"))
        #expect(osd.contains("template=\"http://example.com/opds/search?q={searchTerms}\""))
        #expect(osd.contains("type=\"application/atom+xml;profile=opds-catalog;kind=acquisition\""))
    }

    @Test
    func bookEntryHasCoverAndAcquisitionLinks() {
        let id = UUID()
        let book = IndexedBook(
            id: id, title: "Range", authors: ["David Epstein"],
            identifiers: ["isbn": "978-0-7352-2129-1"],
            formats: [.init(kind: "EPUB", filename: "a.epub", contentHash: "h", size: 1)],
            coverHash: "cover-hash", modifiedMilliseconds: 1, isDeleted: false
        )
        let feed = OPDSFeed.booksFeed(title: "X", books: [book], baseURL: "http://example.com", pageHref: "/opds/books")
        #expect(feed.contains("rel=\"http://opds-spec.org/cover\" href=\"http://example.com/api/books/\(id.uuidString)/cover\""))
        #expect(feed.contains("rel=\"http://opds-spec.org/acquisition/open-access\" href=\"http://example.com/api/books/\(id.uuidString)/download/a.epub\" type=\"application/epub+zip\""))
        #expect(feed.contains("<dc:identifier>isbn:978-0-7352-2129-1</dc:identifier>"))
        #expect(feed.contains("<author><name>David Epstein</name></author>"))
    }

    @Test
    func acquisitionLinksCarryRealMimeTypesAndExtensions() {
        // KOReader derives the file type from the URL's last path extension and
        // falls back to the link type; either must be real, or the book shows
        // no download button.
        let book = IndexedBook(
            id: UUID(), title: "Range", authors: ["David Epstein"],
            formats: [
                .init(kind: "EPUB", filename: "Range - David Epstein.epub", contentHash: "h", size: 1),
                .init(kind: "PDF", filename: "Range - David Epstein.pdf", contentHash: "h", size: 1),
            ],
            modifiedMilliseconds: 1, isDeleted: false
        )
        let feed = OPDSFeed.entry(book: book, baseURL: "http://example.com")
        #expect(feed.contains("download/Range%20-%20David%20Epstein.epub\" type=\"application/epub+zip\""))
        #expect(feed.contains("download/Range%20-%20David%20Epstein.pdf\" type=\"application/pdf\""))
    }

    @Test
    func mediaTypeMapsKnownKindsAndFallsBack() {
        #expect(BookMediaType.mimeType(forKind: "epub") == "application/epub+zip")
        #expect(BookMediaType.mimeType(forKind: "AZW3") == "application/vnd.amazon.ebook")
        #expect(BookMediaType.mimeType(forKind: "flac") == "application/octet-stream")
    }

    @Test
    func specialCharactersAreEscaped() {
        let book = book(title: "Don't & <Panic> \"Now\"")
        let feed = OPDSFeed.entry(book: book, baseURL: "http://example.com")
        #expect(!feed.contains("&<Panic>"))
        #expect(feed.contains("&amp; &lt;Panic&gt;"))
        #expect(feed.contains("&quot;Now&quot;"))
    }

    @Test
    func paginationAddsNextAndPreviousLinks() {
        let books = (0..<30).map { book(title: "Book \($0)") }
        let page1 = OPDSFeed.booksFeed(title: "X", books: books, baseURL: "http://example.com", page: 1, pageHref: "/opds/books")
        #expect(page1.contains("rel=\"next\" href=\"http://example.com/opds/books?page=2\""))
        #expect(!page1.contains("rel=\"previous\""))

        let page2 = OPDSFeed.booksFeed(title: "X", books: books, baseURL: "http://example.com", page: 2, pageHref: "/opds/books")
        #expect(page2.contains("rel=\"previous\" href=\"http://example.com/opds/books?page=1\""))
        // Page 2 has the remaining 5 books, no next.
        #expect(!page2.contains("rel=\"next\""))
        // Only 25 entries per page.
        #expect(page1.components(separatedBy: "<entry>").count == 26)
    }

    @Test
    func facetFeedListsValuesLinkingToTheirBookFeeds() {
        let feed = OPDSFeed.facetFeed(
            title: "Authors",
            values: [("Alice", 2), ("Bob", 1)],
            baseURL: "http://example.com",
            href: "/opds/authors"
        )
        #expect(feed.contains("<title>Alice</title>"))
        #expect(feed.contains("<title>Bob</title>"))
        #expect(feed.contains("<content type=\"text\">2 books</content>"))
        #expect(feed.contains("href=\"http://example.com/opds/authors/Alice\""))
        #expect(feed.contains("href=\"http://example.com/opds/authors/Bob\""))
    }

    @Test
    func facetFeedPercentEncodesValuesForPathSegments() {
        // A value containing "/" must not break the route — the segment is
        // percent-encoded (the :value handler decodes it back).
        let feed = OPDSFeed.facetFeed(
            title: "Series",
            values: [("Sci-Fi/Adventure", 1)],
            baseURL: "http://example.com",
            href: "/opds/series"
        )
        #expect(feed.contains("href=\"http://example.com/opds/series/Sci-Fi%2FAdventure\""))
    }

    @Test
    func paginationLinksUseTheFeedsOwnHref() {
        let books = (0..<30).map { book(title: "Book \($0)") }
        let page1 = OPDSFeed.booksFeed(title: "Newest", books: books, baseURL: "http://example.com", pageHref: "/opds/newest")
        #expect(page1.contains("rel=\"next\" href=\"http://example.com/opds/newest?page=2\""))
        #expect(!page1.contains("/opds/books?page="))

        let page2 = OPDSFeed.booksFeed(title: "Newest", books: books, baseURL: "http://example.com", page: 2, pageHref: "/opds/newest")
        #expect(page2.contains("rel=\"previous\" href=\"http://example.com/opds/newest?page=1\""))
    }
}
