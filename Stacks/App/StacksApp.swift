import SwiftUI

@main
struct StacksApp: App {
    /// Opens the library window at launch (a `Window` scene does not present
    /// itself; see `AppDelegate`).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Identifies the single library window so the menu bar extra can open or
    /// focus it.
    static let libraryWindowID = "library"

    @State private var session = LibrarySession()
    @State private var settings = AppSettings()
    /// The macOS-only feature cluster (device store + in-process server).
    /// Injected into the environment; iOS never builds one.
    @State private var mac = MacFeatures()
    @State private var loginItem = LoginItem()

    init() {
        // One-time migration of the Application Support directory so
        // SyncState/outbox state survives the rename (see StacksSupportMigrator).
        StacksSupportMigrator.migrateOnce()
        // Apply the persisted Dock-icon choice before any scene exists, so the
        // app never flashes a Dock icon it is about to remove.
        let hideDockIcon = AppSettings.hideDockIcon()
        MainActor.assumeIsolated {
            AppLifecycle.applyActivationPolicy(hideDockIcon: hideDockIcon)
        }
    }

    var body: some Scene {
        // A single library window (`Window`, not `WindowGroup`): re-opening
        // focuses the existing window instead of spawning duplicates, which
        // matters when the menu bar extra is the only entry point.
        //
        // `Window` does NOT present its window at launch — unlike `WindowGroup`
        // it is created on demand — so `LibraryWindowOpener` below opens it.
        Window("Stacks", id: Self.libraryWindowID) {
            ContentView(session: session)
                .environment(mac)
                .task {
                    // Wire the session's platform hooks (device selection
                    // clearing, sharing lifecycle) to the macOS stores.
                    mac.attach(to: session)
                    // Skip auto-reopen under UI testing so tests start from a
                    // deterministic welcome screen.
                    if !CommandLine.arguments.contains("--ui-testing") {
                        await session.reopenLibraries()
                    }
                }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            AppCommands(session: session, mac: mac)
        }

        // The background entry point: reachable with or without a Dock icon.
        // A template symbol (not the app icon) so it inverts correctly in a
        // dark menu bar.
        MenuBarExtra {
            // The extra always exists, so it is the only dependable place to
            // open the library window at launch (see `LibraryWindowOpener`).
            StacksMenuBarContent(
                session: session, settings: settings, mac: mac, loginItem: loginItem
            )
            .publishingLibraryWindowOpener(id: Self.libraryWindowID)
        } label: {
            Image(systemName: "book.closed")
        }

        Settings {
            SettingsView(settings: settings)
                .environment(\.librarySession, session)
                .environment(mac)
        }
    }
}

/// The app's menu commands. `@FocusedValue` resolves against the focused view
/// (the browser publishes its search-field focus binding), so Cmd-F can drive
/// it from here without touching the session.
private struct AppCommands: Commands {
    let session: LibrarySession
    let mac: MacFeatures

    @FocusedValue(\.searchFocus) private var searchFocus: FocusState<Bool>.Binding?

    /// The browser context is the home library (device mode counts — active
    /// library resolves to home there). Peer mode does not: the Books-menu
    /// chrome (Edit Metadata, Fetch Missing, Open in Reader, Show in Finder,
    /// Copy to Library) is home-only.
    private var isHomeContext: Bool {
        session.activeLibrary === session.home
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Create Library…") { session.createNewLibrary() }
                .keyboardShortcut("n", modifiers: [.command, .shift])   // Cmd+N reserved
            Divider()
            Button("Close Library") { Task { await session.closeLibrary() } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        // File menu: library open/import actions (the old custom Library menu
        // is gone — Open moves to File with Cmd+O).
        CommandGroup(after: .newItem) {
            Button("Open Library…") { session.present(.open) }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                if session.recentLibraries.isEmpty {
                    Text("No Recent Libraries")
                }
                ForEach(session.recentLibraries) { entry in
                    Button(entry.name) {
                        Task { await session.openRequested(at: entry.url) }
                    }
                }
            }
            Divider()
            Button("Connect to Server…") { session.connectToServerPresented = true }
                .help("Connect to a server by host:port (e.g. a Linux box that can't advertise)")
            Divider()
            Button("Import Books…") { session.present(.addBooks) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Import Calibre Library…") { session.present(.calibre) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Send to Device") {
                Task { await session.sendSelectionToDevice(using: mac.devices) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(session.selection.isEmpty || mac.devices.selectedDeviceID == nil)
        }
        // Books menu: actions on the library selection and its metadata.
        // All items are HOME-ONLY chrome (peers are browse + transfer in this
        // slice), so they are disabled when a peer is the browser context.
        CommandMenu("Books") {
            Button("Edit Metadata…") {
                session.metadataEditQueue = session.selectionBooks
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || mac.devices.selectedDeviceID != nil || !isHomeContext)
            Button("Fetch Missing Metadata…") {
                Task { await session.enrichAllBooksMissingMetadata() }
            }
            .disabled(session.isLibraryUnavailable || !isHomeContext)
            Divider()
            Button("Open in Reader") {
                if let id = session.selection.first {
                    Task { await session.open(id: id) }
                }
            }
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || mac.devices.selectedDeviceID != nil || !isHomeContext)
            Button("Show in Finder") {
                if let id = session.selection.first {
                    Task { await session.reveal(id: id) }
                }
            }
            .disabled(session.selection.isEmpty || session.isLibraryUnavailable || mac.devices.selectedDeviceID != nil || !isHomeContext)
            Divider()
            // Server transfers: upload home selection to a connected server
            // (one item per server — "send to a, send to b"), or download
            // the active remote's selection into home.
            Menu("Send to Server") {
                ForEach(session.remotes) { remote in
                    Button(remote.name) {
                        Task { await session.sendSelectionToServer(remote) }
                    }
                }
            }
            .disabled(session.remotes.isEmpty || session.selection.isEmpty || mac.devices.selectedDeviceID != nil || !isHomeContext)
            Button("Import from Server") {
                if let remote = session.activeRemote {
                    Task { await session.importSelectionFromRemote(remote) }
                }
            }
            .disabled(session.activeRemote?.selection.isEmpty ?? true || session.home == nil || !session.isRemoteContext)
        }
        // Edit menu: deletion of the ACTIVE library's selection (Cmd+Delete;
        // the bare Delete/Backspace key is handled in the grid/table views).
        // Peers trash into their own trash; device mode stays disabled.
        CommandGroup(after: .pasteboard) {
            Button("Delete") {
                if let browser = session.browser {
                    browser.requestDelete(ids: browser.selection)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(
                session.activeLibrary?.selection.isEmpty ?? true
                    || session.activeLibrary?.isLibraryUnavailable ?? true
                    || mac.devices.selectedDeviceID != nil
            )
        }
        CommandGroup(after: .textEditing) {
            Button("Find") {
                searchFocus?.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(searchFocus == nil)
        }
    }
}
