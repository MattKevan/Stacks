import StacksCore
import Foundation

/// Posts completion feedback as standard macOS system notifications.
/// Authorization is requested lazily on first use; every post returns false
/// when notifications are not authorized so callers can fall back to their
/// existing report sheet. The UNUserNotificationCenter machinery lives in
/// `CompletionNotifier` (StacksCore) so the same feedback path can run on
/// Linux via notify-send.
enum SystemNotifier {
    /// Posts a notification; returns false when authorization is missing or
    /// posting failed (caller falls back to a sheet).
    @discardableResult
    static func post(title: String, body: String) async -> Bool {
        await CompletionNotifier.post(title: title, body: body)
    }

    /// "Import complete" summary with the failed items listed (truncated).
    static func postImportCompletion(report: ImportReport) async -> Bool {
        var body = report.summary
        let failed = report.failed
        if !failed.isEmpty {
            let names = failed.prefix(4).map { $0.sourceURL.lastPathComponent }
            body += " — failed: " + truncated(names, extra: failed.count - names.count)
        }
        return await post(title: "Import complete", body: body)
    }

    /// "Sent to device" summary with the unsent items listed (truncated).
    static func postSendCompletion(report: SendReport) async -> Bool {
        var body = report.summary
        let issues = report.noCompatible + report.failed
        if !issues.isEmpty {
            let names = issues.prefix(4).map(\.title)
            body += " — not sent: " + truncated(names, extra: issues.count - names.count)
        }
        return await post(title: "Sent to device", body: body)
    }

    private static func truncated(_ names: [String], extra: Int) -> String {
        var joined = names.joined(separator: ", ")
        if extra > 0 {
            joined += "… and \(extra) more"
        }
        return joined
    }
}
