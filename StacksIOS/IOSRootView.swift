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
        // Long transfers (imports, downloads, uploads) surface here rather than
        // as a modal: an iOS spinner would hide the library for the duration of
        // a batch, and there is no toolbar popover idiom to use instead. The
        // Mac keeps its richer popover.
        .safeAreaInset(edge: .top, spacing: 0) {
            TransferProgressBar(session: session)
                .animation(.default, value: session.importActivity)
                .animation(.default, value: session.serverTransferActivity)
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
                // Completion is a system notification, not a sheet: the user
                // is usually elsewhere by the time a batch finishes.
                await session.notifyImportCompletion()
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
        // Errors a notification might have missed (denied authorization, a
        // failed download) land here — the backstop for notification-only
        // feedback.
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { session.lastError != nil },
                set: { presented in if !presented { session.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
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

    /// The facet value whose shelf is showing, if any.
    @State private var openValue: String?

    var body: some View {
        Group {
            if case .category = target, let browser = session.browser {
                // iOS-specific list: a row pushes the filtered shelf, the
                // filter sits under the title, and the back button returns.
                // The shared FacetListView is the Mac's middle column and does
                // none of that.
                IOSFacetList(browser: browser) { value in
                    openValue = value
                }
                .navigationTitle(target.title)
                .navigationDestination(item: $openValue) { value in
                    IOSFacetValueDetail(session: session, value: value)
                }
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
///
/// Tapping a cover selects it and pushes the detail screen (the Mac instead
/// opens the file, since it has a right-hand inspector and a double-click).
struct IOSGridDetail: View {
    @Bindable var session: LibrarySession
    /// Overrides the navigation title. Nil means the browser's name (the
    /// library for All Books/Audiobooks). A facet value passes its own name, so
    /// a filtered shelf is titled with the value rather than the library.
    var title: String?
    @State private var searchText = ""
    /// Routed by id (`IndexedBook` is not Hashable) — resolved against the
    /// browser's live list, so a metadata edit re-renders the same screen.
    @State private var detailBookID: UUID?

    private var selectedBookID: UUID? {
        guard session.selection.count == 1 else { return nil }
        return session.selection.first
    }

    private func book(withID id: UUID) -> IndexedBook? {
        session.browser?.books.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let browser = session.browser {
                CoverGridView(browser: browser, session: session)
                    .navigationTitle(title ?? browser.name)
                    // `.automatic` (the default) puts the field *under* the
                    // large title, scrolling with it. Forcing
                    // `.navigationBarDrawer(displayMode: .always)` kept it
                    // permanently in the bar, where it drew over the title —
                    // which is what made the shelf look broken.
                    .searchable(text: $searchText, prompt: "Search books")
                    .onChange(of: searchText) { _, newValue in
                        browser.searchText = newValue
                    }
                    // A tap selects (CoverGridView handles that); follow the
                    // selection with the detail screen. Guarded against
                    // re-pushing the same book, and against marquee-style
                    // multi-selection.
                    .onChange(of: session.selection) { _, _ in
                        guard let id = selectedBookID, detailBookID != id else { return }
                        detailBookID = id
                    }
                    .navigationDestination(item: $detailBookID) { id in
                        if let book = book(withID: id) {
                            IOSBookDetailView(session: session, book: book)
                        }
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
