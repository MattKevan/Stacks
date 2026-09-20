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

    /// Raises the library window and makes it key.
    ///
    /// `openWindow(id:)` re-creates a closed window but does *not* lift one
    /// that is already open — it stays buried. The window therefore has to be
    /// ordered front explicitly.
    ///
    /// It cannot be found by title: the `Window` scene is retitled with the
    /// open library's name ("Test1 — Formats"), so a title match misses. The
    /// reliable discriminator is the window that is neither a panel (the menu
    /// bar extra, alerts) nor the Settings window, so it is chosen by exclusion
    /// among windows that can become main.
    ///
    /// Runs after a turn of the runloop: a window created by `openWindow` in
    /// the same call isn't in `NSApp.windows` until the scene is realized.
    static func focusLibraryWindow() {
        activate()
        DispatchQueue.main.async {
            guard let window = libraryWindow() else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The app's library window: a main-capable window that is not a panel
    /// (extras, alerts) and not the Settings window.
    private static func libraryWindow() -> NSWindow? {
        let candidates = NSApplication.shared.windows.filter {
            $0.canBecomeMain && !($0 is NSPanel)
        }
        // Prefer one that isn't the settings window. `showSettingsWindow:` has
        // no class to test, so fall back to the scene's identifier when
        // present, else the last candidate (frontmost-ish).
        let nonSettings = candidates.filter { window in
            let identifier = window.identifier?.rawValue ?? ""
            return !identifier.localizedCaseInsensitiveContains("settings")
        }
        return nonSettings.last ?? candidates.last
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
    /// Mirrors `SMAppService`'s status. `.requiresApproval` is the state where
    /// registration succeeded but the user must allow it in System Settings —
    /// distinct from "on", and the most common cause of "I enabled it and
    /// nothing happened".
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        /// Registration is impossible from here (build product, unsigned, or a
        /// bundle that can move). `reason` explains why.
        case unavailable(String)

        var isOn: Bool { self == .enabled }
    }

    private(set) var state: State = .disabled

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    /// Re-reads the system state. The app is not notified when the login item
    /// changes in System Settings, so this is called when the menu is shown.
    func refresh() {
        switch service.status {
        case .enabled: state = .enabled
        case .requiresApproval: state = .requiresApproval
        case .notRegistered: state = .disabled
        case .notFound:
            state = .unavailable(
                "Move Stacks to your Applications folder to enable this."
            )
        @unknown default:
            state = .disabled
        }
    }

    /// Registers or unregisters the login item.
    ///
    /// Never leaves the control in a dead state: a failure is reported, and the
    /// control stays clickable so the user can retry after fixing the cause
    /// (moving the app, approving it in System Settings). Latching it disabled
    /// on the first failure — as this did — meant one failed attempt disabled
    /// it permanently.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch let failure {
            let description = failure.localizedDescription
            state = .unavailable(description)
            return
        }
        refresh()
        // register() can succeed while awaiting approval; make that visible
        // rather than silently showing "off".
        if state == .disabled, enabled {
            state = .requiresApproval
        }
    }

    /// Opens System Settings → General → Login Items, where a
    /// `.requiresApproval` item is waiting to be allowed.
    func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
