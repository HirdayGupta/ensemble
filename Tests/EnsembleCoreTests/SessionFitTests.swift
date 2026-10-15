import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct SessionFitTests {
    @Test func theNarrowPaneReachesTheColumnAndTheOthersGiveEqually() throws {
        let w = try #require(SessionFit.widths(current: [400, 800, 800], focus: 0, width: 840))
        #expect(w == [840, 580, 580])
    }

    @Test func aPaneAlreadyWideEnoughIsLeftAlone() {
        #expect(SessionFit.widths(current: [900, 800, 800], focus: 0, width: 840) == nil)
        #expect(SessionFit.widths(current: [836, 800], focus: 0, width: 840) == nil)
    }

    @Test func noPaneGoesBelowTheMinimumAndTheRestShareWhatIsLeft() throws {
        // The middle pane can give 50; the last gives the remaining 350.
        let w = try #require(SessionFit.widths(current: [440, 350, 1000], focus: 0, width: 840))
        #expect(w == [840, 300, 650])
    }

    @Test func whenTheOthersRunOutThePaneGetsWhatTheyHave() throws {
        let w = try #require(SessionFit.widths(current: [300, 400, 400], focus: 0, width: 840))
        #expect(w == [500, 300, 300])
        #expect(SessionFit.widths(current: [300, 300, 300], focus: 1, width: 840) == nil)
    }

    @Test func badInputPlansNothing() {
        #expect(SessionFit.widths(current: [400], focus: 0, width: 840) == nil)
        #expect(SessionFit.widths(current: [400, 800], focus: 2, width: 840) == nil)
        #expect(SessionFit.widths(current: [400, .nan], focus: 0, width: 840) == nil)
    }

    @Test func theFitPlanSettlesOnARowLikeClaudes() throws {
        // Four 630 pt panes 10 pt apart, the second widened to 832: the others end up equal.
        let panes = [0.0, 640, 1280, 1920].map { CGRect(x: $0, y: 30, width: 630, height: 1300) }
        let dividers = [635.0, 1275, 1915]
        let (widths, _) = PaneWidths.layout(panes: panes, dividers: dividers)
        #expect(widths == [630, 630, 630, 630])
        let fit = try #require(SessionFit.widths(current: widths, focus: 1, width: 832))
        #expect(abs(fit[1] - 832) < 0.001)
        #expect(abs(fit[0] - fit[2]) < 0.001 && abs(fit[2] - fit[3]) < 0.001)
        #expect(abs(fit.reduce(0, +) - 2520) < 0.001)
    }

    @Test func theTriggerFiresOnceAfterFocusSettles() {
        var t = SessionFit.Trigger()
        #expect(t.observe("a", at: 0) == nil)
        #expect(t.observe("a", at: 0.5) == nil)
        #expect(t.observe("a", at: 0.6) == "a")
        #expect(t.observe("a", at: 2) == nil)
    }

    @Test func passingOverASessionNeverFitsIt() {
        var t = SessionFit.Trigger()
        #expect(t.observe("a", at: 0) == nil)
        #expect(t.observe("b", at: 0.3) == nil)
        #expect(t.observe("a", at: 0.7) == nil)
        #expect(t.observe(nil, at: 1.0) == nil)
        #expect(t.observe(nil, at: 5) == nil)
        #expect(t.observe("b", at: 5.1) == nil)
        #expect(t.observe("b", at: 5.7) == "b")
    }

    @Test func comingBackToASessionIsANewFocusChange() {
        var t = SessionFit.Trigger()
        _ = t.observe("a", at: 0)
        #expect(t.observe("a", at: 1) == "a")
        _ = t.observe("b", at: 2)
        _ = t.observe("a", at: 3)
        #expect(t.observe("a", at: 3.6) == "a")
    }
}

@Suite struct ChatColumnTests {
    let transcript = CGRect(x: 100, y: 40, width: 1200, height: 1200)

    @Test func theCentredColumnInAWidePaneIsRead() {
        let column = CGRect(x: 100 + (1200 - 832) / 2, y: 60, width: 832, height: 400)
        let text = CGRect(x: column.minX + 32, y: 60, width: 768, height: 100)
        let row = CGRect(x: 100, y: 60, width: 1200, height: 400)
        #expect(ChatColumn.measure(transcript: transcript, elements: [row, column, text]) == 832)
    }

    @Test func aPaneNarrowerThanTheColumnShowsNone() {
        let narrow = CGRect(x: 0, y: 40, width: 700, height: 1200)
        let text = CGRect(x: 32, y: 60, width: 636, height: 100)
        #expect(ChatColumn.measure(transcript: narrow, elements: [narrow, text]) == nil)
    }

    @Test func offCentreOrOddSizedElementsAreNotTheColumn() {
        let card = CGRect(x: 120, y: 60, width: 700, height: 100)
        let bubble = CGRect(x: 100 + (1200 - 500) / 2, y: 60, width: 500, height: 100)
        #expect(ChatColumn.measure(transcript: transcript, elements: [card, bubble]) == nil)
    }

    @Test func thePaneWidthAddsWhatSitsBesideTheTranscript() {
        let pane = CGRect(x: 0, y: 30, width: 600, height: 1300)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: CGRect(x: 4, y: 40, width: 592, height: 1200)) == 840)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: nil) == 832)
        #expect(ChatColumn.paneWidth(column: 832, pane: pane, transcript: CGRect(x: 0, y: 40, width: 900, height: 10)) == 832)
    }

    @Test func memoryKeepsTheLatestReadingAndFallsBack() {
        var m = ChatColumn.Memory()
        #expect(m.width == SessionFit.fallbackColumn)
        m.note([nil, nil])
        #expect(m.measured == nil)
        m.note([nil, 1024, 832])
        #expect(m.width == 1024)
        m.note([832])
        #expect(m.width == 832)
    }

    @Test func explicitWidthsAreAGoalTheRowSettlesOn() {
        #expect(PaneWidths.targets(count: 3, available: 1800, goal: .widths([840, 480, 480])) == [840, 480, 480])
        #expect(PaneWidths.targets(count: 2, available: 1800, goal: .widths([840, 480, 480])) == [])
    }
}
