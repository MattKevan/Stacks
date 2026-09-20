import StacksKit
import SwiftUI

/// A facet category's value list, as a push-navigation screen.
///
/// The shared `FacetListView` is built for the Mac's middle column: it selects
/// a value into `facetNavigation` for a detail column to react to, and pins its
/// filter field over the top with `safeAreaInset` (which on iOS draws across
/// the navigation title). Neither suits a phone.
///
/// This is the iOS shape instead: a plain list where a row pushes the filtered
/// shelf, the filter is a real `.searchable` field that sits under the title,
/// and the standard back button returns.
struct IOSFacetList: View {
    let browser: any LibraryBrowser
    /// Called when a value is chosen, so the caller can push it. The caller
    /// applies the filter — this view must not, because `selectValue` toggles
    /// and would clear a value that was already selected.
    let onSelect: (String) -> Void
    @State private var searchText = ""

    private var values: [(value: String, count: Int)] {
        switch browser.facetNavigation.category {
        case .author: browser.authors
        case .series: browser.series
        case .tag: browser.tags
        case .format: browser.formats
        case nil: []
        }
    }

    private var filteredValues: [(value: String, count: Int)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter { $0.value.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(filteredValues, id: \.value) { item in
                Button {
                    onSelect(item.value)
                } label: {
                    HStack {
                        Text(item.value)
                        Spacer()
                        Text("\(item.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            if filteredValues.isEmpty, !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        // Under the title, like the All Books shelf — not overlaid on it.
        .searchable(text: $searchText, prompt: "Filter \(browser.facetNavigation.category?.displayName ?? "values")")
    }
}

/// The shelf for one facet value, pushed from `IOSFacetList`.
///
/// Applies the value to the browser on appear and clears it on disappear, so
/// the filtered grid is driven by the same `facetNavigation` state the Mac
/// uses, and leaving the screen does not leave a stale filter behind.
struct IOSFacetValueDetail: View {
    @Bindable var session: LibrarySession
    let value: String

    var body: some View {
        IOSGridDetail(session: session)
            .navigationTitle(value)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Set, not toggle. `FacetNavigation.selectValue` toggles when
                // the value is already selected (a Mac middle-column
                // affordance: re-clicking a value clears it), which would make
                // this screen show the *unfiltered* shelf when arriving from a
                // list where the value was already active.
                if session.browser?.facetNavigation.value != value {
                    session.browser?.selectValue(value)
                }
            }
            .onDisappear {
                // Leaving the filtered shelf clears the filter, so returning to
                // the list is unfiltered and re-entering any value works.
                session.browser?.selectValue(nil)
            }
    }
}
