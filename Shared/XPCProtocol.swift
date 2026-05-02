import Foundation
@objc(GPUSMIHelperProtocol)
protocol GPUSMIHelperProtocol {
    func startSampling(withReply reply: @escaping (Bool, String?) -> Void)
    func stopSampling(withReply reply: @escaping () -> Void)
    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
