import Testing
@testable import StacksCore

/// The real macOS pipeline cannot run in a test process: it needs an app
/// bundle (`UNUserNotificationCenter.current()` hard-crashes — an
/// NSInternalInconsistencyException, "bundleProxyForCurrentProcess is nil" —
/// in both the SwiftPM and xctest runners) and granted notification
/// authorization. What is testable without either is the post seam: `post`
/// forwards title/body to the poster it is given and reports the poster's
/// Bool verdict. That is the contract callers (SystemNotifier) depend on;
/// actual banner delivery is exercised manually in the app. The Linux
/// branch's `postNotifySend` seam is likewise exercised (guarded, Linux
/// only, where it also needs `/usr/bin/notify-send` plus a libnotify daemon —
/// so its assertion is equally weak: it completes and reports a Bool).
@Suite
struct CompletionNotifierTests {
    @Test
    func postForwardsToPosterAndReportsVerdict() async {
        let result = await CompletionNotifier.post(title: "Stacks test", body: "Test notification") { title, body in
            #expect(title == "Stacks test")
            #expect(body == "Test notification")
            return false
        }
        #expect(result == false)
    }

#if !canImport(UserNotifications)
    @Test
    func postNotifySendCompletesAndReportsBool() {
        let result = CompletionNotifier.postNotifySend(title: "Stacks test", body: "Test notification")
        #expect(result is Bool)
    }
#endif
}
