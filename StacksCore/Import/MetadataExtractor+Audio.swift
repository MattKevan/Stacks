import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

extension MetadataExtractor {
    /// Extracts metadata from an audiobook file. macOS reads ID3/MP4 tags via
    /// AVFoundation (title; artist/author → authors; genre → tags; comments;
    /// embedded artwork via `extractAudioCover`). Linux has no AVFoundation,
    /// so it degrades to the same filename-title rule as DJVU.
    ///
    /// Note: `AVAsset.commonMetadata` is deprecated in favor of the async
    /// `load(.commonMetadata)` API; the synchronous read is used deliberately
    /// so the whole import pipeline stays synchronous (threading async
    /// through `MetadataExtractor`, `ImportService`, and the CLI is a larger
    /// change for no v1 benefit).
    static func extractAudio(from url: URL) -> ExtractedMetadata {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata
        let title = stringValue(items, key: .commonKeyTitle)
            ?? url.deletingPathExtension().lastPathComponent
        let author = stringValue(items, key: .commonKeyArtist)
            ?? stringValue(items, key: .commonKeyAuthor)
        let genre = stringValue(items, key: .commonKeySubject)
        let comments = stringValue(items, key: .commonKeyDescription)
        return ExtractedMetadata(
            title: title,
            authors: author.map { [$0] } ?? [],
            tags: genre.map { [$0] } ?? [],
            comments: comments
        )
        #else
        return extractFromFilename(url)
        #endif
    }

    #if canImport(AVFoundation)
    /// The embedded artwork of an audio file (ID3 APIC / MP4 covr). Re-encoded
    /// to JPEG when ImageIO is available (the same path EPUB covers take); nil
    /// when the file carries no artwork or it cannot be read.
    static func extractAudioCover(from url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        guard let item = AVMetadataItem.metadataItems(
            from: asset.commonMetadata,
            filteredByIdentifier: .commonIdentifierArtwork
        ).first, let data = item.value as? Data else {
            return nil
        }
        #if canImport(ImageIO)
        return normalizeToJPEG(data) ?? data
        #else
        return data
        #endif
    }

    private static func stringValue(_ items: [AVMetadataItem], key: AVMetadataKey) -> String? {
        items.first { $0.commonKey == key }?.value as? String
    }
    #endif
}
