import Foundation

/// What the bundle has to declare for pairing to work, and how to check it.
///
/// Pairing ends with the Portal redirecting to `<scheme>://connect?…`. Nothing
/// in the app can make that URL come back: Launch Services routes it, and
/// Launch Services only knows about schemes an app's `Info.plist` claims in
/// `CFBundleURLTypes`. Get that wrong and everything else still compiles, the
/// sheet still opens, the person still signs in — and then nothing happens.
///
/// The block itself is written by `scripts/url-types.mjs`, because the app's
/// build script is a shell script writing a plist by hand, not a Swift
/// program. What lives here is the other half: reading a built bundle back and
/// saying whether the scheme is really registered, which is what the kit's own
/// test and an app's build check assert against.
public enum ShellPlist {
    /// Every URL scheme a plist claims, lower-cased the way Launch Services
    /// compares them.
    public static func urlSchemes(inPlist data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() } })
    }

    public static func urlSchemes(inPlistAt url: URL) -> Set<String> {
        (try? Data(contentsOf: url)).map { urlSchemes(inPlist: $0) } ?? []
    }

    /// Whether a built bundle will actually receive this app's connect links.
    public static func declares(scheme: String, inPlist data: Data) -> Bool {
        urlSchemes(inPlist: data).contains(scheme.lowercased())
    }

    /// The bundle the app is running from, for a launch-time check. Nil when
    /// the app runs unbundled (`swift run`), where Launch Services is not in
    /// the picture at all and the question does not arise.
    public static func runningBundleDeclaresConnectScheme() -> Bool? {
        guard let scheme = ShellConfig.current.connectScheme,
              let plist = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let data = try? Data(contentsOf: plist) else { return nil }
        return declares(scheme: scheme, inPlist: data)
    }
}
