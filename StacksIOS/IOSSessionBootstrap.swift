import Foundation
import StacksKit

extension LibrarySession {
    /// Opens the app's container library, creating it on first launch.
    ///
    /// Unlike macOS — where a library is a folder the user picks through a
    /// save panel and holds a security-scoped bookmark to — iOS always has a
    /// writable library in Application Support, so there is nothing to choose
    /// and nothing to bookmark.
    func openContainerLibrary() async {
        guard home == nil else { return }
        let root = URL.applicationSupportDirectory
            .appending(path: "Stacks", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        if contents.isEmpty {
            await createLibrary(at: root)
        } else {
            await openLibrary(at: root, fallbackToWelcome: false)
        }
    }
}
