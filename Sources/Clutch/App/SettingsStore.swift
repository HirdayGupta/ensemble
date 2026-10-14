import SwiftUI
import ServiceManagement
import ClutchCore

/// User preferences, persisted in the "dev.clutch.app" defaults suite.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let enabled = "enabled"
        static let showNoseDot = "showNoseDot"
        static let showHighlight = "showHighlight"
        static let cameraName = "cameraName"
        static let mapping = "mapping"
        static let sendCountdownSeconds = "sendCountdownSeconds"
        static let pointerSmoothing = "pointerSmoothing"
        static let playSounds = "playSounds"
        static let calibration = "calibration"
        static let calibratedAt = "calibratedAt"
        static let calibrationDisplays = "calibrationDisplays"
        static let lastClaudeVersion = "lastClaudeVersion"
    }

    static let countdownRange: ClosedRange<Double> = 1...5

    private let defaults: UserDefaults

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var showNoseDot: Bool { didSet { defaults.set(showNoseDot, forKey: Key.showNoseDot) } }
    @Published var showHighlight: Bool { didSet { defaults.set(showHighlight, forKey: Key.showHighlight) } }
    /// nil = automatic camera choice.
    @Published var cameraName: String? { didSet { defaults.set(cameraName, forKey: Key.cameraName) } }
    @Published var mapping: GestureMapping { didSet { saveMapping() } }
    @Published var pointerSmoothing: Double { didSet { defaults.set(pointerSmoothing, forKey: Key.pointerSmoothing) } }
    @Published var sendCountdownSeconds: Double {
        didSet {
            let clamped = min(max(sendCountdownSeconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
            if clamped != sendCountdownSeconds { sendCountdownSeconds = clamped; return }
            defaults.set(sendCountdownSeconds, forKey: Key.sendCountdownSeconds)
        }
    }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    /// Set only through `setLaunchAtLogin`, which talks to the system first.
    @Published private(set) var launchAtLogin: Bool
    @Published var launchAtLoginError: String?
    /// Opaque blob written by the coordinator.
    @Published var calibration: Data? { didSet { defaults.set(calibration, forKey: Key.calibration) } }
    @Published var calibratedAt: Date? { didSet { defaults.set(calibratedAt, forKey: Key.calibratedAt) } }
    /// The screen arrangement the calibration was made on; a different arrangement needs a new calibration.
    @Published var calibrationDisplays: String? { didSet { defaults.set(calibrationDisplays, forKey: Key.calibrationDisplays) } }
    /// The Claude version the last confirmed dictation ran on.
    @Published var lastClaudeVersion: String? { didSet { defaults.set(lastClaudeVersion, forKey: Key.lastClaudeVersion) } }

    init(defaults: UserDefaults? = nil) {
        // In the packaged app the bundle identifier is "dev.clutch.app", so the standard domain already is that
        // suite; naming it as a suite is rejected. Outside a bundle (swift run) the suite is used.
        let suite = "dev.clutch.app"
        let store = defaults ?? (Bundle.main.bundleIdentifier == suite ? .standard : UserDefaults(suiteName: suite) ?? .standard)
        self.defaults = store
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }

        enabled = bool(Key.enabled, true)
        showNoseDot = bool(Key.showNoseDot, true)
        showHighlight = bool(Key.showHighlight, true)
        cameraName = store.string(forKey: Key.cameraName)
        playSounds = bool(Key.playSounds, true)
        LoginAgent.repointIfStale()
        launchAtLogin = LoginAgent.isEnabled
        calibration = store.data(forKey: Key.calibration)
        calibratedAt = store.object(forKey: Key.calibratedAt) as? Date
        calibrationDisplays = store.string(forKey: Key.calibrationDisplays)
        lastClaudeVersion = store.string(forKey: Key.lastClaudeVersion)

        pointerSmoothing = store.object(forKey: Key.pointerSmoothing) as? Double ?? 0.7
        let seconds = store.object(forKey: Key.sendCountdownSeconds) as? Double ?? 2.0
        sendCountdownSeconds = min(max(seconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)

        if let data = store.data(forKey: Key.mapping), let decoded = try? JSONDecoder().decode(GestureMapping.self, from: data) {
            mapping = decoded
        } else {
            mapping = GestureMapping()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try LoginAgent.enable() } else { try LoginAgent.disable() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change open at login: \(error.localizedDescription)"
        }
        launchAtLogin = LoginAgent.isEnabled
    }

    func assign(_ pose: Pose?, to slot: GestureSlot) {
        var next = mapping
        next.assign(pose, to: slot)
        mapping = next
    }

    private func saveMapping() {
        if let data = try? JSONEncoder().encode(mapping) { defaults.set(data, forKey: Key.mapping) }
    }
}

enum GestureSlot: CaseIterable {
    case talk, send, scroll, cancel
}

extension GestureMapping {
    subscript(slot: GestureSlot) -> Pose? {
        get {
            switch slot {
            case .talk: return talk
            case .send: return send
            case .scroll: return scroll
            case .cancel: return cancel
            }
        }
        set {
            switch slot {
            case .talk: if let newValue { talk = newValue }
            case .send: send = newValue
            case .scroll: scroll = newValue
            case .cancel: if let newValue { cancel = newValue }
            }
        }
    }

    /// Gives `slot` the pose; if another slot already used it, that slot takes this slot's previous pose
    /// (or an unused one when this slot was Off), so no two slots ever share a pose.
    mutating func assign(_ pose: Pose?, to slot: GestureSlot) {
        guard let pose else {
            self[slot] = nil
            return
        }
        let previous = self[slot]
        if let other = GestureSlot.allCases.first(where: { $0 != slot && self[$0] == pose }) {
            let used = Set(GestureSlot.allCases.compactMap { self[$0] })
            self[other] = previous ?? Pose.allCases.first(where: { !used.contains($0) })
        }
        self[slot] = pose
    }
}

extension Pose {
    var title: String {
        switch self {
        case .fist: return "Fist"
        case .openPalm: return "Open palm"
        case .thumbsUp: return "Thumbs up"
        case .twoFingers: return "Two fingers"
        }
    }

    /// SF Symbols has no closed-fist glyph; the filled raised hand stands in for it.
    var symbolName: String {
        switch self {
        case .fist: return "hand.raised.fill"
        case .openPalm: return "hand.raised.fingers.spread"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .twoFingers: return "hand.point.up.fill"
        }
    }
}

extension GestureSlot {
    var title: String {
        switch self {
        case .talk: return "Talk"
        case .send: return "Send"
        case .scroll: return "Scroll"
        case .cancel: return "Cancel"
        }
    }

    var detail: String {
        switch self {
        case .talk: return "Hold to dictate into the session you are facing. Release to stop."
        case .send: return "Sends the dictated draft after a countdown you can cancel."
        case .scroll: return "Hold, then move your hand up or down to scroll the session."
        case .cancel: return "Stops a pending send before the countdown ends."
        }
    }

    var allowsOff: Bool { self == .send || self == .scroll }
}
