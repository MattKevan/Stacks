import Foundation

/// The audiobook format set — the single source for what counts as an
/// audiobook across import, device scanning, and browser filtering. Keeping
/// the set here (instead of repeating it in `MetadataExtractor`,
/// `DeviceBookScanner`, and the browse models) means one change covers every
/// surface.
public enum AudioFormats {
    /// Lowercase file extensions treated as audiobooks.
    public static let extensions: Set<String> = ["mp3", "m4b", "m4a", "aac"]

    /// True when the format kind (stored uppercased, e.g. "M4B") is an
    /// audiobook.
    public static func isAudio(_ kind: String) -> Bool {
        extensions.contains(kind.lowercased())
    }
}
