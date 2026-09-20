import Foundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit

/// The image type the shared UI passes around: `NSImage` on macOS, `UIImage`
/// on iOS. Both have `init?(data:)` and a `size`, which is all the shared code
/// needs.
public typealias PlatformImage = NSImage
/// The font type for the few places that need one (HTML metadata style).
public typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformFont = UIFont
#endif

/// The thin platform layer under the shared UI.
///
/// Everything the shared views and stores cannot express portably funnels
/// through here: opening and revealing files, the modifier keys that drive grid
/// selection, and the file panels. macOS supplies AppKit behaviour; iOS
/// supplies UIKit behaviour, and a no-op where the concept does not exist
/// (there is no "reveal in Finder" on iOS).
public enum PlatformServices {
    /// Opens a file in the user's default external application.
    @MainActor
    public static func openExternally(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Reveals a file in the platform file manager. macOS: Finder. iOS has no
    /// equivalent, so this is a no-op there.
    @MainActor
    public static func reveal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Whether the Command modifier is held (drives grid multi-select). iOS
    /// reports false; hardware-keyboard tracking is a Phase 4 item.
    @MainActor
    public static var isCommandDown: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    /// Whether the Shift modifier is held (anchor→click range selection).
    @MainActor
    public static var isShiftDown: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    /// Presents a single-image chooser and returns the chosen file's bytes
    /// (nil when cancelled). iOS returns nil until the Phase 4 photo/file
    /// picker lands.
    @MainActor
    public static func chooseImageFileData() async -> Data? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose a Cover Image"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
        #else
        return nil
        #endif
    }
}

public extension Image {
    /// `Image(nsImage:)` / `Image(uiImage:)` behind one name.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

public extension PlatformImage {
    /// Wraps a decoded `CGImage` — the cover pipeline's output.
    static func decoding(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        PlatformImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        PlatformImage(cgImage: cgImage)
        #endif
    }

    /// Decoded pixel bytes, for `NSCache` cost accounting.
    var decodedByteCost: Int {
        Int(size.width * size.height * 4)
    }
}

extension QLThumbnailRepresentation {
    /// The QuickLook image as the platform image type.
    var platformImage: PlatformImage? {
        #if canImport(AppKit)
        nsImage
        #else
        uiImage
        #endif
    }
}
