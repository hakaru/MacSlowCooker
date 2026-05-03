import Foundation

/// XPC contract between MacSlowCooker.app and the root LaunchDaemon helper.
///
/// All methods are no-argument other than the reply block — the helper
/// rejects any caller-supplied paths or process arguments by construction.
@objc(MacSlowCookerHelperProtocol)
protocol MacSlowCookerHelperProtocol {

    /// Begin sampling on first call; subsequent calls are idempotent and
    /// reply success without spawning a second powermetrics process.
    /// `reply(false, message)` indicates the spawn failed.
    func startSampling(withReply reply: @escaping (Bool, String?) -> Void)

    /// Intentional no-op. Daemon lifecycle is managed by launchd: the
    /// helper stays alive while any client is connected and is idled out
    /// by launchd when none are. The runner outlives any single client by
    /// design — multiple app instances on the same machine all share the
    /// one powermetrics process, and tearing it down on first disconnect
    /// would force re-spawn (~1.3 s) for the next reconnect. Kept on the
    /// protocol for symmetry and to leave the door open for a future
    /// reference-counted implementation.
    func stopSampling(withReply reply: @escaping () -> Void)

    /// Returns the most recent encoded `GPUSample` JSON, or nil if no
    /// sample has been produced yet (cold start before powermetrics emits).
    func fetchLatestSample(withReply reply: @escaping (Data?) -> Void)

    /// Returns the helper bundle's `CFBundleVersion`. The app calls this
    /// at startup (HelperInstaller.refreshIfStale) to detect a stale
    /// running helper after a fresh deploy.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
