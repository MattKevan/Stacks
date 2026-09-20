import StacksKit
import StacksSync
import SwiftUI

/// Host:port sheet for servers that can't advertise (Linux without Avahi,
/// other subnets, containers): type the address, optionally credentials, and
/// connect. The server's real name is adopted from `/api/identity`.
///
/// Shared by the macOS and iOS shells — the only platform differences are the
/// sheet width and the Return/Escape key equivalents.
struct ConnectToServerView: View {
    @Bindable var session: LibrarySession
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "18080"
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false

    private var portValue: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server")
                .font(.headline)
            Text("Enter the address of a Stacks server — e.g. a Linux box "
                + "that can't advertise over the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Host", text: $host)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)
            TextField("Username (optional)", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password (optional)", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .cancelActionShortcut()
                Button("Connect") {
                    connect()
                }
                .defaultActionShortcut()
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                    || portValue == nil || connecting)
            }
        }
        .padding(20)
        .platformSheetWidth(380)
    }

    private func connect() {
        guard let portValue else { return }
        connecting = true
        Task {
            await session.connectManual(
                host: host.trimmingCharacters(in: .whitespaces),
                port: portValue,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
            dismiss()
        }
    }
}

/// Username/password sheet shown when a discovered library demands basic
/// auth. Credentials go to the Keychain (per library) so reconnects are
/// prompt-free.
struct CredentialPromptView: View {
    let library: DiscoveredLibrary
    @Bindable var session: LibrarySession
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(library.name)
                .font(.headline)
            Text("This library requires a username and password.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .cancelActionShortcut()
                Button("Connect") {
                    connecting = true
                    let credential = RemoteLibrary.Credential(username: username, password: password)
                    RemoteCredentials.save(username: username, password: password, for: library.id)
                    Task {
                        await session.connect(to: library, credential: credential)
                        dismiss()
                    }
                }
                .defaultActionShortcut()
                .disabled(username.isEmpty || connecting)
            }
        }
        .padding(20)
        .platformSheetWidth(360)
    }
}
