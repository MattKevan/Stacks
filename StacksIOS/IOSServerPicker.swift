import StacksKit
import StacksSync
import SwiftUI

/// Chooses which connected server a book is sent to.
///
/// Presented as a sheet because a picker is only needed when there is more
/// than one server; with exactly one, the caller sends straight to it. If
/// nothing is connected, the sheet offers the connection dialogs instead of an
/// empty list — a dead end otherwise.
struct IOSServerPicker: View {
    let session: LibrarySession
    /// The book being sent (shown for context).
    let book: IndexedBook
    let onSend: (RemoteLibraryBrowser) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            Group {
                if session.remotes.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers Connected", systemImage: "network.slash")
                    } description: {
                        Text("Connect to a Stacks server to send books to it.")
                    } actions: {
                        Button("Connect to Server…") { isConnecting = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(session.remotes) { remote in
                        Button {
                            onSend(remote)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(remote.name)
                                    if !remote.isConnected {
                                        Text("Disconnected — sends will queue")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: "paperplane")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Send “\(book.title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !session.remotes.isEmpty {
                    Button {
                        isConnecting = true
                    } label: {
                        Label("Connect to Another Server…", systemImage: "plus.circle")
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .sheet(isPresented: $isConnecting) {
                ConnectToServerView(session: session)
            }
        }
    }
}
