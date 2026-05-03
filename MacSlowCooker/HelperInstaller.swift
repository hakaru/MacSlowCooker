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
