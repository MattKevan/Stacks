import StacksKit
import StacksSync
import SwiftUI

/// Libraries advertised on the local network, plus the ones already connected.
///
/// Lifted out of the macOS sidebar so iOS can render the same information in
/// its own chrome: tap a discovered library to connect, tap a connected one to
/// browse it, eject to disconnect. The server remains listed while it
/// advertises, so reconnecting is one tap.
struct SharedLibrariesView: View {
    @Bindable var session: LibrarySession
    /// iOS-style rows are whole-row buttons; the Mac sidebar uses selection
    /// tags instead, so it passes `false` and handles selection itself.
    var usesSelectionBinding: Bool = false
    /// Called when a connected remote is chosen (Mac sidebar sets selection).
    var onSelectRemote: ((UUID) -> Void)?

    private var discovered: [DiscoveredLibrary] {
        session.discovery.libraries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var unconnected: [DiscoveredLibrary] {
        discovered.filter { library in
            !session.remotes.contains { $0.id == library.id }
        }
    }

    var body: some View {
        Section("Shared") {
            ForEach(session.remotes) { browser in
                remoteRow(browser)
            }
            if discovered.isEmpty && session.remotes.isEmpty {
                Text(session.discovery.browseError == nil
                    ? "Browsing for libraries on this network…"
                    : "Local Network access is off")
                    .foregroundStyle(.secondary)
            }
            ForEach(unconnected) { library in
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
            if let error = session.discovery.browseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func remoteRow(_ browser: RemoteLibraryBrowser) -> some View {
        if usesSelectionBinding {
            // Mac sidebar: the row is a selection tag; selection drives the
            // browser context.
            Button {
                onSelectRemote?(browser.id)
            } label: {
                remoteLabel(browser)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                session.selectRemote(browser.id)
            } label: {
                remoteLabel(browser)
            }
            .buttonStyle(.plain)
        }
    }

    private func remoteLabel(_ browser: RemoteLibraryBrowser) -> some View {
        RemoteRowLabel(browser: browser) {
            session.disconnectRemote(browser.id)
        }
    }
}

/// The label of a connected-remote row: name (plus a "Disconnected" state),
/// the offline-queue badge, and the eject button. Shared so the Mac sidebar's
/// disclosure rows and iOS's plain rows stay identical.
struct RemoteRowLabel: View {
    let browser: RemoteLibraryBrowser
    let onEject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(browser.name)
                    if !browser.isConnected {
                        Text("Disconnected")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } icon: {
                Image(systemName: browser.isConnected ? "network" : "network.slash")
                    .foregroundStyle(browser.isConnected ? Color.primary : Color.orange)
            }
            Spacer()
            PendingBadge(browser: browser)
            Button(action: onEject) {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(.borderless)
            .help("Disconnect from \(browser.name)")
        }
        .contentShape(Rectangle())
    }
}

/// The offline-queue badge on a connected Shared row: how many edits are queued
/// until the server is reachable again.
struct PendingBadge: View {
    let browser: RemoteLibraryBrowser
    @State private var count = 0

    var body: some View {
        Group {
            if count > 0 {
                Text("\(count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            count = await browser.pendingCount()
        }
    }
}
