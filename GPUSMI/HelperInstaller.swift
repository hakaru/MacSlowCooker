import Foundation
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "com.gpusmi", category: "app")

enum HelperInstallerError: LocalizedError {
    case requiresApproval
    case registrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "System Settings でGPUSMIの実行を許可してください"
        case .registrationFailed(let e):
            return "HelperToolのインストールに失敗しました: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class HelperInstaller {

    private static let plistName = "com.gpusmi.helper.plist"

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
            os_log("Daemon plist not found in bundle", log: log, type: .fault)
            throw HelperInstallerError.registrationFailed(
                NSError(domain: "com.gpusmi", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Daemon plist not found"])
            )

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
