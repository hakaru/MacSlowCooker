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

import AppKit

/// Captures every IconState the animator renders.
final class CapturingRenderer: PotRenderer {
    private(set) static var captured: [IconState] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); captured.removeAll(); lock.unlock()
    }

    static func render(state: IconState) -> NSImage {
        lock.lock(); captured.append(state); lock.unlock()
        return NSImage(size: iconSize)
    }
}
