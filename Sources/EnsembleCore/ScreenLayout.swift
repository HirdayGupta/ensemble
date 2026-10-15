import CoreGraphics
import Foundation

/// A connected screen as the display arrangement in System Settings has it. `frame` is global, top-left origin.
public struct ScreenDescription: Equatable, Sendable {
    public var name: String
    public var frame: CGRect
    public var isMain: Bool
    public init(name: String, frame: CGRect, isMain: Bool) { self.name = name; self.frame = frame; self.isMain = isMain }
}

public enum ScreenLayout {
    public static func orientation(of frame: CGRect) -> String { frame.width >= frame.height ? "landscape" : "portrait" }

    /// "1920 x 1080" in points.
    public static func size(of frame: CGRect) -> String { "\(Int(frame.width.rounded())) \u{00D7} \(Int(frame.height.rounded()))" }

    /// Where a screen sits relative to the main one: "main", or "left, portrait", "right, landscape", "above, ...".
    public static func position(of screen: ScreenDescription, among screens: [ScreenDescription]) -> String {
        if screen.isMain { return "main" }
        let main = screens.first(where: \.isMain) ?? screens.first
        guard let main else { return orientation(of: screen.frame) }
        let dx = screen.frame.midX - main.frame.midX, dy = screen.frame.midY - main.frame.midY
        let side: String
        if abs(dx) >= abs(dy) { side = dx < 0 ? "left" : "right" } else { side = dy < 0 ? "above" : "below" }
        return "\(side), \(orientation(of: screen.frame))"
    }

    /// "Found 2 screens".
    public static func headline(count: Int) -> String { "Found \(count) screen\(count == 1 ? "" : "s")" }

    /// "DELL U2723QE" and a detail line "2560 x 1440, main" / "1080 x 1920, left, portrait".
    public static func detail(of screen: ScreenDescription, among screens: [ScreenDescription]) -> String {
        let place = position(of: screen, among: screens)
        return screen.isMain ? "\(size(of: screen.frame)), \(orientation(of: screen.frame)), main" : "\(size(of: screen.frame)), \(place)"
    }

    /// "Screen 2 of 2 \u{00B7} DELL U2723QE \u{00B7} turn to face it".
    public static func stepTitle(index: Int, count: Int, name: String, facing: Bool) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("Screen \(index + 1) of \(count)") }
        parts.append(name)
        if facing { parts.append("turn to face it") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Calibrated for 2 screens", or "... for 1 of 2 screens" when only some connected screens are.
    public static func calibratedLine(valid: Int, connected: Int) -> String? {
        guard valid > 0, connected > 0 else { return nil }
        if valid >= connected { return "Calibrated for \(connected) screen\(connected == 1 ? "" : "s")" }
        return "Calibrated for \(valid) of \(connected) screens"
    }
}
