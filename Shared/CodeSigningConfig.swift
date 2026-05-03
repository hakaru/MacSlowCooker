import Foundation

/// Code-signing configuration shared between the app and the helper.
///
/// `teamOU` is the Apple Developer Team ID (a 10-character string like
/// `K38MBRNKAT`). The helper validates incoming XPC connections by building a
/// designated requirement string that pins the connecting binary to this Team
/// ID. The same value must appear in three other places that cannot read this
/// constant directly:
///
///   - `project.yml` → `DEVELOPMENT_TEAM`
///   - `HelperTool/Info.plist` → `SMAuthorizedClients` requirement string
///   - the certificate the build uses for code signing
///
/// When forking, run `bin/set-team-id.sh <YOUR_TEAM_ID>` to update all four
/// places in lockstep. The script is the source of truth for what needs to
/// change; this constant is just where the runtime requirement string is
/// constructed from.
enum CodeSigningConfig {
    static let teamOU = "K38MBRNKAT"

    static let appBundleID = "com.macslowcooker.app"

    /// The full designated-requirement string used by `setCodeSigningRequirement`
    /// on incoming XPC connections.
    static var xpcClientRequirement: String {
        "identifier \"\(appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamOU)\""
    }
}
