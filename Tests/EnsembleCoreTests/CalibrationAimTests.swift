import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct CalibrationAimTests {
    static let frame = CGRect(x: 0, y: 0, width: 2000, height: 1000)
    static let rule = AimRule()

    /// 15 Hz readings from `start` for `seconds`, holding (yaw, pitch) plus a repeating `jitter`.
    static func hold(yaw: Double, pitch: Double, from start: TimeInterval = 0, seconds: Double = 0.6, jitter: Double = 0) -> [AimReading] {
        let n = Int(seconds * 15)
        return (0..<n).map { i in
            let wobble = i % 2 == 0 ? jitter : -jitter
            return AimReading(t: start + Double(i) / 15, yaw: yaw + wobble, pitch: pitch + wobble)
        }
    }

    /// The centre dot was taken facing straight ahead; the next dot is on the left edge.
    static let centre = CalibrationSample(yaw: 0, pitch: 0, target: CGPoint(x: 1000, y: 500))
    static let leftDot = CGPoint(x: 160, y: 500)

    @Test func headMovedTowardTheDotIsAccepted() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        let verdict = Self.rule.evaluate(Self.hold(yaw: -0.25, pitch: 0.01), requirement: req)
        guard case .ready(let yaw, _) = verdict else { Issue.record("expected ready, got \(verdict)"); return }
        #expect(abs(yaw + 0.25) < 0.01)
    }

    @Test func headMovedAwayIsRefused() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        #expect(Self.rule.evaluate(Self.hold(yaw: 0.25, pitch: 0), requirement: req) == .wrongWay)
    }

    @Test func headNotMovedIsRefused() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        #expect(Self.rule.evaluate(Self.hold(yaw: 0.005, pitch: 0), requirement: req) == .notFarEnough)
    }

    @Test func movedTooLittleIsRefused() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        #expect(Self.rule.evaluate(Self.hold(yaw: -0.02, pitch: 0), requirement: req) == .notFarEnough)
    }

    @Test func jitteryHeadIsNotStillEvenWhenItIsInTheRightPlace() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        #expect(Self.rule.evaluate(Self.hold(yaw: -0.25, pitch: 0, jitter: 0.04), requirement: req) == .notStill)
        #expect(Self.rule.evaluate(Self.hold(yaw: -0.25, pitch: 0, jitter: 0.004), requirement: req) != .notStill)
    }

    @Test func tooFewOrTooShortReadingsAreNotStill() {
        let req = AimRequirement.stillness
        #expect(Self.rule.evaluate([], requirement: req) == .notStill)
        #expect(Self.rule.evaluate(Self.hold(yaw: 0, pitch: 0, seconds: 0.2), requirement: req) == .notStill)
    }

    @Test func stillnessAloneAcceptsTheFirstDot() {
        #expect(Self.rule.requirement(forFirstDotOn: Self.frame, previousScreen: nil) == .stillness)
        guard case .ready(let yaw, let pitch) = Self.rule.evaluate(Self.hold(yaw: 0.1, pitch: 0.1), requirement: .stillness) else { Issue.record("not ready"); return }
        #expect(abs(yaw - 0.1) < 1e-9 && abs(pitch - 0.1) < 1e-9)
    }

    @Test func downAndUpDotsExpectPitchOnly() {
        let top = CalibrationSample(yaw: 0, pitch: -0.1, target: CGPoint(x: 1000, y: 80))
        let req = Self.rule.requirement(forTarget: CGPoint(x: 1000, y: 920), on: Self.frame, accepted: [Self.centre, top])
        guard case let .movedToward(_, _, yawSign, pitchSign, _, _) = req else { Issue.record("expected movement"); return }
        #expect(yawSign == 0 && pitchSign == 1)
        #expect(Self.rule.evaluate(Self.hold(yaw: 0, pitch: 0.12), requirement: req) == .ready(yaw: 0, pitch: 0.12))
        #expect(Self.rule.evaluate(Self.hold(yaw: 0, pitch: -0.25), requirement: req) == .wrongWay)
    }

    @Test func requiredTurnLearnsFromSamplesAlreadyTaken() {
        // Centre to left took 0.9 rad, so a screen this wide needs far more than the assumed default for the right dot.
        let left = CalibrationSample(yaw: -0.9, pitch: 0, target: Self.leftDot)
        let req = Self.rule.requirement(forTarget: CGPoint(x: 1840, y: 500), on: Self.frame, accepted: [Self.centre, left])
        guard case let .movedToward(_, _, _, _, minYaw, _) = req else { Issue.record("expected movement"); return }
        #expect(minYaw > 0.2)
    }

    @Test func secondScreenToTheLeftNeedsAYawLeft() {
        let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let portrait = CGRect(x: -1080, y: -300, width: 1080, height: 1920)
        let mainCentre = CalibrationSample(yaw: 0, pitch: 0, target: CGPoint(x: main.midX, y: main.midY))
        let req = Self.rule.requirement(forFirstDotOn: portrait, previousScreen: (main, mainCentre))
        guard case let .movedToward(_, _, yawSign, _, _, _) = req else { Issue.record("expected movement"); return }
        #expect(yawSign == -1)
        #expect(Self.rule.evaluate(Self.hold(yaw: -0.5, pitch: 0), requirement: req) != .wrongWay)
        #expect(Self.rule.evaluate(Self.hold(yaw: 0.3, pitch: 0), requirement: req) == .wrongWay)
        #expect(Self.rule.evaluate(Self.hold(yaw: 0, pitch: 0), requirement: req) == .notFarEnough)
    }

    // MARK: Gate

    @Test func ringStartsOnlyOnceTheHeadHasArrivedAndHolds() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        var gate = AimGate(requirement: req, startedAt: 0)
        // The head stays where the previous dot was taken for two seconds: no ring.
        for r in Self.hold(yaw: 0, pitch: 0, seconds: 2) { gate.push(r); #expect(gate.update(now: r.t) == .waiting(.turnToDot)) }
        // Then it turns and holds.
        var sawFilling = false, captured: (Double, Double)?
        for r in Self.hold(yaw: -0.3, pitch: 0, from: 2.1, seconds: 3) {
            gate.push(r)
            switch gate.update(now: r.t) {
            case .filling: sawFilling = true
            case .captured(let y, let p): captured = (y, p)
            default: break
            }
        }
        #expect(sawFilling)
        #expect(captured != nil)
        if let c = captured { #expect(abs(c.0 + 0.3) < 0.01) }
    }

    @Test func hintChangesAfterFourSecondsAndItGivesUpAtTwelve() {
        let req = Self.rule.requirement(forTarget: Self.leftDot, on: Self.frame, accepted: [Self.centre])
        var gate = AimGate(requirement: req, startedAt: 0)
        var last = gate.update(now: 0)
        for r in Self.hold(yaw: 0, pitch: 0, seconds: 13) {
            gate.push(r)
            last = gate.update(now: r.t)
            if r.t < 3.9 { #expect(last == .waiting(.turnToDot)) }
            if r.t > 4.1, r.t < 11.9 { #expect(last == .waiting(.moveHead)) }
        }
        #expect(last == .timedOut)
        gate.restart(at: 13)
        #expect(gate.update(now: 13.1) == .waiting(.turnToDot))
    }

    @Test func ringResetsWhenTheHeadDriftsOrTheFaceIsLost() {
        var gate = AimGate(requirement: .stillness, startedAt: 0)
        var filling = false
        for r in Self.hold(yaw: 0, pitch: 0, seconds: 0.8) { gate.push(r); if case .filling = gate.update(now: r.t) { filling = true } }
        #expect(filling)
        // A big move mid-fill sends it back to waiting.
        gate.push(AimReading(t: 0.85, yaw: 0.5, pitch: 0))
        #expect(gate.update(now: 0.85) == .waiting(.turnToDot))
        // Face lost: no readings for a second.
        var lost = AimGate(requirement: .stillness, startedAt: 0)
        for r in Self.hold(yaw: 0, pitch: 0, seconds: 0.8) { lost.push(r); _ = lost.update(now: r.t) }
        #expect(lost.update(now: 2.5) == .waiting(.turnToDot))
    }
}

@Suite struct ScreenLayoutTests {
    static let main = ScreenDescription(name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true)
    static let portrait = ScreenDescription(name: "DELL U2723QE", frame: CGRect(x: -1080, y: -300, width: 1080, height: 1920), isMain: false)
    static let all = [main, portrait]

    @Test func twoScreensAreNamedAndPlaced() {
        #expect(ScreenLayout.headline(count: 2) == "Found 2 screens")
        #expect(ScreenLayout.headline(count: 1) == "Found 1 screen")
        #expect(ScreenLayout.position(of: Self.main, among: Self.all) == "main")
        #expect(ScreenLayout.position(of: Self.portrait, among: Self.all) == "left, portrait")
        #expect(ScreenLayout.detail(of: Self.portrait, among: Self.all) == "1080 \u{00D7} 1920, left, portrait")
        #expect(ScreenLayout.detail(of: Self.main, among: Self.all) == "2560 \u{00D7} 1440, landscape, main")
    }

    @Test func aboveAndRight() {
        let right = ScreenDescription(name: "R", frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080), isMain: false)
        let above = ScreenDescription(name: "A", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isMain: false)
        #expect(ScreenLayout.position(of: right, among: [Self.main, right]) == "right, landscape")
        #expect(ScreenLayout.position(of: above, among: [Self.main, above]) == "above, landscape")
    }

    @Test func stepTitles() {
        #expect(ScreenLayout.stepTitle(index: 1, count: 2, name: "DELL U2723QE", facing: true) == "Screen 2 of 2 \u{00B7} DELL U2723QE \u{00B7} turn to face it")
        #expect(ScreenLayout.stepTitle(index: 0, count: 1, name: "Built-in", facing: false) == "Built-in")
    }

    @Test func calibratedLine() {
        #expect(ScreenLayout.calibratedLine(valid: 2, connected: 2) == "Calibrated for 2 screens")
        #expect(ScreenLayout.calibratedLine(valid: 1, connected: 2) == "Calibrated for 1 of 2 screens")
        #expect(ScreenLayout.calibratedLine(valid: 0, connected: 2) == nil)
    }
}
