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
import QuickLook
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformFont = UIFont

/// Retained for the lifetime of a QuickLook presentation: `QLPreviewController`
/// holds its data source weakly, so an unowned one would deallocate before the
/// sheet renders.
final class FilePreviewDataSource: NSObject, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> any QLPreviewItem {
        url as NSURL
    }
}
#endif

/// The thin platform layer under the shared UI.
///
/// Everything the shared views and stores cannot express portably funnels
/// through here: opening and revealing files, the modifier keys that drive grid
/// selection, and the file panels. macOS supplies AppKit behaviour; iOS
/// supplies UIKit behaviour, and a no-op where the concept does not exist
/// (there is no "reveal in Finder" on iOS).
public enum PlatformServices {
    #if canImport(UIKit)
    /// Strong reference to the in-flight QuickLook data source (the controller
    /// holds it weakly). Main-actor isolated because presentation is.
    @MainActor
    private static var previewDataSource: FilePreviewDataSource?
    #endif

    /// Opens a file. macOS hands it to the default app; iOS cannot hand an
    /// arbitrary local library file to another app, so it presents QuickLook
    /// over the active window instead.
    @MainActor
    public static func openExternally(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        guard let root = activeRootViewController() else { return }
        let source = FilePreviewDataSource(url: url)
        previewDataSource = source
        let preview = QLPreviewController()
        preview.dataSource = source
        // Present from whatever is already on top (a context-menu sheet, a
        // detail pane) so the preview isn't stranded behind it.
        if let presented = root.presentedViewController {
            presented.present(preview, animated: true)
        } else {
            root.present(preview, animated: true)
        }
        #endif
    }

    #if canImport(UIKit)
    private static func activeRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?
            .rootViewController
    }
    #endif

    /// Whether `reveal` does anything. Views hide affordances like "Show in
    /// Finder" where it doesn't (iOS).
    public static var supportsReveal: Bool {
        #if canImport(AppKit)
        true
        #else
        false
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

public extension View {
    /// Grid keyboard navigation (arrows / Return / Delete). `onKeyPress` is a
    /// macOS/iPadOS API, so on iOS this compiles to the view unchanged — the
    /// touch UI has no arrow keys to handle.
    @ViewBuilder
    func gridKeyboardNavigation(
        columns: @escaping () -> Int,
        moveFocus: @escaping (Int) -> Void,
        openFocused: @escaping () -> Void,
        trashFocused: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        self
            .onKeyPress(.leftArrow) { moveFocus(-1); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(1); return .handled }
            .onKeyPress(.upArrow) { moveFocus(-columns()); return .handled }
            .onKeyPress(.downArrow) { moveFocus(columns()); return .handled }
            .onKeyPress(.return) { openFocused(); return .handled }
            .onKeyPress(.delete) { trashFocused(); return .handled }
        #else
        self
        #endif
    }
}

public extension View {
    /// Fixed sheet width where sheets have a width (macOS); a no-op inside an
    /// iOS sheet, which sizes itself to the device.
    @ViewBuilder
    func platformSheetWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        self
        #endif
    }

    /// Return/Escape key equivalents. macOS only — iOS sheets use the keyboard
    /// accessory the system provides.
    @ViewBuilder
    func defaultActionShortcut() -> some View {
        #if os(macOS)
        self.keyboardShortcut(.defaultAction)
        #else
        self
        #endif
    }

    @ViewBuilder
    func cancelActionShortcut() -> some View {
        #if os(macOS)
        self.keyboardShortcut(.cancelAction)
        #else
        self
        #endif
    }

    /// Grid-tile tap behaviour. macOS follows Finder (double-click opens,
    /// single click selects); touch platforms open on a single tap — the
    /// discoverable idiom there. Selection stays available on iOS through the
    /// tile's context menu, which selects before acting.
    @ViewBuilder
    func gridTileTaps(
        onOpen: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        self
            .onTapGesture(count: 2) { onOpen() }
            .onTapGesture { onSelect() }
        #else
        self
            .onTapGesture { onOpen() }
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
