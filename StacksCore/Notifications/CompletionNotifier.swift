#if canImport(UserNotifications)
import UserNotifications
#endif
import Foundation

/// Posts completion feedback as system notifications on every platform the
/// core builds for. macOS posts through `UNUserNotificationCenter` (with the
/// foreground-banner delegate), Linux shells out to `notify-send` (libnotify).
/// Every post returns false when the notification could not be delivered so
/// callers can fall back to their existing report sheet.
public enum CompletionNotifier {
#if canImport(UserNotifications)
    /// Presents banners while the app is frontmost (macOS suppresses foreground
    /// notifications by default). Retained for the process by `shared`; assigned
    /// to the notification center before every post (idempotent).
    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = NotificationDelegate()

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }

    /// Resolves notification authorization; true when notifications can be
    /// posted (authorized / provisional / ephemeral). Idempotent after the
    /// first call; never throws.
    private static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Posts a notification; returns false when authorization is missing or
    /// posting failed (caller falls back to a sheet).
    public static func post(title: String, body: String) async -> Bool {
        await post(title: title, body: body, using: postViaUserNotifications)
    }

    /// Runs the real macOS pipeline. Kept separate from `post` so tests can
    /// inject a poster: the pipeline requires an app bundle —
    /// `UNUserNotificationCenter.current()` raises an
    /// NSInternalInconsistencyException ("bundleProxyForCurrentProcess is
    /// nil") for processes whose main bundle is not an app, e.g. the headless
    /// `stacks` server or SwiftPM/xctest test runners — so such processes
    /// report false and callers fall back to their sheet. The Stacks app is
    /// always a .app bundle, so its behavior is unaffected.
    static func post(title: String, body: String, using poster: @Sendable (String, String) async -> Bool) async -> Bool {
        await poster(title, body)
    }

    private static func postViaUserNotifications(title: String, body: String) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        guard await requestAuthorizationIfNeeded() else { return false }
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
#else
    /// Posts a notification via `notify-send`; returns false when the tool is
    /// missing or exits non-zero (caller falls back to a sheet).
    public static func post(title: String, body: String) async -> Bool {
        postNotifySend(title: title, body: body)
    }

    /// Runs `/usr/bin/notify-send` (libnotify) with the notification text;
    /// true when it exits 0. Kept separate from `post` so the Process
    /// invocation is a testable unit (Linux-only — guarded out on macOS).
    static func postNotifySend(title: String, body: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/notify-send")
        process.arguments = ["-a", "Stacks", title, body]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
#endif
}
