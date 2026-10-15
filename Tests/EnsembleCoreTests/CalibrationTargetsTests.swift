import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct CalibrationTargetsTests {
    @Test func edgeDotsSitFourPercentInOnALargeScreen() {
        let frame = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let points = CalibrationTargets.points(in: frame)
        #expect(points.count == 5)
        #expect(points[0] == CGPoint(x: -1280, y: 720))
        #expect(abs(points[1].x - (-2560 + 102.4)) < 0.001)
        #expect(abs(points[2].x - (-102.4)) < 0.001)
        #expect(abs(points[3].y - 57.6) < 0.001)
        #expect(abs(points[4].y - (1440 - 57.6)) < 0.001)
    }

    @Test func everyDotIsDrawnWholeOnASmallScreen() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        for p in CalibrationTargets.points(in: frame) {
            #expect(p.x - frame.minX >= CalibrationTargets.dotRadius && frame.maxX - p.x >= CalibrationTargets.dotRadius)
            #expect(p.y - frame.minY >= CalibrationTargets.dotRadius && frame.maxY - p.y >= CalibrationTargets.dotRadius)
        }
    }

    @Test func theTopDotClearsTheMenuBarAndNotch() {
        // A notched laptop: 1512 x 982 points, 38 points of menu bar and notch at the top.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let top = CalibrationTargets.points(in: frame, topReserve: 38)[3]
        #expect(top.y - CalibrationTargets.dotRadius >= 38)
        // Where 4% is already clear of it, the reserve changes nothing.
        let large = CGRect(x: 0, y: 0, width: 2560, height: 2880)
        #expect(abs(CalibrationTargets.points(in: large, topReserve: 24)[3].y - 115.2) < 0.001)
    }
}
