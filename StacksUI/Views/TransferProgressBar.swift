import SwiftUI

/// A compact, always-visible progress strip for long transfers.
///
/// The Mac keeps its richer Safari-Downloads popover in the toolbar; this is
/// the shared, chrome-agnostic form that iOS presents above its content
/// (there is no toolbar popover idiom there, and a modal spinner hides the
/// library while a batch runs).
///
/// Reads the session's two activity sources — a local import, or a
/// server transfer (download/upload) — so any long operation surfaces without
/// the caller wiring anything up.
struct TransferProgressBar: View {
    let session: LibrarySession

    var body: some View {
        if let activity = session.importActivity {
            row(
                title: activity.title,
                current: activity.currentTitle,
                completed: activity.completed,
                total: activity.total,
                symbol: "square.and.arrow.down"
            )
        } else if let activity = session.serverTransferActivity {
            row(
                title: activity.title,
                current: activity.currentTitle,
                completed: activity.completed,
                total: activity.total,
                symbol: activity.headlineSymbol
            )
        }
    }

    private func row(
        title: String,
        current: String?,
        completed: Int,
        total: Int,
        symbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(completed) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if total > 1 {
                ProgressView(value: Double(completed), total: Double(total))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if let current, !current.isEmpty {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
