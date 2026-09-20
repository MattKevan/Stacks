import Foundation
import StacksKit

/// Maps a stored format kind (the uppercased file extension, e.g. `EPUB`) to
/// the MIME type OPDS readers expect. Readers that cannot infer a type from the
/// URL fall back to this — KOReader, for one, refuses to offer a download when
/// the acquisition link's type is `application/octet-stream` and the href has
/// no usable extension.
public enum BookMediaType {
    public static func mimeType(forKind kind: String) -> String {
        switch kind.lowercased() {
        case "epub": return "application/epub+zip"
        case "pdf": return "application/pdf"
        case "mobi": return "application/x-mobipocket-ebook"
        case "azw3": return "application/vnd.amazon.ebook"
        case "djvu": return "image/vnd.djvu"
        case "txt": return "text/plain"
        case "mp3": return "audio/mpeg"
        case "m4b", "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }
}

/// OPDS 1.2 feed generation for third-party readers (Thorium, KOReader,
/// Calibre). Feeds are built as escaped XML STRINGS — Foundation's
/// `XMLDocument` is not available on Linux (Plan 3), so string building with
/// strict escaping is the portable choice.
public enum OPDSFeed {
    public static let pageSize = 25

    /// The feed media types — also served as the routes' HTTP `Content-Type`
    /// (with a charset appended), so the body and the header always agree.
    public static let navigationContentType = "application/atom+xml;profile=opds-catalog;kind=navigation"
    public static let acquisitionContentType = "application/atom+xml;profile=opds-catalog;kind=acquisition"
    public static let openSearchContentType = "application/opensearchdescription+xml"

    // MARK: - Feeds

    /// The root navigation feed: All Books + Authors/Series/Tags/Formats +
    /// Newest, plus the OpenSearch link. `title` is the library's display name,
    /// so multiple shared libraries are distinguishable in reader menus.
    public static func root(title: String, baseURL: String, updated: Date = .now) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
        <id>\(escape(baseURL))/opds</id>
        <title>\(escape(title))</title>
        <updated>\(iso(updated))</updated>
        <author><name>Stacks</name></author>
        <link rel="self" href="\(escape(baseURL))/opds" type="\(navigationContentType)"/>
        <link rel="start" href="\(escape(baseURL))/opds" type="\(navigationContentType)"/>
        <link rel="search" href="\(escape(baseURL))/opds/search.xml" type="\(openSearchContentType)"/>
        \(navigationEntry(title: "All Books", href: "/opds/books", baseURL: baseURL, updated: updated))
        \(navigationEntry(title: "Authors", href: "/opds/authors", baseURL: baseURL, updated: updated))
        \(navigationEntry(title: "Series", href: "/opds/series", baseURL: baseURL, updated: updated))
        \(navigationEntry(title: "Tags", href: "/opds/tags", baseURL: baseURL, updated: updated))
        \(navigationEntry(title: "Formats", href: "/opds/formats", baseURL: baseURL, updated: updated))
        \(navigationEntry(title: "Newest", href: "/opds/newest", baseURL: baseURL, updated: updated))
        </feed>
        """
    }

    /// A navigation feed listing one facet dimension's values (authors,
    /// series, tags, formats), each entry linking to the acquisition feed of
    /// that value's books (`href` is the bare facet path, e.g.
    /// `/opds/authors`; links append the percent-encoded value).
    public static func facetFeed(
        title: String,
        values: [(value: String, count: Int)],
        baseURL: String,
        href: String,
        updated: Date = .now
    ) -> String {
        let entries = values.map { value, count -> String in
            let entryHref = "\(escape(baseURL))\(escape(href))/\(percentEncode(value))"
            return """
            <entry>
              <title>\(escape(value))</title>
              <id>\(entryHref)</id>
              <updated>\(iso(updated))</updated>
              <content type="text">\(count) books</content>
              <link rel="subsection" href="\(entryHref)" type="\(acquisitionContentType)"/>
            </entry>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>\(escape(baseURL))\(escape(href))</id>
          <title>\(escape(title))</title>
          <updated>\(iso(updated))</updated>
          <author><name>Stacks</name></author>
          <link rel="self" href="\(escape(baseURL))\(escape(href))" type="\(navigationContentType)"/>
          <link rel="start" href="\(escape(baseURL))/opds" type="\(navigationContentType)"/>
        \(entries)
        </feed>
        """
    }

    /// An acquisition feed (books, facet values, search results) with
    /// pagination. `pageHref` is the path for page 1 (e.g. `/opds/books`);
    /// the query parameter carries the page.
    public static func booksFeed(
        title: String,
        books: [IndexedBook],
        baseURL: String,
        page: Int = 1,
        pageHref: String,
        updated: Date = .now
    ) -> String {
        let start = (page - 1) * pageSize
        let slice = Array(books.dropFirst(start).prefix(pageSize))
        let hasNext = start + slice.count < books.count
        var links = ""
        if page > 1 {
            links += """
              <link rel="previous" href="\(escape(baseURL))\(escape(pageHref))?page=\(page - 1)" type="\(acquisitionContentType)"/>

            """
        }
        if hasNext {
            links += """
              <link rel="next" href="\(escape(baseURL))\(escape(pageHref))?page=\(page + 1)" type="\(acquisitionContentType)"/>

            """
        }
        let entries = slice.map { entry(book: $0, baseURL: baseURL) }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>\(escape(baseURL))\(escape(pageHref))</id>
          <title>\(escape(title))</title>
          <updated>\(iso(updated))</updated>
          <author><name>Stacks</name></author>
          <link rel="self" href="\(escape(baseURL))\(escape(pageHref))\(page > 1 ? "?page=\(page)" : "")" type="\(acquisitionContentType)"/>
          <link rel="start" href="\(escape(baseURL))/opds" type="\(navigationContentType)"/>
        \(links)\(entries)
        </feed>
        """
    }

    /// One book entry: identity, metadata, cover link, and acquisition links
    /// for every stored format.
    public static func entry(book: IndexedBook, baseURL: String) -> String {
        let authors = book.authors.map { "      <author><name>\(escape($0))</name></author>" }
            .joined(separator: "\n")
        let identifiers = book.identifiers.map { type, value in
            "      <dc:identifier>\(escape(type)):\(escape(value))</dc:identifier>"
        }.joined(separator: "\n")
        // Downloads are addressed by an extension-terminated path: readers
        // (KOReader especially) derive the file type from the last path
        // extension, so `?format=` hrefs are undownloadable. The real MIME type
        // covers readers that key off `type` instead.
        let formats = book.formats.map { format -> String in
            let name = format.filename.isEmpty ? "book.\(format.kind.lowercased())" : format.filename
            return """
              <link rel="http://opds-spec.org/acquisition/open-access" href="\(escape(baseURL))/api/books/\(book.id.uuidString)/download/\(percentEncode(name))" type="\(BookMediaType.mimeType(forKind: format.kind))"/>
            """
        }.joined(separator: "\n")
        let cover = book.coverHash.map { _ in
            """
              <link rel="http://opds-spec.org/cover" href="\(escape(baseURL))/api/books/\(book.id.uuidString)/cover" type="image/jpeg"/>
            """
        } ?? ""
        return """
        <entry>
          <title>\(escape(book.title))</title>
          <id>urn:uuid:\(book.id.uuidString)</id>
          <updated>\(iso(Date(timeIntervalSince1970: Double(book.modifiedMilliseconds) / 1_000)))</updated>
        \(authors)\(identifiers)\(cover)\(formats)
        </entry>
        """
    }

    // MARK: - Helpers

    /// The OpenSearch Description Document the root feed's `rel="search"` link
    /// points at (OPDS 1.2 expects the search relation to describe the search,
    /// not be the search URL itself). Clients — KOReader included — read the
    /// template out of here.
    public static func openSearchDescription(baseURL: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>Stacks</ShortName>
          <Description>Search this library</Description>
          <InputEncoding>UTF-8</InputEncoding>
          <Url type="\(acquisitionContentType)" template="\(escape(baseURL))/opds/search?q={searchTerms}"/>
        </OpenSearchDescription>
        """
    }

    /// A navigation entry. `href` is a path (e.g. `/opds/books`); both the
    /// entry id and the link are made absolute against `baseURL` so the feed is
    /// self-contained.
    private static func navigationEntry(title: String, href: String, baseURL: String, updated: Date) -> String {
        let url = "\(escape(baseURL))\(escape(href))"
        return """
        <entry>
          <title>\(escape(title))</title>
          <id>\(url)</id>
          <updated>\(iso(updated))</updated>
          <content type="text">\(escape(title))</content>
          <link rel="subsection" href="\(url)" type="\(acquisitionContentType)"/>
        </entry>
        """
    }

    /// XML-escapes text content and attribute values.
    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Percent-encodes a facet value for use as a single URL path segment.
    /// Keeps only RFC 3986 unreserved characters — `.urlPathAllowed` would
    /// leave "/" intact and break the route match for values containing it
    /// (the `:value` handler decodes with `removingPercentEncoding`).
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
