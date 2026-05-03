import Foundation
import Observation

@Observable
@MainActor
final class GPUDataStore {
    private(set) var samples: [GPUSample] = []
    private(set) var latestSample: GPUSample?
    private(set) var isConnected: Bool = false

    /// Set when helper installation or registration fails. PopupView surfaces
    /// this as an in-window banner instead of the previous modal NSAlert,
    /// which blocked the run loop and forced the user to quit before they
    /// could approve the helper in System Settings.
    private(set) var installError: String?

    private let maxSamples = 60

    func addSample(_ sample: GPUSample) {
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst()
        }
        latestSample = sample
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
    }

    func setInstallError(_ message: String?) {
        installError = message
    }
}
