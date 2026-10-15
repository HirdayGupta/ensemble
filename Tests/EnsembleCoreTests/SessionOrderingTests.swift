import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct SessionOrderingTests {
    private let leftScreen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let rightScreen = CGRect(x: 1000, y: 0, width: 1000, height: 1000)

    private func session(_ id: String, x: CGFloat, window: Int) -> ClaudeSession {
        ClaudeSession(id: id, frame: CGRect(x: x, y: 0, width: 100, height: 100), windowNumber: window)
    }

    @Test func sessionsOnOneScreenSortLeftToRightByX() {
        let b = session("B", x: 600, window: 1), a = session("A", x: 100, window: 1), c = session("C", x: 300, window: 1)
        let ordered = SessionOrdering.ordered([b, a, c], screens: [leftScreen])
        #expect(ordered.map(\.session.id) == ["A", "C", "B"])
        #expect(ordered.map(\.group) == [0, 0, 0])
    }

    @Test func screensOrderBeforeXWithinEachScreen() {
        let rightFar = session("R1", x: 1900, window: 1)
        let rightNear = session("R2", x: 1050, window: 1)
        let leftOne = session("L1", x: 500, window: 1)
        let ordered = SessionOrdering.ordered([rightFar, leftOne, rightNear], screens: [leftScreen, rightScreen])
        #expect(ordered.map(\.session.id) == ["L1", "R2", "R1"])
    }

    @Test func crossingToAnotherScreenStartsANewGroup() {
        let l = session("L", x: 500, window: 1)
        let r = session("R", x: 1500, window: 1)
        let ordered = SessionOrdering.ordered([l, r], screens: [leftScreen, rightScreen])
        #expect(ordered.map(\.group) == [0, 1])
    }

    @Test func separateWindowsOnTheSameScreenAlsoStartANewGroup() {
        let w1a = session("W1A", x: 100, window: 1)
        let w1b = session("W1B", x: 200, window: 1)
        let w2 = session("W2", x: 300, window: 2)
        let ordered = SessionOrdering.ordered([w1a, w1b, w2], screens: [leftScreen])
        #expect(ordered.map(\.session.id) == ["W1A", "W1B", "W2"])
        #expect(ordered.map(\.group) == [0, 0, 1])
    }

    @Test func aSessionOutsideEveryScreenSortsLast() {
        let onScreen = session("ON", x: 500, window: 1)
        let offScreen = session("OFF", x: -5000, window: 1)
        let ordered = SessionOrdering.ordered([offScreen, onScreen], screens: [leftScreen])
        #expect(ordered.map(\.session.id) == ["ON", "OFF"])
    }

    @Test func emptyInputsProduceNoOrdering() {
        #expect(SessionOrdering.ordered([], screens: [leftScreen]).isEmpty)
    }
}
