import AppKit
import UniformTypeIdentifiers
import StacksCore
import SwiftUI

/// Per-field Keep / Use-fetched review for a fetched metadata candidate. The
/// cover row shows both thumbnails; a field the candidate can't supply has no
/// picker (forced Keep). Pure view — no lookup, no writes; the parent applies
/// the choices.
struct MetadataMergeReviewSheet: View {
    let plan: MetadataMergePlan
    @Binding var choices: [MetadataMergeItem.Field: MetadataMergeChoice]
    let currentCover: NSImage?
    let fetchedCover: NSImage?
    /// Alternative covers from the source (Google Books sizes); the user can
    /// pick one or upload their own file.
    let coverURLs: [URL]
    let onChooseCover: (Data) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review fetched metadata")
                .font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(plan.items) { item in
                        if item.field == .cover {
                            coverRow(item)
                        } else {
                            fieldRow(item)
                        }
                    }
                }
            }
            HStack {
                Text("Use fetched only where you choose — nothing is written until Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Apply") { onConfirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func fieldRow(_ item: MetadataMergeItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.headline)
                    .frame(minWidth: 110, alignment: .leading)
                Text("Current: \(item.currentValue ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Fetched: \(item.fetchedValue ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.fetchedValue == nil {
                Text("Keep")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                choicePicker(item.field)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    private func coverRow(_ item: MetadataMergeItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.headline)
                HStack(spacing: 16) {
                    coverThumbnail(currentCover, caption: "Current")
                    coverThumbnail(fetchedCover, caption: "Fetched")
                }
                if !coverURLs.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(coverURLs.enumerated()), id: \.offset) { _, url in
                            CoverOptionThumbnail(url: url, onChoose: onChooseCover)
                        }
                        Button {
                            chooseCoverFile()
                        } label: {
                            Label("Choose File…", systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    .padding(.top, 6)
                }
            }
            Spacer()
            if item.fetchedValue == nil {
                Text("Keep")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                choicePicker(item.field)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }

    /// NSOpenPanel for the "Choose File…" cover upload: any image file.
    private func chooseCoverFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Cover Image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            onChooseCover(data)
        }
    }

    private func coverThumbnail(_ image: NSImage?, caption: String) -> some View {
        VStack(spacing: 2) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 90)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 60, height: 90)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func choicePicker(_ field: MetadataMergeItem.Field) -> some View {
        Picker("", selection: choiceBinding(field)) {
            Text("Keep").tag(MetadataMergeChoice.keep)
            Text("Use fetched").tag(MetadataMergeChoice.useFetched)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 170)
    }

    private func choiceBinding(_ field: MetadataMergeItem.Field) -> Binding<MetadataMergeChoice> {
        Binding(
            get: { choices[field] ?? .keep },
            set: { choices[field] = $0 }
        )
    }
}

/// A tappable alternative-cover thumbnail: loads the image from the source,
/// and tapping it hands the bytes to the caller (the pending cover).
private struct CoverOptionThumbnail: View {
    let url: URL
    let onChoose: (Data) -> Void
    @State private var image: NSImage?

    var body: some View {
        Button {
            Task {
                if let data = try? await Self.fetch(url) {
                    onChoose(data)
                }
            }
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 44, height: 64)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .task(id: url) {
            if let data = try? await Self.fetch(url), !Task.isCancelled {
                image = NSImage(data: data)
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let client = URLSessionMetadataHTTPClient()
        let request = URLRequest(url: url)
        return try await client.data(from: request)
    }
}
