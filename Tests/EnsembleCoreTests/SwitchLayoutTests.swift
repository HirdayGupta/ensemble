import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct SwitchLayoutTests {
    @Test func oneColumnFillsTheWholeWidth() {
        let cols = SwitchLayout.columns(count: 1, groupBreaks: [], width: 40)
        #expect(cols == [SessionColumn(x: 0, width: 40)])
    }

    @Test func columnsSitLeftToRightWithoutOverlap() {
        let cols = SwitchLayout.columns(count: 3, groupBreaks: [], width: 60)
        #expect(cols.count == 3)
        for i in 1..<cols.count { #expect(cols[i].x >= cols[i - 1].x + cols[i - 1].width) }
    }

    @Test func columnsNeverOverflowTheGivenWidth() {
        for count in [1, 2, 5, 10, 11, 25, 60] {
            for width: CGFloat in [10, 26, 56, 64, 120, 360] {
                let cols = SwitchLayout.columns(count: count, groupBreaks: [], width: width)
                guard let last = cols.last else { continue }
                #expect(last.x + last.width <= width + 0.001, "count \(count) width \(width)")
            }
        }
    }

    @Test func upToTenColumnsStayAtFullSpacingWhenThereIsRoom() {
        let cols = SwitchLayout.columns(count: SwitchLayout.legibleColumns, groupBreaks: [], width: 200)
        let spacing = cols[1].x - (cols[0].x + cols[0].width)
        #expect(abs(spacing - 3) < 0.001)
    }

    @Test func pastTenColumnsSpacingCompressesBeforeColumnWidthDoes() {
        let roomy = SwitchLayout.columns(count: 10, groupBreaks: [], width: 60)
        let crowded = SwitchLayout.columns(count: 20, groupBreaks: [], width: 60)
        let roomySpacing = roomy[1].x - (roomy[0].x + roomy[0].width)
        let crowdedSpacing = crowded[1].x - (crowded[0].x + crowded[0].width)
        #expect(crowdedSpacing < roomySpacing)
        #expect(crowded.last!.x + crowded.last!.width <= 60.001)
    }

    @Test func aGroupBreakIsAWiderGapThanARegularOne() {
        let cols = SwitchLayout.columns(count: 4, groupBreaks: [2], width: 80)
        let regularGap = cols[1].x - (cols[0].x + cols[0].width)
        let groupGap = cols[2].x - (cols[1].x + cols[1].width)
        let otherRegularGap = cols[3].x - (cols[2].x + cols[2].width)
        #expect(groupGap > regularGap)
        #expect(abs(regularGap - otherRegularGap) < 0.001)
    }

    @Test func groupBreaksOutsideRangeAreIgnored() {
        let withJunkBreaks = SwitchLayout.columns(count: 3, groupBreaks: [0, 3, 99], width: 60)
        let withNoBreaks = SwitchLayout.columns(count: 3, groupBreaks: [], width: 60)
        #expect(withJunkBreaks == withNoBreaks)
    }

    @Test func zeroCountOrWidthProducesNoColumns() {
        #expect(SwitchLayout.columns(count: 0, groupBreaks: [], width: 60).isEmpty)
        #expect(SwitchLayout.columns(count: 3, groupBreaks: [], width: 0).isEmpty)
    }

    @Test func litColumnSitsOverFromAtZeroProgressAndToAtOneProgress() {
        let cols = SwitchLayout.columns(count: 3, groupBreaks: [], width: 60)
        #expect(SwitchLayout.litColumn(from: 0, to: 2, progress: 0, in: cols) == cols[0])
        #expect(SwitchLayout.litColumn(from: 0, to: 2, progress: 1, in: cols) == cols[2])
    }

    @Test func litColumnAtHalfProgressSitsBetweenTheTwo() {
        let cols = SwitchLayout.columns(count: 3, groupBreaks: [], width: 60)
        let mid = SwitchLayout.litColumn(from: 0, to: 2, progress: 0.5, in: cols)!
        #expect(abs(mid.x - (cols[0].x + cols[2].x) / 2) < 0.001)
    }

    @Test func litColumnClampsProgressAndIndicesOutOfRange() {
        let cols = SwitchLayout.columns(count: 3, groupBreaks: [], width: 60)
        #expect(SwitchLayout.litColumn(from: -5, to: 50, progress: 2, in: cols) == cols[2])
        #expect(SwitchLayout.litColumn(from: -5, to: 50, progress: -2, in: cols) == cols[0])
    }

    @Test func litColumnIsNilWithNoColumns() {
        #expect(SwitchLayout.litColumn(from: 0, to: 0, progress: 0.5, in: []) == nil)
    }
}
