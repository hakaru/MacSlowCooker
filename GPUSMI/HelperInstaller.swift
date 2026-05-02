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
            if await needsUpdate() {
                os_log("Updating daemon...", log: log, type: .info)
                try await service.unregister()
                try await register(service: service)
            } else {
                os_log("Daemon already up-to-date", log: log, type: .info)
            }

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
    }

    private static func needsUpdate() async -> Bool {
        guard let bundleHelperURL = Bundle.main.url(
            forResource: "HelperTool",
            withExtension: nil,
            subdirectory: "Contents/Library/LaunchDaemons"
        ),
        let bundleVersion = Bundle(url: bundleHelperURL)?.infoDictionary?["CFBundleVersion"] as? String
        else { return false }

        return await withCheckedContinuation { continuation in
            let conn = NSXPCConnection(machServiceName: "com.gpusmi.helper", options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: GPUSMIHelperProtocol.self)
            conn.resume()

            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume(returning: true)
            } as? GPUSMIHelperProtocol

            proxy?.helperVersion { installedVersion in
                conn.invalidate()
                continuation.resume(returning: installedVersion != bundleVersion)
            }
        }
    }
}
