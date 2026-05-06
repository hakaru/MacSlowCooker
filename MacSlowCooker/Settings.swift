import Foundation
import Observation

@Observable
@MainActor
final class Settings {

    enum Keys {
        static let potStyle       = "potStyle"
        static let flameAnimation = "flameAnimation"
        static let boilingTrigger = "boilingTrigger"
        static let floatAboveOtherWindows = "floatAboveOtherWindows"
        static let prometheusEnabled      = "prometheusEnabled"
        static let prometheusPort         = "prometheusPort"
        static let prometheusBindAll      = "prometheusBindAll"
        static let pngExportEnabled = "pngExportEnabled"
        static let pngExportPath    = "pngExportPath"
        static let licenseKey        = "licenseKey"
        static let licenseVerifiedAt = "licenseVerifiedAt"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let keychain: KeychainStore

    var potStyle: PotStyle = .dutchOven {
        didSet { defaults.set(potStyle.rawValue, forKey: Keys.potStyle) }
    }

    var flameAnimation: FlameAnimation = .both {
        didSet { defaults.set(flameAnimation.rawValue, forKey: Keys.flameAnimation) }
    }

    var boilingTrigger: BoilingTrigger = .combined {
        didSet { defaults.set(boilingTrigger.rawValue, forKey: Keys.boilingTrigger) }
    }

    var floatAboveOtherWindows: Bool = true {
        didSet { defaults.set(floatAboveOtherWindows, forKey: Keys.floatAboveOtherWindows) }
    }

    var prometheusEnabled: Bool = false {
        didSet { defaults.set(prometheusEnabled, forKey: Keys.prometheusEnabled) }
    }

    var prometheusPort: Int = 9091 {
        didSet { defaults.set(prometheusPort, forKey: Keys.prometheusPort) }
    }

    var prometheusBindAll: Bool = false {
        didSet { defaults.set(prometheusBindAll, forKey: Keys.prometheusBindAll) }
    }

    var pngExportEnabled: Bool = false {
        didSet { defaults.set(pngExportEnabled, forKey: Keys.pngExportEnabled) }
    }

    var pngExportPath: String = Settings.defaultPNGExportPath {
        didSet { defaults.set(pngExportPath, forKey: Keys.pngExportPath) }
    }

    var licenseKey: String? = nil {
        didSet {
            if let v = licenseKey { keychain.write(v, forKey: Keys.licenseKey) }
            else { keychain.delete(forKey: Keys.licenseKey) }
        }
    }

    var licenseVerifiedAt: Date? = nil {
        didSet {
            if let d = licenseVerifiedAt {
                keychain.write(
                    ISO8601DateFormatter().string(from: d),
                    forKey: Keys.licenseVerifiedAt
                )
            } else {
                keychain.delete(forKey: Keys.licenseVerifiedAt)
            }
        }
    }

    /// licenseKey と licenseVerifiedAt は意図的にリセットしない（アカウント情報は設定とは別）
    func resetToDefaults() {
        potStyle = .dutchOven
        flameAnimation = .both
        boilingTrigger = .combined
        floatAboveOtherWindows = true
        prometheusEnabled = false
        prometheusPort    = 9091
        prometheusBindAll = false
        pngExportEnabled = false
        pngExportPath    = Settings.defaultPNGExportPath
    }

    static var defaultPNGExportPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacSlowCooker", isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
        return dir.path
    }

    static let shared = Settings()

    /// Assignments below fire `didSet`, re-writing the just-loaded value back to
    /// `UserDefaults`. Harmless and accepted as the tradeoff for keeping persistence
    /// declarative. `Settings.changes` (Task 4) starts tracking after init, so these
    /// init-time writes are not observed by consumers.
    init(defaults: UserDefaults = .standard,
         keychain: KeychainStore = KeychainStore(service: "com.macslowcooker.app")) {
        self.defaults = defaults
        self.keychain = keychain
        self.potStyle       = PotStyle(rawValue: defaults.string(forKey: Keys.potStyle) ?? "")        ?? .dutchOven
        self.flameAnimation = FlameAnimation(rawValue: defaults.string(forKey: Keys.flameAnimation) ?? "") ?? .both
        self.boilingTrigger = BoilingTrigger(rawValue: defaults.string(forKey: Keys.boilingTrigger) ?? "") ?? .combined
        // .object(forKey:) returns nil when the key is missing — distinguish "never set"
        // from "explicitly false" so the default of true holds on first launch.
        self.floatAboveOtherWindows = (defaults.object(forKey: Keys.floatAboveOtherWindows) as? Bool) ?? true
        self.prometheusEnabled = (defaults.object(forKey: Keys.prometheusEnabled) as? Bool) ?? false
        let storedPort = defaults.integer(forKey: Keys.prometheusPort)
        self.prometheusPort    = (1024...65535).contains(storedPort) ? storedPort : 9091
        self.prometheusBindAll = (defaults.object(forKey: Keys.prometheusBindAll) as? Bool) ?? false
        self.pngExportEnabled = (defaults.object(forKey: Keys.pngExportEnabled) as? Bool) ?? false
        self.pngExportPath    = (defaults.string(forKey: Keys.pngExportPath)) ?? Settings.defaultPNGExportPath
        self.licenseKey = keychain.read(forKey: Keys.licenseKey)
        if let s = keychain.read(forKey: Keys.licenseVerifiedAt) {
            self.licenseVerifiedAt = ISO8601DateFormatter().date(from: s)
        }
    }
}

extension Settings {

    /// Yields once per mutation of any tracked property. Re-arms
    /// `withObservationTracking` automatically after each yield.
    ///
    /// Lifetime: the tracker is captured by the continuation's
    /// `onTermination`, so it lives as long as a consumer is iterating
    /// the stream. When the consumer breaks the loop AsyncStream invokes
    /// `onTermination`, which cancels the tracker; AsyncStream then
    /// releases the closure (and the tracker with it). The tracker's
    /// `onChange` captures `continuation` directly — `Continuation` is
    /// a value type, so no real strong cycle forms.
    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let tracker = SettingsChangeTracker(settings: self) {
                continuation.yield(())
            }
            Task { @MainActor in tracker.start() }
            continuation.onTermination = { _ in
                Task { @MainActor in tracker.cancel() }
            }
        }
    }
}

@MainActor
private final class SettingsChangeTracker {
    private weak var settings: Settings?
    private let onChange: () -> Void
    private var cancelled = false

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
    }

    func start() {
        guard !cancelled, let settings else { return }
        withObservationTracking {
            _ = settings.potStyle
            _ = settings.flameAnimation
            _ = settings.boilingTrigger
            _ = settings.floatAboveOtherWindows
            _ = settings.prometheusEnabled
            _ = settings.prometheusPort
            _ = settings.prometheusBindAll
            _ = settings.pngExportEnabled
            _ = settings.pngExportPath
            _ = settings.licenseKey
            _ = settings.licenseVerifiedAt
        } onChange: { [weak self] in
            // onChange fires synchronously *before* the mutation completes.
            // Hop to a Task so the new value is observable when downstream
            // consumers run, and so we can re-arm tracking.
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.onChange()
                self.start()
            }
        }
    }

    /// Called from `AsyncStream.onTermination`, which fires on an arbitrary executor.
    /// We dispatch the flag write to MainActor; this means an in-flight onChange Task
    /// may race ahead and call `continuation.yield(())` once on a finished continuation.
    /// Yielding to a finished `AsyncStream.Continuation` is a documented no-op, so the
    /// race is benign. The next observed mutation (if any) sees `cancelled == true`
    /// and stops re-arming.
    nonisolated func cancel() {
        Task { @MainActor in self.cancelled = true }
    }
}
