import Foundation
@objc(MacSlowCookerHelperProtocol)
protocol MacSlowCookerHelperProtocol {
    func startSampling(withReply reply: @escaping (Bool, String?) -> Void)
    func stopSampling(withReply reply: @escaping () -> Void)
    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
