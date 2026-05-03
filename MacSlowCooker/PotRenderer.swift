import AppKit
import Foundation

/// View-layer protocol for rendering an `IconState` into a Dock-icon
/// bitmap. The domain types it consumes (`IconState`, `PotStyle`,
/// `FlameAnimation`, `BoilingTrigger`) live in `Shared/DomainTypes.swift`
/// so the logic and persistence layers can use them without depending on
/// AppKit.
protocol PotRenderer {
    static var iconSize: CGSize { get }
    static func render(state: IconState) -> NSImage
}

extension PotRenderer {
    static var iconSize: CGSize { CGSize(width: 512, height: 512) }
}
