import Foundation
@testable import MacSlowCooker

/// Mutable Clock used by DockIconAnimator tests. Time only moves when `advance(by:)` is called.
final class TestClock: Clock {
    private(set) var now: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = start
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
