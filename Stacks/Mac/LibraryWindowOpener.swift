import AppKit
import SwiftUI

/// Opens the library window once at launch.
///
/// A `Window` scene (as opposed to `WindowGroup`) does not present itself when
/// the app starts — it exists only once something asks for it. Launching from
/// the Dock or Finder into a windowless app is a dead end, so the window is
/// opened explicitly.
///
/// The trigger has to be the app delegate, not a view: the library window
/// doesn't exist yet (so a view inside it never appears), and the menu bar
/// extra's content only appears when the menu is *opened* — its `onAppear`
/// fires on the first click, far too late for a launch. `applicationDidFinishLaunching`
/// is the only hook that reliably runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `StacksApp` so the delegate can reach the scene's `openWindow`.
    /// `openWindow` is only available from the SwiftUI environment, so the
    /// window is opened by a tiny helper view published through this closure,
    /// captured from the menu bar extra's environment.
    static var openLibraryWindow: (() -> Void)?

    /// True while the app should quit once its last window closes — only when
    /// there is no menu bar extra to keep it alive. The extra is always
    /// present, so this stays false; kept for clarity.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Track window visibility so the activation policy can follow it: a
        // visible window means the app must be `.regular` to own the menu bar
        // (see `AppLifecycle.applyActivationPolicy`).
        // `NSWindowDidBecomeVisibleNotification` does not exist; these are the
        // window-lifecycle signals that exist and cover the transitions that
        // matter (a window becoming main/key, or closing/minimising away).
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged),
                name: name, object: nil
            )
        }

        // The scene tree isn't built at `didFinishLaunching`; defer one runloop
        // turn so the opener closure has been published.
        DispatchQueue.main.async {
            AppDelegate.openLibraryWindow?()
            AppLifecycle.activate()
            // The window now exists: promote out of accessory so the app owns
            // the menu bar instead of leaving Finder's in place.
            AppLifecycle.refreshActivationPolicy(hideDockIcon: AppSettings.hideDockIcon())
        }
    }

    /// Re-evaluates the activation policy when a window appears or closes.
    /// Deferred a turn, because the notification fires before the window's
    /// visibility flag settles (and `willClose` before it actually closes).
    @objc private func windowVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            AppLifecycle.refreshActivationPolicy(hideDockIcon: AppSettings.hideDockIcon())
        }
    }

    /// Clicking the Dock icon (or otherwise re-activating) while a window is
    /// open must not leave the app in accessory mode with another app's menu
    /// bar showing.
    func applicationDidBecomeActive(_ notification: Notification) {
        if AppLifecycle.hasVisibleLibraryWindow {
            AppLifecycle.applyActivationPolicy(hideDockIcon: AppSettings.hideDockIcon())
        }
    }
}

/// Publishes a closure that opens the given window, so the app delegate can
/// trigger it at launch. `openWindow` comes from the SwiftUI environment, which
/// only exists inside a view — hence a view that does nothing but capture it.
private struct LibraryWindowPublishOpener: ViewModifier {
    let windowID: String

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AppDelegate.openLibraryWindow = { openWindow(id: windowID) }
        }
    }
}

extension View {
    /// Publishes a closure that opens the given window, for `AppDelegate`.
    func publishingLibraryWindowOpener(id: String) -> some View {
        modifier(LibraryWindowPublishOpener(windowID: id))
    }
}
