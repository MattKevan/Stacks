import StacksKit
import SwiftUI
import UniformTypeIdentifiers

/// The iOS shell. Adapts by size class rather than device:
///
/// - **iPad (regular)** mirrors the Mac: a three-column `NavigationSplitView`
///   (library/facets, facet values, covers).
/// - **iPhone (compact)** is a `NavigationStack` with a bottom toolbar — the
///   categories that the iPad keeps in the sidebar move into the bar, because
///   there is nowhere to put a sidebar.
///
/// Everything inside the columns is the shared `StacksUI`.
struct IOSRootView: View {
    @Bindable var session: LibrarySession
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isImporting = false

    var body: some View {
        Group {
            switch session.state {
            case .loaded:
                shell
            case .loading:
                ProgressView("Opening library…")
            case .failed(let message):
                ContentUnavailableView(
                    "Can’t Open Library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .welcome:
                ProgressView("Preparing library…")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                .epub, .pdf, .data,
            ]
                + AudioFormats.extensions.compactMap { UTType(filenameExtension: $0) }
                + ["mobi", "azw", "azw3"].compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task {
                // Picked files are security-scoped; the import reads them, so
                // hold access for its duration.
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
                await session.importFiles(urls: urls)
                session.presentImportReport()
            }
        }
        // Import feedback. macOS routes this through notifications + the
        // inspector; a sheet is the right affordance on iOS, where the user is
        // already looking at the screen that just changed.
        .sheet(isPresented: Binding(
            get: { session.importReport != nil },
            set: { presented in if !presented { session.importReport = nil } }
        )) {
            if let report = session.importReport {
                IOSImportReportView(report: report) { session.importReport = nil }
            }
        }
    }

    @ViewBuilder
    private var shell: some View {
        if sizeClass == .regular {
            IPadBrowser(session: session, isImporting: $isImporting)
        } else {
            IPhoneBrowser(session: session, isImporting: $isImporting)
        }
    }
}

/// iPad: the Mac's three-column shape — sidebar, facet values, covers.
private struct IPadBrowser: View {
    @Bindable var session: LibrarySession
    @Binding var isImporting: Bool

    var body: some View {
        NavigationSplitView {
            IOSLibrarySidebar(session: session)
        } content: {
            if let browser = session.browser,
               let category = browser.facetNavigation.category {
                FacetListView(browser: browser)
                    .navigationTitle(category.displayName)
            } else {
                ContentUnavailableView(
                    "Choose a Category",
                    systemImage: "square.grid.2x2",
                    description: Text("Pick Authors, Series, Tags or Formats to narrow the shelf.")
                )
            }
        } detail: {
            IOSGridDetail(session: session)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Books", systemImage: "plus") { isImporting = true }
                    }
                }
        }
    }
}

/// iPhone: a navigation stack with the categories in a bottom toolbar.
private struct IPhoneBrowser: View {
    @Bindable var session: LibrarySession
    @Binding var isImporting: Bool

    var body: some View {
        NavigationStack {
            IOSGridDetail(session: session)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Add Books", systemImage: "plus") { isImporting = true }
                        Spacer()
                        Button {
                            session.selectCategory(nil)
                        } label: {
                            Label("All", systemImage: "books.vertical")
                        }
                        Spacer()
                        Button {
                            session.selectAudiobooks()
                        } label: {
                            Label("Audio", systemImage: "headphones")
                        }
                    }
                }
        }
    }
}

/// The cover shelf itself — shared `CoverGridView` (four fixed columns on iOS).
private struct IOSGridDetail: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Group {
            if let browser = session.browser {
                CoverGridView(browser: browser, session: session)
                    .navigationTitle(browser.name)
            } else {
                ContentUnavailableView("No Library", systemImage: "books.vertical")
            }
        }
    }
}

/// The result of an import: the one-line summary plus the files that failed or
/// were already in the library.
private struct IOSImportReportView: View {
    let report: ImportReport
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Label(
                    report.summary,
                    systemImage: report.failed.isEmpty
                        ? "checkmark.circle"
                        : "exclamationmark.triangle"
                )
                if !report.failed.isEmpty {
                    Section("Couldn’t Import") {
                        ForEach(report.failed, id: \.sourceURL) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.sourceURL.lastPathComponent)
                                if case let .failed(message) = item.status {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !report.duplicates.isEmpty {
                    Section("Already in the Library") {
                        ForEach(report.duplicates, id: \.sourceURL) { item in
                            Text(item.sourceURL.lastPathComponent)
                        }
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

/// The iPad sidebar. The Mac sidebar carries device and sharing sections that
/// iOS has no counterpart for, so this is its own (much smaller) list.
struct IOSLibrarySidebar: View {
    @Bindable var session: LibrarySession

    private let categories: [FacetType] = [.author, .series, .tag, .format]

    var body: some View {
        List {
            Section("Library") {
                Button {
                    session.selectCategory(nil)
                } label: {
                    Label("All Books", systemImage: "books.vertical")
                }
                Button {
                    session.selectAudiobooks()
                } label: {
                    Label("Audiobooks", systemImage: "headphones")
                }
            }
            Section("Browse") {
                ForEach(categories, id: \.self) { type in
                    Button {
                        session.selectCategory(type)
                    } label: {
                        Label(type.displayName, systemImage: type.sidebarSymbol)
                    }
                }
            }
        }
        .navigationTitle(session.home?.name ?? "Stacks")
    }
}
