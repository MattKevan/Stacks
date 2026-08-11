import AppKit
import StacksCore
import SwiftUI

/// Right-side inspector: cover + metadata for the single selected book, plus a
/// collapsible Calibre source-data section rendered from the raw payload.
struct BookInspectorView: View {
    @Bindable var session: LibrarySession
    @State private var coverImage: NSImage?

    private var book: IndexedBook? {
        guard let id = session.selection.first else { return nil }
        // The browser context (home or a connected remote) owns the
        // selection; its books list is the source.
        return session.browser?.books.first { $0.id == id }
    }

    /// Enrichment lookups are home-scoped (the network lookup + apply write
    /// through the home repository), so the Fetch button hides for remotes.
    private var isRemoteContext: Bool {
        session.browser is RemoteLibraryBrowser
    }

    private var rawRows: [CalibreRawRow] {
        book?.rawMetadata.map(CalibreRawPresenter.rows(from:)) ?? []
    }

    var body: some View {
        Group {
            if let book {
                contents(book)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
            }
        }
        // Keyed on the cover hash so a metadata edit that replaces the cover
        // restarts the load (book.id is stable across edits). The state
        // assignment happens AFTER the cancellation guard: a cancelled task
        // must never overwrite a newer selection's cover.
        .task(id: book?.coverHash) {
            guard let book else {
                coverImage = nil
                return
            }
            // Browser-routed: the thumbnail cache for home, a server fetch
            // for remotes.
            let image = await session.browser?.coverImage(for: book)
            guard !Task.isCancelled else { return }
            coverImage = image
        }
        .frame(minWidth: 280, idealWidth: 320)
    }

    private func contents(_ book: IndexedBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cover(book)
                // Grid with a fixed label column: labels right-aligned, values
                // left-aligned — so every value starts at the same x instead of
                // hugging its label's width.
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Title").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        Text(book.title).gridColumnAlignment(.leading)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Authors").foregroundStyle(.secondary)
                        Text(book.authors.joined(separator: ", "))
                    }
                    if let series = book.series {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Series").foregroundStyle(.secondary)
                            Text(book.seriesIndex.map { "\(series) #\($0)" } ?? series)
                        }
                    }
                    if let rating = book.rating {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Rating").foregroundStyle(.secondary)
                            Text(String(repeating: "★", count: rating))
                        }
                    }
                    if let publisher = book.publisher {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Publisher").foregroundStyle(.secondary)
                            Text(publisher)
                        }
                    }
                    if let date = book.publicationDate {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Published").foregroundStyle(.secondary)
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Added").foregroundStyle(.secondary)
                        Text((book.addedDate ?? .now).formatted(date: .abbreviated, time: .omitted))
                    }
                    if !book.languages.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Languages").foregroundStyle(.secondary)
                            Text(book.languages.joined(separator: ", "))
                        }
                    }
                    if !book.tags.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Tags").foregroundStyle(.secondary)
                            Text(book.tags.joined(separator: ", "))
                        }
                    }
                    if !book.identifiers.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Identifiers").foregroundStyle(.secondary)
                            Text(book.identifiers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                        }
                    }
                    if !book.formats.isEmpty {
                        GridRow(alignment: .firstTextBaseline) {
                            Text("Formats").foregroundStyle(.secondary)
                            Text(book.formats.map { "\($0.kind) (\(Self.byteString($0.size)))" }.joined(separator: ", "))
                        }
                    }
                }
                // The description is often HTML from the source metadata —
                // render it safely instead of showing raw tags.
                if let comments = book.comments, !comments.isEmpty {
                    metadataValue(comments)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                if !rawRows.isEmpty {
                    DisclosureGroup("Calibre Source Data") {
                        ForEach(rawRows) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }

                Button("Edit Metadata…") {
                    session.metadataEditQueue = [book]
                }
                .disabled(session.metadataEditQueue != nil)

                if !isRemoteContext {
                    Button("Fetch Metadata…") {
                        Task { await session.fetchMetadata(for: book.id) }
                    }
                    .disabled(session.isFetchingMetadata)
                }
                if let error = session.metadataLookupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    /// Renders a metadata value as attributed text when it contains HTML
    /// (Calibre/EPUB descriptions are often marked up) and as plain text
    /// otherwise. NSAttributedString's HTML import renders text and styles
    /// safely — no scripts or remote content execute.
    @ViewBuilder
    private func metadataValue(_ value: String) -> some View {
        if let attributed = Self.htmlAttributed(value) {
            Text(attributed)
        } else {
            Text(value)
        }
    }

    /// Converts HTML metadata to an AttributedString; nil when the value has
    /// no markup (so plain text renders verbatim, no interpretation).
    private static func htmlAttributed(_ value: String) -> AttributedString? {
        guard value.contains("<") || value.contains("&") else { return nil }
        guard let data = value.data(using: .utf8),
              let ns = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else { return nil }
        return AttributedString(ns)
    }

    @ViewBuilder
    private func cover(_ book: IndexedBook) -> some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        }
    }

    private static func byteString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
