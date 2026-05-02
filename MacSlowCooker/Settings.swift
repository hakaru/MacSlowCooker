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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.potStyle       = PotStyle(rawValue: defaults.string(forKey: Keys.potStyle) ?? "")        ?? .dutchOven
        self.flameAnimation = FlameAnimation(rawValue: defaults.string(forKey: Keys.flameAnimation) ?? "") ?? .both
        self.boilingTrigger = BoilingTrigger(rawValue: defaults.string(forKey: Keys.boilingTrigger) ?? "") ?? .combined
    }
}
