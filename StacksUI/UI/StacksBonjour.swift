import Foundation

/// The Bonjour service type every Stacks peer uses, in the form the client and
/// the `NSBonjourServices` plist entry both expect (no trailing dot).
///
/// This mirrors `StacksBonjour` in `StacksServerKit`. It is duplicated here
/// because the iOS client deliberately does not link the server module (it
/// would pull in Hummingbird); `BonjourPlistTests` asserts the plists agree
/// with the advertised value so the two copies cannot drift unnoticed.
public enum StacksBonjourClient {
    public static let serviceType = "_stacks._tcp"
}
