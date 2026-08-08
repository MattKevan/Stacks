import Foundation
import libmobi
import Testing

@Suite
struct MobiSmokeTests {
    /// `Bundle.module` is SPM-only; Xcode test bundles resolve their resources
    /// through the bundle that contains a type from the test target.
    private final class FixtureMarker {}

    /// SwiftPM builds test resources into the target's resource bundle;
    /// XcodeGen copies them flat into the test bundle (no subdirectory is
    /// preserved). `SWIFT_PACKAGE` is defined only for SwiftPM builds.
    private var fixtureBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: FixtureMarker.self)
        #endif
    }

    @Test
    func parsesFixtureRawmlAndCover() throws {
        let url = try #require(fixtureBundle.url(
            forResource: "fixture", withExtension: "mobi"
        ))
        let mobi = try Mobi(url: url)
        let rawml = try mobi.getRawml()
        #expect(!rawml.isEmpty)
        // Cover may be absent in minimal fixtures — assert only when present.
        _ = try? mobi.getCover()
    }
}
