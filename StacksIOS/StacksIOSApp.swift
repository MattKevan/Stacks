import StacksKit
import SwiftUI

@main
struct StacksIOSApp: App {
    @State private var session = LibrarySession()

    var body: some Scene {
        WindowGroup {
            IOSRootView(session: session)
                .environment(\.librarySession, session)
                .task {
                    // iOS owns its library in the app container: create it on
                    // first launch, reopen it afterwards. No file panels, no
                    // security-scoped bookmarks.
                    await session.openContainerLibrary()
                }
        }
    }
}
