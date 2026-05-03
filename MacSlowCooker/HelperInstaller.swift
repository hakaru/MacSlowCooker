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

    /// Detect a stale helper binary (running version != bundled version) and
    /// re-register the daemon so launchd picks up the freshly deployed binary.
    /// Without this, `SMAppService.daemon().status == .enabled` short-circuits
    /// `installIfNeeded()` and the old helper keeps running until manual
    /// `launchctl kickstart -k`.
    static func refreshIfStale() async {
        let expected = bundledVersion
        guard let running = await XPCClient.fetchHelperVersion() else {
            os_log("Could not query helper version (timeout / XPC error) — skipping refresh check",
                   log: log, type: .info)
            return
        }
        guard running != expected else {
            os_log("Helper version matches bundle (%{public}s)", log: log, type: .info, expected)
            return
        }
        os_log("Helper version mismatch — running=%{public}s bundled=%{public}s; re-registering",
               log: log, type: .info, running, expected)

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
