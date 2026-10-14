import Foundation
import Vision
@testable import EnsembleCore

struct Frame {
    let t: TimeInterval
    let hand: Hand?
}

enum FixtureReplay {
    static func load(_ name: String) throws -> [Frame] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures") else {
            throw NSError(domain: "FixtureReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var frames: [Frame] = []
        for line in text.split(separator: "\n") {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String != "header", let t = obj["t"] as? Double else { continue }
            frames.append(Frame(t: t, hand: (obj["hand"] as? [String: Any]).map(parseHand)))
        }
        return frames
    }

    private static func parseHand(_ json: [String: Any]) -> Hand {
        let chirality: VNChirality
        switch json["c"] as? String {
        case "L": chirality = .left
        case "R": chirality = .right
        default: chirality = .unknown
        }
        var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for (key, value) in (json["p"] as? [String: [Double]]) ?? [:] where value.count == 2 {
            points[VNHumanHandPoseObservation.JointName(rawValue: VNRecognizedPointKey(rawValue: key))] = CGPoint(x: value[0], y: value[1])
        }
        return Hand(chirality: chirality, points: points, confidence: Float(json["conf"] as? Double ?? 1))
    }

    static func observations(_ name: String) throws -> [HandObservation] {
        let classifier = GestureClassifier()
        return try load(name).map { HandClassifierAdapter.observation(from: $0.hand, at: $0.t, classifier: classifier) }
    }

    /// Intents with the time they fired, replayed through a fresh machine.
    static func intents(_ name: String, mapping: GestureMapping = .holdFist) throws -> [(t: TimeInterval, intent: GestureIntent)] {
        let machine = GestureMachine(mapping: mapping)
        machine.talkStyle = .hold
        var out: [(TimeInterval, GestureIntent)] = []
        for o in try observations(name) {
            for i in machine.push(o) { out.append((o.t, i)) }
        }
        return out
    }
}
