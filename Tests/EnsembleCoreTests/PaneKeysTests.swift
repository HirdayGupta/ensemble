import Foundation
import Testing
@testable import EnsembleCore

/// The planner against a simulated Claude row: each press moves only the pair beside its divider and stops at
/// Claude's own minimum, which the planner only estimates.
@Suite struct PaneKeysTests {
    /// Claude's minimum on the owner's Mac: 24 percent of a 1320 pt pair.
    private let claudeMin = 316.0

    /// Plans, runs the presses on the simulated row and returns where the row ends up.
    private func run(_ w: [Double], to target: [Double], estimate: Double? = nil) -> (widths: [Double], presses: [PaneKeys.Press]) {
        let presses = PaneKeys.plan(from: w, to: target, minimum: estimate ?? claudeMin)
        return (PaneKeys.simulate(w, minimum: claudeMin, presses: presses), presses)
    }

    @Test(arguments: [2, 3, 4])
    func maximizeMakesTheSessionAsWideAsClaudeAllowsInEveryPlace(_ n: Int) throws {
        let even = Array(repeating: 2520 / Double(n), count: n)
        for k in 0..<n {
            let target = try #require(PaneKeys.maximizeWidths(even, focus: k, minimum: claudeMin))
            let (w, presses) = run(even, to: target)
            for (i, x) in w.enumerated() {
                if i == k { #expect(abs(x - (2520 - Double(n - 1) * claudeMin)) < 0.001) } else { #expect(abs(x - claudeMin) < 0.001) }
            }
            // One jump per divider, each landing exactly on Claude's limit.
            #expect(presses.count == n - 1)
            #expect(presses.allSatisfy { $0.key == .home || $0.key == .end })
        }
    }

    @Test func widthReachesTheSessionThroughThePanesBetweenOuterFirst() throws {
        let even = [630.0, 630, 630, 630]
        let target = try #require(PaneKeys.maximizeWidths(even, focus: 2, minimum: claudeMin))
        #expect(run(even, to: target).presses == [.init(0, .home), .init(1, .home), .init(2, .end)])
        // The far end of the row holds the width: it is passed along three panes to the other end.
        let skewed = [1572.0, 316, 316, 316]
        let far = try #require(PaneKeys.maximizeWidths(skewed, focus: 3, minimum: claudeMin))
        let (w, presses) = run(skewed, to: far)
        #expect(presses == [.init(0, .home), .init(1, .home), .init(2, .home)])
        #expect(abs(w[3] - 1572) < 0.001)
    }

    @Test func aWrongEstimateOfClaudesMinimumStillLandsOnClaudesOwn() throws {
        let even = [840.0, 840, 840]
        for estimate in [290.0, 340] {
            let target = try #require(PaneKeys.maximizeWidths(even, focus: 1, minimum: estimate))
            let (w, _) = run(even, to: target, estimate: estimate)
            #expect(abs(w[0] - claudeMin) < 0.001 && abs(w[2] - claudeMin) < 0.001)
            #expect(abs(w[1] - (2520 - 2 * claudeMin)) < 0.001)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func evenOutAfterMaximizingReturnsToEqualWidths(_ k: Int) throws {
        let even = [630.0, 630, 630, 630]
        let target = try #require(PaneKeys.maximizeWidths(even, focus: k, minimum: claudeMin))
        let maxed = run(even, to: target).widths
        let (w, presses) = run(maxed, to: try #require(PaneKeys.evenWidths(maxed)))
        for x in w { #expect(abs(x - 630) <= PaneKeys.arrow) }
        // Mid-row moves gain little from a jump (no limit is near); the jumps that do save keys are taken.
        #expect(presses.count <= 45)
        #expect(presses.contains { $0.key == .home || $0.key == .end })
    }

    @Test func maximizingAnotherSessionMovesTheWidthAcross() throws {
        let even = [630.0, 630, 630, 630]
        let first = run(even, to: try #require(PaneKeys.maximizeWidths(even, focus: 0, minimum: claudeMin))).widths
        let (w, _) = run(first, to: try #require(PaneKeys.maximizeWidths(first, focus: 3, minimum: claudeMin)))
        #expect(abs(w[3] - (2520 - 3 * claudeMin)) < 0.001)
        for x in w.prefix(3) { #expect(abs(x - claudeMin) < 0.001) }
    }

    @Test func aSmallMoveGlidesInSteps() {
        // A 104 pt fit: three Shift steps and one arrow, inside the budget.
        let presses = PaneKeys.plan(from: [728, 896], to: [832, 792], minimum: claudeMin)
        #expect(presses.map(\.key) == [.shiftRight, .shiftRight, .shiftRight, .right])
        #expect(PaneKeys.duration(presses) <= PaneKeys.animateBudget)
        #expect(abs(PaneKeys.simulate([728, 896], minimum: claudeMin, presses: presses)[0] - 832) <= PaneKeys.arrow / 2)
    }

    @Test func aLongMoveJumpsThenSteps() {
        // 2020 pt in a two-pane row: a glide would need 64 keys; End then two Shift steps back is three.
        let presses = PaneKeys.plan(from: [400, 2400], to: [2420, 380], minimum: claudeMin)
        #expect(presses.map(\.key) == [.end, .shiftLeft, .shiftLeft])
        let w = PaneKeys.simulate([400, 2400], minimum: claudeMin, presses: presses)
        #expect(abs(w[0] - 2420) <= PaneKeys.arrow / 2)
        // A move that ends on a limit is one key, however far.
        #expect(PaneKeys.plan(from: [1260, 1260], to: [316, 2204], minimum: claudeMin) == [.init(0, .home)])
    }

    @Test func aFitPlanReachesTheChatColumn() throws {
        let row = [630.0, 630, 630, 630]
        let fit = try #require(SessionFit.widths(current: row, focus: 1, width: 832))
        let (w, presses) = run(row, to: fit)
        #expect(abs(w[1] - 832) <= PaneKeys.arrow)
        #expect(abs(w.reduce(0, +) - 2520) < 0.001)
        #expect(presses.count <= 12)
    }

    @Test func nothingToDoIsNoPresses() {
        #expect(PaneKeys.plan(from: [850, 850, 850], to: [852, 849, 849], minimum: claudeMin).isEmpty)
    }

    @Test func badInputPlansNothing() {
        #expect(PaneKeys.plan(from: [850, 850], to: [850, 850, 850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, 850], to: [800, 800], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, .nan], to: [850, 850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850], to: [850], minimum: claudeMin).isEmpty)
        #expect(PaneKeys.plan(from: [850, 850], to: [900, 800], minimum: .nan).isEmpty)
        #expect(PaneKeys.maximizeWidths([850, 850], focus: 2, minimum: claudeMin) == nil)
        // Too narrow a window to leave the others at Claude's minimum: nothing to plan.
        #expect(PaneKeys.maximizeWidths([300, 300, 300], focus: 0, minimum: claudeMin) == nil)
        #expect(PaneKeys.evenWidths([850]) == nil)
    }

    @Test func claudesMinimumIsReadFromTheDividers() {
        // Measured: pairs of 1320 and 1256 pt reporting 24 and 26 percent.
        #expect(abs(PaneKeys.minimum(pairWidths: [1320, 1256], minPercents: [24, 26]) - 326.56) < 0.01)
        #expect(PaneKeys.minimum(pairWidths: [1320], minPercents: [nil]) == PaneKeys.fallbackMinimum)
        #expect(PaneKeys.minimum(pairWidths: [1320], minPercents: [0]) == PaneKeys.fallbackMinimum)
    }

    @Test func stepsRoundToTheNearestArrow() {
        #expect(PaneKeys.stepKeys(40) == [.shiftRight, .right])
        #expect(PaneKeys.stepKeys(-60) == [.shiftLeft, .shiftLeft])
        #expect(PaneKeys.stepKeys(3) == [])
    }

    @Test func homeAndEndStopAtClaudesMinimum() {
        let w = PaneKeys.simulate([800, 800], minimum: 316, presses: [.init(0, .end)])
        #expect(w == [1284, 316])
        #expect(PaneKeys.simulate(w, minimum: 316, presses: [.init(0, .right)]) == [1284, 316])
        // A divider that does not exist moves nothing.
        #expect(PaneKeys.simulate(w, minimum: 316, presses: [.init(3, .home)]) == w)
    }
}
