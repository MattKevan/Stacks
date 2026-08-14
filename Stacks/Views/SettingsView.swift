import SwiftUI

/// Standard macOS preferences pane (Settings… / Cmd-,). The Diagnostics
/// section moved here from the toolbar so the window toolbar stays clean.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.librarySession) private var librarySession

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            libraryTab
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
            sharingTab
                .tabItem {
                    Label("Sharing", systemImage: "network")
                }
            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
    }

    /// Share the open library over the LAN: the in-process server, Bonjour
    /// advertising, and optional basic auth. The server serves the repository
    /// the app already has open — one journal, one writer. The OPDS catalog
    /// is an independent surface on the same server and port.
    private var sharingTab: some View {
        Form {
            Section("Share This Library") {
                Toggle("Share on the local network", isOn: shareBinding)
                if settings.shareLibraryOverNetwork {
                    Toggle("Advertise with Bonjour", isOn: $settings.advertiseWithBonjour)
                        .help("Other Stacks clients discover this library automatically")
                    Toggle("Require a password", isOn: $settings.requireSharePassword)
                    if settings.requireSharePassword {
                        TextField("Username", text: $settings.shareUsername)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: passwordBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if settings.shareLibraryOverNetwork || settings.shareOPDSOverNetwork {
                    LabeledContent("Port") {
                        TextField("Port", value: $settings.sharePort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("The port the shared server binds (restart sharing to apply)")
                }
                if let sharing = librarySession?.sharing {
                    if sharing.isServingSync {
                        LabeledContent("Address", value: sharing.addressString)
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sharing.addressString, forType: .string)
                        }
                    } else if let error = sharing.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section("OPDS Catalog") {
                Toggle("Share OPDS catalog", isOn: opdsBinding)
                    .help("Exposes the catalog to third-party readers (Thorium, KOReader, Calibre) on the same port")
                if settings.shareOPDSOverNetwork {
                    if let sharing = librarySession?.sharing {
                        if sharing.isServingOPDS {
                            LabeledContent("Feed URL", value: sharing.opdsAddressString)
                            Button("Copy Feed URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sharing.opdsAddressString, forType: .string)
                            }
                            Text("Other devices on this network enter this URL in their reader app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let error = sharing.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sharing")
    }

    /// The sync toggle and the OPDS toggle both reconcile the single shared
    /// server: flipping either one (or the other off) restarts it with the
    /// matching surface enabled.
    private var shareBinding: Binding<Bool> {
        Binding(
            get: { settings.shareLibraryOverNetwork },
            set: { newValue in
                settings.shareLibraryOverNetwork = newValue
                guard let session = librarySession else { return }
                Task { @MainActor in
                    if !(await session.reconcileSharing()) {
                        settings.shareLibraryOverNetwork = false
                        session.lastError = "Open a library before sharing it."
                    }
                }
            }
        )
    }

    /// Independent of the sync share: the OPDS catalog can be exposed to
    /// readers with the sync API off (and vice versa).
    private var opdsBinding: Binding<Bool> {
        Binding(
            get: { settings.shareOPDSOverNetwork },
            set: { newValue in
                settings.shareOPDSOverNetwork = newValue
                guard let session = librarySession else { return }
                Task { @MainActor in
                    if !(await session.reconcileSharing()) {
                        settings.shareOPDSOverNetwork = false
                        session.lastError = "Open a library before sharing it."
                    }
                }
            }
        )
    }

    /// The password field writes through to the Keychain, never UserDefaults.
    private var passwordBinding: Binding<String> {
        Binding(
            get: { ShareCredentials.load() ?? "" },
            set: {
                if $0.isEmpty {
                    ShareCredentials.delete()
                } else {
                    ShareCredentials.save(password: $0)
                }
            }
        )
    }

    /// Home-library designation: which library is the primary workspace, how
    /// to change it, and how to create a new one. Peer management stays in
    /// the sidebar — this pane is home-only.
    private var libraryTab: some View {
        Form {
            Section("Home Library") {
                LabeledContent("Library", value: librarySession?.home?.name ?? "None")
                if let root = librarySession?.home?.coreRepository.root {
                    LabeledContent("Location", value: root.path)
                }
                Button("Change Home Library…") {
                    librarySession?.present(.changeHome)
                }
                .disabled(librarySession == nil)
                Button("Create New Library…") {
                    librarySession?.createNewLibrary()
                }
                .disabled(librarySession == nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library")
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(
                    "Automatically fetch missing metadata on import",
                    isOn: $settings.automaticallyFetchMissingMetadata
                )
                Text("When an imported book is missing authors or tags, Stacks "
                    + "looks it up online and fills in the gaps (high-confidence matches "
                    + "apply silently; ambiguous ones are offered for review).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
