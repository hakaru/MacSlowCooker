import Foundation
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "com.macslowcooker", category: "app")

enum HelperInstallerError: LocalizedError {
    case requiresApproval
    case registrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "Please allow MacSlowCooker to run in System Settings → Login Items."
        case .registrationFailed(let e):
            return "Failed to install the helper tool: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class HelperInstaller {

    private static let plistName = "com.macslowcooker.helper.plist"

    /// The bundled helper's CFBundleVersion (kept in lockstep with the
    /// app's CFBundleVersion at build time). Read from the app bundle so
    /// version comparison does not require a separate constant to maintain.
    static var bundledVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static func installIfNeeded() async throws {
        let service = SMAppService.daemon(plistName: plistName)

        switch service.status {
        case .notRegistered:
            os_log("Registering daemon...", log: log, type: .info)
            try await register(service: service)

        case .enabled:
            os_log("Daemon enabled", log: log, type: .info)

        case .requiresApproval:
            os_log("Requires approval in System Settings", log: log, type: .error)
            SMAppService.openSystemSettingsLoginItems()
            throw HelperInstallerError.requiresApproval

        case .notFound:
            // macOS 14+ sometimes reports .notFound even with a properly placed plist
            // until register() is actually attempted. Try registering and let the
            // framework surface the real error if any.
            os_log("Status .notFound — attempting register() anyway", log: log, type: .info)
            try await register(service: service)

        @unknown default:
            break
        }
    }

    /// Detect a stale helper binary (bundled version > running version) and
    /// re-register the daemon so launchd picks up the freshly deployed binary.
    /// Without this, `SMAppService.daemon().status == .enabled` short-circuits
    /// `installIfNeeded()` and the old helper keeps running until manual
    /// `launchctl kickstart -k`.
    ///
    /// **Refuses downgrade** — if the running helper version is newer than
    /// or equal to the bundled one, this is a no-op. Otherwise launching
    /// an older but correctly-signed app bundle (a stray previous release
    /// in Downloads, an outdated nightly) would unregister a newer running
    /// helper. The downgrade ban was added per Codex security audit
    /// (2026-05-04, finding #13).
    static func refreshIfStale() async {
        let expected = bundledVersion
        let runningVersion = await XPCClient.fetchHelperVersion()

        // Decide whether a refresh is warranted. Three paths land here:
        //   - .same       → no-op
        //   - .bundledOlder → refuse (downgrade ban)
        //   - .bundledNewer → refresh
        // A nil running version is the catch-22 case: SMAppService says
        // .enabled but the helper isn't answering helperVersion. If the
        // app simply skipped here (the previous behavior) the user was
        // stuck with a broken helper forever. Treat persistent
        // non-response as a stronger "stale" signal than "can't tell"
        // and force-refresh, gated by a 24 h throttle so a transient
        // XPC hiccup at launch doesn't churn the daemon every time.
        let action: RefreshAction
        if let running = runningVersion {
            switch compareVersions(bundled: expected, running: running) {
            case .same:
                os_log("Helper version matches bundle (%{public}s)", log: log, type: .info, expected)
                return
            case .bundledOlder:
                os_log("Refusing helper downgrade: bundled=%{public}s < running=%{public}s",
                       log: log, type: .info, expected, running)
                return
            case .bundledNewer:
                os_log("Helper version stale — running=%{public}s bundled=%{public}s; re-registering",
                       log: log, type: .info, running, expected)
                action = .refresh
            }
        } else if shouldAttemptRecoveryRefresh() {
            os_log("Helper not responding to helperVersion — attempting recovery re-registration",
                   log: log, type: .info)
            recordRecoveryAttempt()
            action = .refresh
        } else {
            os_log("Helper non-responsive but recovery throttle still active — skipping",
                   log: log, type: .info)
            return
        }

        guard action == .refresh else { return }

        let service = SMAppService.daemon(plistName: plistName)
        do {
            try await service.unregister()
        } catch {
            os_log("Unregister failed: %{public}s", log: log, type: .error, error.localizedDescription)
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        do {
            try await register(service: service)
            os_log("Daemon re-registered with new binary", log: log, type: .info)
        } catch {
            os_log("Re-register failed: %{public}s", log: log, type: .error, error.localizedDescription)
        }
    }

    private enum RefreshAction { case refresh }

    private static let recoveryThrottleKey = "helper.lastRecoveryAttempt"
    private static let recoveryThrottleInterval: TimeInterval = 24 * 60 * 60   // 24 h

    /// Throttle the catch-22 recovery path. Without throttling, a helper
    /// that always times out on helperVersion would force a re-register
    /// on every launch — annoying for the user (the app stalls ~3 s on
    /// each launch) and chatty in launchd logs. 24 h is long enough to
    /// avoid churn, short enough that the user doesn't wait days for
    /// auto-recovery.
    private static func shouldAttemptRecoveryRefresh() -> Bool {
        let last = UserDefaults.standard.double(forKey: recoveryThrottleKey)
        return Date().timeIntervalSince1970 - last >= recoveryThrottleInterval
    }

    private static func recordRecoveryAttempt() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: recoveryThrottleKey)
    }

    enum VersionComparison {
        case same
        case bundledNewer    // refresh needed
        case bundledOlder    // downgrade — refuse
    }

    /// Compare CFBundleVersion strings monotonically. Apple recommends an
    /// integer-y build number (e.g., "1", "42") and Apple's own comparison
    /// rules treat them numerically. We accept the recommended form plus
    /// dotted-numeric ("1.2.3") as a fallback. Strings that parse as
    /// neither fall back to lexicographic compare; the only safe behavior
    /// then is to refuse refresh on inequality so we don't accidentally
    /// downgrade.
    static func compareVersions(bundled: String, running: String) -> VersionComparison {
        if bundled == running { return .same }

        // Integer compare path (e.g., "42" vs "41")
        if let b = Int(bundled), let r = Int(running) {
            return b > r ? .bundledNewer : .bundledOlder
        }

        // Dotted-numeric compare (e.g., "1.2.3" vs "1.3.0"). Pad the shorter
        // component list with zeros so "1.0.0" and "1.0" compare equal —
        // semantic versioning treats trailing zeros as implicit, and the
        // earlier "longer wins" rule triggered redundant re-registration on
        // every launch when the bundled version had a trailing .0 the
        // running helper didn't (or vice versa).
        let bComponents = bundled.split(separator: ".").compactMap { Int($0) }
        let rComponents = running.split(separator: ".").compactMap { Int($0) }
        if !bComponents.isEmpty,
           !rComponents.isEmpty,
           bComponents.count == bundled.split(separator: ".").count,
           rComponents.count == running.split(separator: ".").count {
            let longest = Swift.max(bComponents.count, rComponents.count)
            let bPadded = bComponents + Array(repeating: 0, count: longest - bComponents.count)
            let rPadded = rComponents + Array(repeating: 0, count: longest - rComponents.count)
            for (b, r) in zip(bPadded, rPadded) {
                if b != r { return b > r ? .bundledNewer : .bundledOlder }
            }
            return .same
        }

        // Unparseable — treat as downgrade so we never replace a working
        // helper with something we can't reason about.
        return .bundledOlder
    }

    private static func register(service: SMAppService) async throws {
        do {
            try service.register()
        } catch {
            throw HelperInstallerError.registrationFailed(error)
        }
        if service.status == .requiresApproval {
            os_log("Registration requires user approval", log: log, type: .info)
            SMAppService.openSystemSettingsLoginItems()
            throw HelperInstallerError.requiresApproval
        }
    }
}
