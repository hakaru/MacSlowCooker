import Foundation
import Observation

@Observable
@MainActor
final class GPUDataStore {
    private(set) var samples: [GPUSample] = []
    private(set) var latestSample: GPUSample?
    private(set) var isConnected: Bool = false

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
}
