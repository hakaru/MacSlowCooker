import Foundation

protocol Clock: AnyObject {
    var now: Date { get }
}

final class SystemClock: Clock {
    var now: Date { Date() }
}
