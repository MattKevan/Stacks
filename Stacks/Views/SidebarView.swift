import StacksKit
import StacksSync
import StacksServerKit
import Foundation
import SwiftUI

/// One selectable row in the sidebar: All Books, a library facet category,
/// or a connected device (Finder-style, with eject).
/// The selectable rows under a connected remote's disclosure group.
enum RemoteSubsection: Hashable {
    case allBooks
    case audiobooks
    case category(FacetType)
}

enum SidebarItem: Hashable {
    case allBooks
    case audiobooks
    case category(FacetType)
    case remote(UUID, RemoteSubsection)
    case device(UUID)
}

struct SidebarView: View {
    @Environment(MacFeatures.self) private var mac
    @Bindable var session: LibrarySession

    /// The facet categories offered in the Library and remote sections, in order.
    static let libraryCategories: [FacetType] = [.author, .series, .tag, .format]

    var body: some View {
        List(selection: Binding<SidebarItem?>(
            get: {
                // The connected remote is a selectable context, like the
                // pre-network peers: clicking it shows its books while home
                // stays open underneath.
                if let remote = session.activeRemote {
                    if remote.isShowingAudiobooks {
                        return .remote(remote.id, .audiobooks)
                    }
                    if let category = remote.facetNavigation.category {
                        return .remote(remote.id, .category(category))
                    }
                    return .remote(remote.id, .allBooks)
                }
                if let id = mac.devices.selectedDeviceID {
                    return .device(id)
                }
                // The browser context is the active library: rows map to
                // `.allBooks`/`.audiobooks`/`.category`.
                guard let library = session.activeLibrary else { return .allBooks }
                if library.isShowingAudiobooks {
                    return .audiobooks
                }
                if let category = library.facetNavigation.category {
                    return .category(category)
                }
                return .allBooks
            },
            set: { item in
                switch item {
                case .allBooks:
                    session.selectCategory(nil)
                case .audiobooks:
                    session.selectAudiobooks()
                case let .category(category):
                    session.selectCategory(category)
                case let .remote(id, subsection):
                    session.selectRemote(id)
                    if let remote = session.activeRemote, remote.id == id {
                        // Selecting a dropped server attempts a reconnect; a
                        // successful pull flips the sidebar state back.
                        if !remote.isConnected {
                            Task { try? await remote.refreshBooksThrowing() }
                        }
                        switch subsection {
                        case .allBooks:
                            remote.facetNavigation.clear()
                            remote.isShowingAudiobooks = false
                        case .audiobooks:
                            remote.facetNavigation.clear()
                            remote.isShowingAudiobooks = true
                        case let .category(category):
                            remote.isShowingAudiobooks = false
                            remote.facetNavigation.selectCategory(category)
                        }
                    }
                case let .device(id):
                    session.selectDevice(id, using: mac.devices)
                case nil:
                    break
                }
            }
        )) {
            Section("Library") {
                Label("All Books", systemImage: "books.vertical")
                    .tag(SidebarItem.allBooks)
                Label("Audiobooks", systemImage: "headphones")
                    .tag(SidebarItem.audiobooks)
                ForEach(SidebarView.libraryCategories, id: \.self) { category in
                    Label(category.displayName, systemImage: category.sidebarSymbol)
                        .tag(SidebarItem.category(category))
                }
            }
            if !mac.devices.devices.isEmpty {
                Section("Devices") {
                    ForEach(mac.devices.devices) { device in
                        HStack(spacing: 6) {
                            Label(device.name, systemImage: "externaldrive")
                            Spacer()
                            Button {
                                Task { await mac.devices.eject(device.id) }
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Eject \(device.name)")
                        }
                        .tag(SidebarItem.device(device.id))
                        .contentShape(Rectangle())
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers, deviceID: device.id)
                        }
                    }
                }
            }
            SharedLibrariesSection(session: session)
        }
        .listStyle(.sidebar)
    }

    /// LAN libraries advertised over Bonjour. The rows live in StacksUI
    /// (`SharedLibrariesView`) so iOS renders the same information; here they
    /// carry sidebar selection tags (the disclosure of facet subsections) and
    /// a whole-row tap sets the browser context.
    private struct SharedLibrariesSection: View {
        @Bindable var session: LibrarySession
        /// The connected server whose addresses the Get Info alert shows.
        @State private var infoServer: ServerInfo?

        var body: some View {
            Section("Shared") {
                ForEach(session.remotes) { browser in
                    // A disclosure group, like the pre-network peers: the
                    // header selects the remote (All Books) and toggles the
                    // facet subsections; eject disconnects but the server
                    // stays listed (reconnectable) while it advertises.
                    DisclosureGroup {
                        Label("Audiobooks", systemImage: "headphones")
                            .tag(SidebarItem.remote(browser.id, .audiobooks))
                        ForEach(SidebarView.libraryCategories, id: \.self) { category in
                            Label(category.displayName, systemImage: category.sidebarSymbol)
                                .tag(SidebarItem.remote(browser.id, .category(category)))
                        }
                    } label: {
                        RemoteRowLabel(browser: browser) {
                            session.disconnectRemote(browser.id)
                        }
                    }
                    .tag(SidebarItem.remote(browser.id, .allBooks))
                    .contextMenu {
                        Button("Get Info") { presentInfo(for: browser) }
                    }
                    .alert(
                        infoServer?.title ?? "",
                        isPresented: Binding(
                            get: { infoServer != nil },
                            set: { if !$0 { infoServer = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(infoServer?.message ?? "")
                    }
                }
                ForEach(unconnectedDeferredToStacksUI) { library in
                    Button {
                        Task { await session.connect(to: library) }
                    } label: {
                        HStack(spacing: 6) {
                            Label(library.name, systemImage: "network")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        /// Discovered libraries not already connected (connected ones are the
        /// disclosure rows above).
        private var unconnectedDeferredToStacksUI: [DiscoveredLibrary] {
            session.discovery.libraries
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .filter { library in
                    !session.remotes.contains { $0.id == library.id }
                }
        }

        /// Get Info: the numeric address(es) of the connected server. The
        /// connection host is already an IP for Bonjour-discovered servers; a
        /// hand-typed host resolves here, falling back to the typed host when
        /// the lookup fails.
        private func presentInfo(for browser: RemoteLibraryBrowser) {
            let addresses = LocalNetwork.ipAddresses(of: browser.host)
            let shown = addresses.isEmpty ? [browser.host] : addresses
            infoServer = ServerInfo(
                id: browser.id,
                title: browser.name,
                message: shown.map { "http://\(LocalNetwork.urlHost($0)):\(browser.port)" }
                    .joined(separator: "\n")
            )
        }

        /// The Get Info alert's payload; the browser's id doubles as the
        /// alert's identity, so re-asking while one is open replaces it.
        private struct ServerInfo: Identifiable {
            let id: UUID
            let title: String
            let message: String
        }
    }

    /// Finder-style drag: file URLs dropped on a device row are sent to that
    /// device (selecting it first so the send targets the right one).
    private func handleDrop(_ providers: [NSItemProvider], deviceID: UUID) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await LibrarySession.loadURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await session.sendDroppedFiles(urls: urls, to: deviceID, using: mac.devices)
        }
        return true
    }
}

// `EnvironmentValues.librarySession` now lives in StacksUI
// (UI/SessionEnvironment.swift) because shared views read it.
