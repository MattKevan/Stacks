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
    @State private var isConnectingToServer = false

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
        // The same connection dialogs the Mac uses (StacksUI).
        .sheet(item: Binding(
            get: { session.credentialPrompt },
            set: { session.credentialPrompt = $0 }
        )) { library in
            CredentialPromptView(library: library, session: session)
        }
        .sheet(isPresented: $isConnectingToServer) {
            ConnectToServerView(session: session)
        }
    }

    @ViewBuilder
    private var shell: some View {
        if sizeClass == .regular {
            IPadBrowser(
                session: session,
                isImporting: $isImporting,
                isConnectingToServer: $isConnectingToServer
            )
        } else {
            IPhoneBrowser(
                session: session,
                isImporting: $isImporting,
                isConnectingToServer: $isConnectingToServer
            )
        }
    }
}

/// The browsing contexts a shelf can show. Facets (Authors/Series/Tags/Formats)
/// filter whichever library is the current browser context, so the same list
/// works for the home library and for a connected server.
enum IOSBrowseTarget: Hashable, Identifiable {
    case allBooks
    case audiobooks
    case category(FacetType)

    var id: Self { self }

    var title: String {
        switch self {
        case .allBooks: "All Books"
        case .audiobooks: "Audiobooks"
        case .category(let type): type.displayName
        }
    }

    var symbol: String {
        switch self {
        case .allBooks: "books.vertical"
        case .audiobooks: "headphones"
        case .category(let type): type.sidebarSymbol
        }
    }

    static let facetCategories: [FacetType] = [.author, .series, .tag, .format]
}

extension LibrarySession {
    /// Applies a browse target to the browser context (home or a remote).
    func apply(_ target: IOSBrowseTarget) {
        switch target {
        case .allBooks:
            selectCategory(nil)
        case .audiobooks:
            selectAudiobooks()
        case .category(let type):
            selectCategory(type)
        }
    }

    /// Switches the browser context to a connected server, then applies the
    /// same target against it. Selecting the remote clears the home facet, so
    /// the target is re-applied afterwards.
    func browseRemote(_ remote: RemoteLibraryBrowser, _ target: IOSBrowseTarget) {
        selectRemote(remote.id)
        switch target {
        case .allBooks:
            break
        case .audiobooks:
            remote.isShowingAudiobooks = true
            Task { await remote.refreshBooks() }
        case .category(let type):
            remote.selectCategory(type)
        }
    }
}

/// iPad: the Mac's three-column shape — sidebar, facet values, covers.
private struct IPadBrowser: View {
    @Bindable var session: LibrarySession
    @Binding var isImporting: Bool
    @Binding var isConnectingToServer: Bool

    var body: some View {
        NavigationSplitView {
            IOSLibrarySidebar(
                session: session,
                isConnectingToServer: $isConnectingToServer
            )
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

/// iPhone: a navigation stack with the browse targets one level down.
///
/// The facet values need a screen of their own (there is no middle column), so
/// "Authors" pushes a value list which pushes the shelf.
private struct IPhoneBrowser: View {
    @Bindable var session: LibrarySession
    @Binding var isImporting: Bool
    @Binding var isConnectingToServer: Bool
    @State private var path: [IOSBrowseTarget] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Library") {
                    ForEach([IOSBrowseTarget.allBooks, .audiobooks]) { target in
                        NavigationLink(value: target) {
                            Label(target.title, systemImage: target.symbol)
                        }
                    }
                }
                Section("Browse") {
                    ForEach(IOSBrowseTarget.facetCategories, id: \.self) { type in
                        NavigationLink(value: IOSBrowseTarget.category(type)) {
                            Label(type.displayName, systemImage: type.sidebarSymbol)
                        }
                    }
                }
                IOSSharedSection(
                    session: session,
                    path: $path,
                    isConnectingToServer: $isConnectingToServer
                )
            }
            .navigationTitle(session.home?.name ?? "Stacks")
            .navigationDestination(for: IOSBrowseTarget.self) { target in
                IOSTargetDetail(session: session, target: target, path: $path)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Books", systemImage: "plus") { isImporting = true }
                }
            }
        }
    }
}

/// A facet target's screen: the value list, which pushes the filtered shelf.
private struct IOSTargetDetail: View {
    @Bindable var session: LibrarySession
    let target: IOSBrowseTarget
    @Binding var path: [IOSBrowseTarget]

    var body: some View {
        Group {
            if case .category = target, let browser = session.browser {
                FacetListView(browser: browser)
                    .navigationTitle(target.title)
            } else {
                IOSGridDetail(session: session)
                    .navigationTitle(target.title)
            }
        }
        .task {
            // Entering a facet screen selects the category (the values list is
            // driven by `facetNavigation.category`).
            if case .category = target {
                session.apply(target)
            }
        }
    }
}

/// The cover shelf itself — shared `CoverGridView` (four fixed columns on iOS)
/// with search and the browser-context title.
private struct IOSGridDetail: View {
    @Bindable var session: LibrarySession
    @State private var searchText = ""

    var body: some View {
        Group {
            if let browser = session.browser {
                CoverGridView(browser: browser, session: session)
                    .navigationTitle(browser.name)
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search books"
                    )
                    .onChange(of: searchText) { _, newValue in
                        browser.searchText = newValue
                    }
            } else {
                ContentUnavailableView("No Library", systemImage: "books.vertical")
            }
        }
    }
}

/// The Shared section for iPhone's list: discovered servers connect on tap,
/// connected ones push straight to their shelf.
private struct IOSSharedSection: View {
    @Bindable var session: LibrarySession
    @Binding var path: [IOSBrowseTarget]
    @Binding var isConnectingToServer: Bool

    var body: some View {
        Section("Shared") {
            ForEach(session.remotes) { remote in
                Button {
                    session.browseRemote(remote, .allBooks)
                    path.append(.allBooks)
                } label: {
                    RemoteRowLabel(browser: remote) {
                        session.disconnectRemote(remote.id)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(unconnected) { library in
                Button {
                    Task { await session.connect(to: library) }
                } label: {
                    Label(library.name, systemImage: "network")
                }
                .buttonStyle(.plain)
            }
            if session.discovery.libraries.isEmpty && session.remotes.isEmpty {
                Text(session.discovery.browseError == nil
                    ? "Browsing for libraries on this network…"
                    : "Local Network access is off")
                    .foregroundStyle(.secondary)
            }
            Button {
                isConnectingToServer = true
            } label: {
                Label("Connect to Server…", systemImage: "plus.circle")
            }
        }
    }

    private var unconnected: [DiscoveredLibrary] {
        session.discovery.libraries
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { library in
                !session.remotes.contains { $0.id == library.id }
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

/// The iPad sidebar. iPhone has no sidebar, so its equivalent list is inline in
/// `IPhoneBrowser`.
struct IOSLibrarySidebar: View {
    @Bindable var session: LibrarySession
    @Binding var isConnectingToServer: Bool

    var body: some View {
        List {
            Section("Library") {
                ForEach([IOSBrowseTarget.allBooks, .audiobooks]) { target in
                    Button {
                        session.apply(target)
                    } label: {
                        Label(target.title, systemImage: target.symbol)
                    }
                }
            }
            Section("Browse") {
                ForEach(IOSBrowseTarget.facetCategories, id: \.self) { type in
                    Button {
                        session.apply(.category(type))
                    } label: {
                        Label(type.displayName, systemImage: type.sidebarSymbol)
                    }
                }
            }
            // The network libraries: same rows the Mac sidebar shows.
            SharedLibrariesView(session: session)
            Section {
                Button {
                    isConnectingToServer = true
                } label: {
                    Label("Connect to Server…", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle(session.home?.name ?? "Stacks")
    }
}
