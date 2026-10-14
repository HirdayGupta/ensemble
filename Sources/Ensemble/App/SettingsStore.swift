import SwiftUI
import ServiceManagement
import EnsembleCore

/// User preferences, persisted in the "dev.ensemble.app" defaults suite.
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
        static let reverseScroll = "reverseScroll"
        static let liveSoundBars = "liveSoundBars"
        static let playSounds = "playSounds"
        static let pauseMediaWhileDictating = "pauseMediaWhileDictating"
        static let calibration = "calibration"
        static let calibratedAt = "calibratedAt"
        static let calibrationDisplays = "calibrationDisplays"
        static let lastClaudeVersion = "lastClaudeVersion"
    }

    static let countdownRange: ClosedRange<Double> = 0.5...3

    private let defaults: UserDefaults

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var showNoseDot: Bool { didSet { defaults.set(showNoseDot, forKey: Key.showNoseDot) } }
    @Published var showHighlight: Bool { didSet { defaults.set(showHighlight, forKey: Key.showHighlight) } }
    /// nil = automatic camera choice.
    @Published var cameraName: String? { didSet { defaults.set(cameraName, forKey: Key.cameraName) } }
    @Published var mapping: GestureMapping { didSet { saveMapping() } }
    @Published var pointerSmoothing: Double { didSet { defaults.set(pointerSmoothing, forKey: Key.pointerSmoothing) } }
    /// Flips pinch-and-drag scrolling relative to the Mac's own scroll direction.
    @Published var reverseScroll: Bool { didSet { defaults.set(reverseScroll, forKey: Key.reverseScroll) } }
    /// Off by default: the listening sign is a blinking microphone dot and Ensemble never asks for the microphone.
    /// On: sound bars follow the voice level, which needs microphone permission.
    @Published var liveSoundBars: Bool { didSet { defaults.set(liveSoundBars, forKey: Key.liveSoundBars) } }
    @Published var sendCountdownSeconds: Double {
        didSet {
            let clamped = min(max(sendCountdownSeconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
            if clamped != sendCountdownSeconds { sendCountdownSeconds = clamped; return }
            defaults.set(sendCountdownSeconds, forKey: Key.sendCountdownSeconds)
        }
    }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var pauseMediaWhileDictating: Bool { didSet { defaults.set(pauseMediaWhileDictating, forKey: Key.pauseMediaWhileDictating) } }
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
        // In the packaged app the bundle identifier is "dev.ensemble.app", so the standard domain already is that
        // suite; naming it as a suite is rejected. Outside a bundle (swift run) the suite is used.
        let suite = "dev.ensemble.app"
        let store = defaults ?? (Bundle.main.bundleIdentifier == suite ? .standard : UserDefaults(suiteName: suite) ?? .standard)
        self.defaults = store
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }

        enabled = bool(Key.enabled, true)
        showNoseDot = bool(Key.showNoseDot, true)
        showHighlight = bool(Key.showHighlight, true)
        cameraName = store.string(forKey: Key.cameraName)
        playSounds = bool(Key.playSounds, true)
        pauseMediaWhileDictating = bool(Key.pauseMediaWhileDictating, true)
        LoginAgent.repointIfStale()
        launchAtLogin = LoginAgent.isEnabled
        calibration = store.data(forKey: Key.calibration)
        calibratedAt = store.object(forKey: Key.calibratedAt) as? Date
        calibrationDisplays = store.string(forKey: Key.calibrationDisplays)
        lastClaudeVersion = store.string(forKey: Key.lastClaudeVersion)

        pointerSmoothing = store.object(forKey: Key.pointerSmoothing) as? Double ?? 0.7
        reverseScroll = store.bool(forKey: Key.reverseScroll)
        liveSoundBars = store.bool(forKey: Key.liveSoundBars)
        let seconds = store.object(forKey: Key.sendCountdownSeconds) as? Double ?? 0.75
        sendCountdownSeconds = min(max(seconds, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)

        if let data = store.data(forKey: Key.mapping), var decoded = try? JSONDecoder().decode(GestureMapping.self, from: data) {
            // Version 2 made "gather" the talk gesture (start; gather then open to stop). Move hold-a-fist setups over once.
            if store.integer(forKey: "mappingVersion") < 2 {
                if decoded.talk == .fist { decoded.talk = .gather }
                store.set(2, forKey: "mappingVersion")
            }
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
    case talk, send, scrollUp, scrollDown, cancel
}

extension GestureMapping {
    subscript(slot: GestureSlot) -> Pose? {
        get {
            switch slot {
            case .talk: return talk
            case .send: return send
            case .scrollUp: return scrollUp
            case .scrollDown: return scrollDown
            case .cancel: return cancel
            }
        }
        set {
            switch slot {
            case .talk: if let newValue { talk = newValue }
            case .send: send = newValue
            case .scrollUp: scrollUp = newValue
            case .scrollDown: scrollDown = newValue
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
        case .gather: return "Gather (fingertips together)"
        case .pointUp: return "Point up"
        case .pointDown: return "Point down"
        }
    }

    /// SF Symbols has no closed-fist glyph; the filled raised hand stands in for it.
    var symbolName: String {
        switch self {
        case .fist: return "hand.raised.fill"
        case .openPalm: return "hand.raised.fingers.spread"
        case .thumbsUp: return "hand.thumbsup.fill"
        case .twoFingers: return "hand.point.up.fill"
        case .gather: return "hand.pinch.fill"
        case .pointUp: return "hand.point.up.left.fill"
        case .pointDown: return "hand.point.down.fill"
        }
    }
}

extension GestureSlot {
    var title: String {
        switch self {
        case .talk: return "Talk"
        case .send: return "Send"
        case .scrollUp: return "Scroll up"
        case .scrollDown: return "Scroll down"
        case .cancel: return "Cancel"
        }
    }

    var detail: String {
        switch self {
        case .talk: return "Pinch twice to dictate into the session you are facing. Pinch twice again to stop."
        case .send: return "Hold to send the dictated draft after the hold time set under Sending."
        case .scrollUp: return "Hold to scroll the session up, faster the longer you hold."
        case .scrollDown: return "Hold to scroll the session down, faster the longer you hold."
        case .cancel: return "Stops a pending send before the countdown ends."
        }
    }

    var allowsOff: Bool { self == .send || self == .scrollUp || self == .scrollDown }
}
