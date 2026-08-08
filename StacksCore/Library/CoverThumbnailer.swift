import CoreGraphics
import Foundation
import ImageIO

/// Downsampled cover decoding (WWDC 2018 "Image and Graphics Best
/// Practices"): the ImageIO thumbnail pipeline lives in `CoverDecoder` —
/// `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
/// decodes the image AT the target size instead of materializing a
/// full-resolution bitmap. Scrolling a large library then decodes only a small
/// thumbnail per visible cover — no gigabytes of full-res buffers, no
/// per-cell main-thread decode stall.
public enum CoverThumbnailer {
    /// Decodes a downsampled version of the image at `url`, with the longest
    /// side capped at `maxPixelSize` (aspect ratio preserved). Never decodes
    /// the full image; returns nil for a missing/unreadable file. Thread-safe
    /// (ImageIO) — safe to call from a background queue.
    public static func downsample(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        // The decode itself is CoverDecoder's ImageIO branch (the same
        // thumbnail options the URL-based path used, on the file's bytes),
        // which returns a small PNG; re-decode that into the CGImage.
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let pngData = CoverDecoder.decode(data: data, maxPixelSize: Int(maxPixelSize)) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
