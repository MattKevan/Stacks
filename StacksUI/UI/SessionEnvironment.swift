import SwiftUI

/// The session, injected into the environment by each app shell so shared
/// views (Diagnostics) can reach it without an explicit parameter.
private struct LibrarySessionKey: EnvironmentKey {
    static let defaultValue: LibrarySession? = nil
}

extension EnvironmentValues {
    var librarySession: LibrarySession? {
        get { self[LibrarySessionKey.self] }
        set { self[LibrarySessionKey.self] = newValue }
    }
}
