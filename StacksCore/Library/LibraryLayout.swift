import Foundation

public struct LibraryLayout: Sendable {
    public let root: URL

    /// The name of the directory that holds the journal, manifest, and staging
    /// areas inside a library.
    static let controlDirectoryName = ".stacks"
    /// The pre-rename control directory. Kept only so
    /// `migrateControlDirectoryIfNeeded` can find libraries created before the
    /// rename.
    private static let legacyControlDirectoryName = ".bookmanager"

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// One-time migration: the control directory was named `.bookmanager`;
    /// rename it to `.stacks` so libraries created before the rename keep
    /// opening. Idempotent — a no-op once `.stacks` exists (or when there's
    /// nothing to migrate). Throws rather than failing silently, so a library
    /// is never mistaken for an empty folder.
    public static func migrateControlDirectoryIfNeeded(root: URL) throws {
        let fileManager = FileManager.default
        let root = root.standardizedFileURL
        let legacy = root.appending(path: legacyControlDirectoryName, directoryHint: .isDirectory)
        let current = root.appending(path: controlDirectoryName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else { return }
        try fileManager.moveItem(at: legacy, to: current)
    }

    public var controlRoot: URL { root.appending(path: Self.controlDirectoryName, directoryHint: .isDirectory) }
    public var manifestURL: URL { controlRoot.appending(path: "library.json") }
    public var changesRoot: URL { controlRoot.appending(path: "changes", directoryHint: .isDirectory) }
    public var bookChangesRoot: URL { changesRoot.appending(path: "books", directoryHint: .isDirectory) }
    public var libraryChangesRoot: URL { changesRoot.appending(path: "library", directoryHint: .isDirectory) }
    /// The append-only operation journal — the authoritative library state
    /// (replaces the Automerge change store).
    public var journalRoot: URL { changesRoot.appending(path: "journal", directoryHint: .isDirectory) }
    /// Periodic full-state snapshot for fast rebuilds (atomic writes).
    public var snapshotURL: URL { changesRoot.appending(path: "snapshot.json") }
    /// Per-import staging area; journal commands use `<commandID>/`
    /// subdirectories so their staged files are self-contained.
    public var stagingRoot: URL { controlRoot.appending(path: "staging", directoryHint: .isDirectory) }
    public var transactionsRoot: URL { controlRoot.appending(path: "transactions", directoryHint: .isDirectory) }
    public var trashRoot: URL { controlRoot.appending(path: "trash", directoryHint: .isDirectory) }
    public var recoveryRoot: URL { controlRoot.appending(path: "recovery", directoryHint: .isDirectory) }
    public var quarantineRoot: URL { controlRoot.appending(path: "quarantine", directoryHint: .isDirectory) }

    public func create(manifest: LibraryManifest) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [
            bookChangesRoot,
            libraryChangesRoot,
            transactionsRoot,
            trashRoot,
            recoveryRoot,
            quarantineRoot
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.stacks.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> LibraryManifest {
        try JSONDecoder.stacks.decode(
            LibraryManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }
}

extension JSONEncoder {
    public static var stacks: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var stacks: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
