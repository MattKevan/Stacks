import Testing
@testable import StacksKit
@testable import StacksSync
@testable import StacksServerKit

@Test
func exposesLibraryFormatVersion() {
    #expect(StacksCoreVersion.libraryFormat == 1)
}
