import AppKit
import ServiceManagement
import SwiftUI

/// macOS app-lifecycle concerns the shared code cannot express: the activation
/// policy (Dock icon vs menu bar only) and the login item.
///
/// Both are macOS-only, so this lives in the shell rather than `StacksUI`.
@MainActor
enum AppLifecycle {
    /// Applies the persisted Dock-icon preference.
    ///
    /// `.accessory` hides the Dock icon and drops the app out of Cmd-Tab —
    /// the app keeps running and the menu bar extra stays reachable. Called at
    /// launch and whenever the preference changes.
    static func applyActivationPolicy(hideDockIcon: Bool) {
        NSApplication.shared.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    /// Brings the app forward. Needed before opening a window while running as
    /// an accessory, since there is no Dock icon to click: without this the
    /// window opens behind whatever is frontmost.
    static func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Raises the app's main library window and makes it key.
    ///
    /// Calling `openWindow(id:)` on a window that is already open does not
    /// reliably lift it above other windows — it can stay buried behind them.
    /// So after opening, the window is located and ordered to the front
    /// explicitly. Runs on the next runloop turn, because a freshly created
    /// window isn't in `NSApp.windows` until the scene has been realized.
    ///
    /// A window that is closed has to be re-created by the caller (`openWindow`);
    /// this only raises one that exists.
    static func focusLibraryWindow(titled title: String = "Stacks") {
        activate()
        DispatchQueue.main.async {
            let window = NSApplication.shared.windows.first { candidate in
                candidate.title == title && candidate.canBecomeMain
            } ?? NSApplication.shared.windows.first { $0.canBecomeMain }
            guard let window else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Shows the app's Settings window. The `Settings` scene has no programmatic
    /// opener in SwiftUI other than `SettingsLink`, which needs to live inside a
    /// view — the menu bar extra uses it directly; this is the fallback for code
    /// paths that aren't in a view.
    static func openSettings() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.sendAction(
                Selector(("showSettingsWindow:")), to: nil, from: nil
            )
        } else {
            NSApplication.shared.sendAction(
                Selector(("showPreferencesWindow:")), to: nil, from: nil
            )
        }
        activate()
    }
}

/// The "Open at Login" preference, backed by `SMAppService` rather than
/// UserDefaults: the system is the source of truth, and it can change behind
/// the app's back (System Settings → General → Login Items).
///
/// `SMAppService.mainApp` registers the app bundle itself, so it is only valid
/// for a real `.app` — it throws when run from a test host.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled: Bool
    /// Set when the last toggle failed (unsigned build, missing bundle, the
    /// user denied it in System Settings).
    private(set) var error: String?

    private let service = SMAppService.mainApp

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the system state — the app is not notified when the login item
    /// changes in System Settings, so the menu re-reads when it appears.
    func refresh() {
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            error = nil
        } catch let failure {
            error = failure.localizedDescription
        }
        refresh()
    }
}
