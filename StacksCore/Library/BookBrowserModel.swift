import Foundation

/// Toolbar sort order for the library browser (Finder-style). Shared by the
/// macOS app (which aliases `BrowserSortOrder` to this) and any other client
/// of the core.
public enum BookSortOrder: String, CaseIterable, Sendable {
    case name
    case dateAdded
}

/// Pure client-side browse state for a pulled book snapshot: search text,
/// facet selection, and sort order. Applies the exact filter+sort the remote
/// browser used to do inline — facet first when one is active, else a
/// case-insensitive substring search over title/authors/tags/series, then the
/// chosen sort. Tested in isolation; the browser views stay thin.
public struct BookBrowserModel: Sendable {
    public var searchText = ""
    public var facetNavigation = FacetNavigation()
    public var sortOrder: BookSortOrder = .name

    public init() {}

    /// Search + facet filtering applied client-side over the pulled books,
    /// then sorted. Facet filtering takes precedence over search text (a
    /// selected facet value narrows the category column, search is ignored
    /// while one is active).
    public func books(from remoteBooks: [IndexedBook]) -> [IndexedBook] {
        let filtered: [IndexedBook]
        if let facet = facetNavigation.activeFacet {
            filtered = remoteBooks.filter { book in
                switch facet.type {
                case .author: return book.authors.contains(facet.value)
                case .series: return book.series == facet.value
                case .tag: return book.tags.contains(facet.value)
                case .format: return book.formats.contains { $0.kind.lowercased() == facet.value.lowercased() }
                }
            }
        } else {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            filtered = query.isEmpty ? remoteBooks : remoteBooks.filter {
                $0.title.lowercased().contains(query)
                    || $0.authors.contains { $0.lowercased().contains(query) }
                    || $0.tags.contains { $0.lowercased().contains(query) }
                    || ($0.series?.lowercased().contains(query) ?? false)
            }
        }
        switch sortOrder {
        case .name:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateAdded:
            return filtered.sorted { ($0.addedMilliseconds ?? 0) > ($1.addedMilliseconds ?? 0) }
        }
    }
}
