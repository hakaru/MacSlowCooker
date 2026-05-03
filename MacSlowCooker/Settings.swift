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

    var floatAboveOtherWindows: Bool = true {
        didSet { defaults.set(floatAboveOtherWindows, forKey: Keys.floatAboveOtherWindows) }
    }

    /// Restore every tracked property to its default value. didSet on each
    /// property handles persistence; downstream observers see one yield per
    /// changed field through `Settings.changes`.
    func resetToDefaults() {
        potStyle = .dutchOven
        flameAnimation = .both
        boilingTrigger = .combined
        floatAboveOtherWindows = true
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
        // .object(forKey:) returns nil when the key is missing — distinguish "never set"
        // from "explicitly false" so the default of true holds on first launch.
        self.floatAboveOtherWindows = (defaults.object(forKey: Keys.floatAboveOtherWindows) as? Bool) ?? true
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
