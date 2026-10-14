import CoreGraphics
import Foundation
@testable import ClutchCore

/// Drives a GestureMachine with synthetic 30 fps frames and records when each intent fired.
final class GestureSim {
    let machine: GestureMachine
    var t = 10.0
    var log: [(t: TimeInterval, intent: GestureIntent)] = []
    let fps = 30.0

    init(mapping: GestureMapping = .init()) { machine = GestureMachine(mapping: mapping) }

    var intents: [GestureIntent] { log.map(\.intent) }

    func count(_ intent: GestureIntent) -> Int { intents.filter { $0 == intent }.count }

    /// Time of the first logged intent equal to `intent`, relative to `origin`.
    func firstTime(of intent: GestureIntent) -> TimeInterval? { log.first { $0.intent == intent }?.t }

    func scrollTotal() -> Double {
        intents.reduce(0) { acc, i in if case .scroll(let dy) = i { return acc + dy }; return acc }
    }

    /// Holds `pose` for `duration` seconds. `palmY` maps seconds-since-start to a vertical palm position.
    func hold(_ pose: Pose?, for duration: Double, palmY: ((Double) -> Double)? = nil) {
        let frames = Int((duration * fps).rounded())
        let start = t
        for _ in 0..<frames {
            let y = palmY?(t - start) ?? 0.5
            record(machine.push(HandObservation(t: t, present: true, pose: pose, palmCenter: CGPoint(x: 0.5, y: y))))
            t += 1 / fps
        }
    }

    func absent(for duration: Double) {
        for _ in 0..<Int((duration * fps).rounded()) {
            record(machine.push(HandObservation(t: t, present: false, pose: nil, palmCenter: nil)))
            t += 1 / fps
        }
    }

    func tick(after silence: Double) {
        record(machine.tick(now: t - 1 / fps + silence))
    }

    private func record(_ out: [GestureIntent]) {
        for i in out { log.append((t, i)) }
    }
}
