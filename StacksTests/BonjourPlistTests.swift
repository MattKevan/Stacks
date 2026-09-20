import Foundation
import Testing
@testable import StacksServerKit

/// `NSBonjourServices` is the one place the service type is written by hand:
/// the advertiser, the client browser, and the shared constant all come from
/// code, but the plists are literal. iOS refuses local-network access (and
/// hides the app from Settings > Local Network) when the declared list doesn't
/// match what the code uses, and it does so silently. These tests read the
/// plists and assert they agree.
///
/// Lives in the Xcode-only `StacksTests` target because the plists are only
/// present in this checkout, and because the constant they are checked against
/// is defined in `StacksUI`, which is compiled into the app target rather than
/// exposed as a module. That copy is therefore pinned here by its literal
/// value — `StacksUI/UI/StacksBonjour.swift` and this string must agree.
struct BonjourPlistTests {
    private static let clientServiceType = "_stacks._tcp"
    /// The repository root, derived from this file's location:
    /// …/StacksTests/<file>.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StacksTests
            .deletingLastPathComponent()   // repository root
    }

    private func bonjourServices(in plist: String) throws -> [String] {
        let data = try Data(contentsOf: repositoryRoot.appending(path: plist))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(object as? [String: Any])
        return try #require(dictionary["NSBonjourServices"] as? [String])
    }

    @Test
    func iOSAppDeclaresTheServiceTypeTheCodeBrowses() throws {
        let services = try bonjourServices(in: "Config/Stacks-iOS-Info.plist")
        #expect(services == [Self.clientServiceType])
    }

    @Test
    func macOSAppDeclaresTheServiceTypeTheCodeAdvertises() throws {
        let services = try bonjourServices(in: "Stacks/Info.plist")
        #expect(services == [Self.clientServiceType])
    }

    /// The advertiser (server module) and the browser (shared client) each
    /// declare the type. They must agree, or a client can see its own shares
    /// but not anyone else's.
    @Test
    func serverAndClientAgreeOnTheServiceType() {
        #expect(StacksBonjour.serviceType == Self.clientServiceType)
        #expect(StacksBonjour.serviceType == "_stacks._tcp")
    }

    /// `NetService` wants the type with a trailing dot; `NWBrowser` and the
    /// plist want it without.
    @Test
    func serviceTypeIsInTheBrowserAndPlistForm() {
        #expect(Self.clientServiceType.hasPrefix("_"))
        #expect(Self.clientServiceType.hasSuffix("._tcp"))
        #expect(!Self.clientServiceType.hasSuffix("."))
    }
}
