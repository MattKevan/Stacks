import AppKit
import SwiftUI

/// The menu bar extra's menu contents.
///
/// The extra itself is always present (see `StacksApp`): when the app runs as
/// an accessory this is the only way to reach the window, the settings, and
/// Quit.
struct StacksMenuBarContent: View {
    let session: LibrarySession
    let settings: AppSettings
    let mac: MacFeatures
    let loginItem: LoginItem

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Library Window") {
            openLibraryWindow()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Divider()

        Toggle("Share Library", isOn: shareBinding)
            .disabled(session.home == nil)

        Divider()

        // SettingsLink is the documented way to open the Settings scene from
        // outside the app menu.
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        loginItemControl

        Toggle("Hide Dock Icon", isOn: dockIconBinding)

        Divider()

        Button("Quit Stacks") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        // The system state can change in System Settings behind the app's back,
        // so it is re-read each time the menu is shown.
        .task { loginItem.refresh() }
    }

    /// The login item, rendered according to its real state rather than a plain
    /// on/off toggle: a registered-but-unapproved item and an impossible one
    /// both need to look different from "off", or the user is left guessing.
    @ViewBuilder
    private var loginItemControl: some View {
        switch loginItem.state {
        case .unavailable(let reason):
            // Still clickable: the user may be able to fix the cause.
            Button {
                loginItem.setEnabled(true)
            } label: {
                Text("Open at Login Unavailable")
            }
            .help(reason)

        case .requiresApproval:
            Button {
                loginItem.openLoginItemsSettings()
            } label: {
                Text("Approve Open at Login…")
            }
            .help("Allow Stacks in System Settings → General → Login Items.")

        default:
            Toggle("Open at Login", isOn: loginBinding)
        }
    }

    /// Sharing is the app's own server for the open library. Toggling writes
    /// the same preference the Settings pane does and reconciles through the
    /// session, so the two controls can't disagree.
    private var shareBinding: Binding<Bool> {
        Binding(
            get: { settings.shareLibraryOverNetwork },
            set: { newValue in
                settings.shareLibraryOverNetwork = newValue
                Task {
                    if !(await session.reconcileSharing(mac.sharing)) {
                        // Requested sharing with no home library: revert so the
                        // menu reflects reality.
                        settings.shareLibraryOverNetwork = false
                    }
                }
            }
        )
    }

    private var dockIconBinding: Binding<Bool> {
        Binding(
            get: { settings.hideDockIcon },
            set: { newValue in
                settings.hideDockIcon = newValue
                AppLifecycle.applyActivationPolicy(hideDockIcon: newValue)
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.state.isOn },
            set: { loginItem.setEnabled($0) }
        )
    }

    /// Opens the library window, or brings it to the front if it is already
    /// open. `openWindow` handles the closed case; `focusLibraryWindow` lifts
    /// an existing window above whatever it is buried behind (and un-minimizes
    /// it) — necessary because there is no Dock icon to click in accessory
    /// mode, so the menu item is the only way back to the window.
    private func openLibraryWindow() {
        openWindow(id: StacksApp.libraryWindowID)
        AppLifecycle.focusLibraryWindow()
    }
}
