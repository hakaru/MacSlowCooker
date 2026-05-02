import Foundation
import Observation

@Observable
@MainActor
final class Settings {

    enum Keys {
        static let potStyle       = "potStyle"
        static let flameAnimation = "flameAnimation"
        static let boilingTrigger = "boilingTrigger"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var potStyle: PotStyle = .dutchOven {
        didSet { defaults.set(potStyle.rawValue, forKey: Keys.potStyle) }
    }

    var flameAnimation: FlameAnimation = .both {
        didSet { defaults.set(flameAnimation.rawValue, forKey: Keys.flameAnimation) }
    }

    var boilingTrigger: BoilingTrigger = .combined {
        didSet { defaults.set(boilingTrigger.rawValue, forKey: Keys.boilingTrigger) }
    }

    static let shared = Settings()

    /// Assignments below fire `didSet`, re-writing the just-loaded value back to
    /// `UserDefaults`. Harmless and accepted as the tradeoff for keeping persistence
    /// declarative. `Settings.changes` (Task 4) starts tracking after init, so these
    /// init-time writes are not observed by consumers.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.potStyle       = PotStyle(rawValue: defaults.string(forKey: Keys.potStyle) ?? "")        ?? .dutchOven
        self.flameAnimation = FlameAnimation(rawValue: defaults.string(forKey: Keys.flameAnimation) ?? "") ?? .both
        self.boilingTrigger = BoilingTrigger(rawValue: defaults.string(forKey: Keys.boilingTrigger) ?? "") ?? .combined
    }
}

extension Settings {

    /// Yields once per mutation of any tracked property.
    /// Re-arms `withObservationTracking` automatically after each yield.
    var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let tracker = SettingsChangeTracker(settings: self) {
                continuation.yield(())
            }
            Task { @MainActor in tracker.start() }
            continuation.onTermination = { _ in tracker.cancel() }
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

    nonisolated func cancel() {
        Task { @MainActor in self.cancelled = true }
    }
}
