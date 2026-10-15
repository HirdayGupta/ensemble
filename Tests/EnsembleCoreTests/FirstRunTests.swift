import Testing
@testable import EnsembleCore

@Suite struct FirstRunTests {
    @Test func newOwnerDefersStartUntilTourSettles() {
        #expect(FirstRunGate.shouldDeferStart(tourCompleted: false, tourSkipped: false))
        #expect(!FirstRunGate.shouldDeferStart(tourCompleted: true, tourSkipped: false))
        #expect(!FirstRunGate.shouldDeferStart(tourCompleted: false, tourSkipped: true))
    }

    @Test func onlyWelcomeWaits() {
        #expect(!FirstRunGate.stepNeedsCoordinator(.welcome))
        for step in TourStep.allCases where step != .welcome {
            #expect(FirstRunGate.stepNeedsCoordinator(step))
        }
    }

    @Test func cameraAccessGrantedOnlyWhenGranted() {
        #expect(CameraAccess.granted.isGranted)
        #expect(!CameraAccess.notAsked.isGranted)
        #expect(!CameraAccess.denied.isGranted)
    }

    @Test func temporaryLocations() {
        let home = "/Users/sam"
        #expect(InstallLocation.isTemporary(bundlePath: "/private/var/folders/ab/T/AppTranslocation/1234/d/Ensemble.app", home: home))
        #expect(InstallLocation.isTemporary(bundlePath: "/Volumes/Ensemble/Ensemble.app", home: home))
        #expect(InstallLocation.isTemporary(bundlePath: "/Users/sam/Downloads/Ensemble.app", home: home))
        #expect(InstallLocation.isTemporary(bundlePath: "/Users/sam/Downloads/Ensemble 1/Ensemble.app", home: home))
    }

    @Test func settledLocations() {
        let home = "/Users/sam"
        #expect(!InstallLocation.isTemporary(bundlePath: "/Applications/Ensemble.app", home: home))
        #expect(!InstallLocation.isTemporary(bundlePath: "/Users/sam/Applications/Ensemble.app", home: home))
        #expect(!InstallLocation.isTemporary(bundlePath: "/Users/sam/Desktop/Ensemble.app", home: home))
        #expect(!InstallLocation.isTemporary(bundlePath: "/Users/sam/Downloadsx/Ensemble.app", home: home))
        // A SwiftPM debug build is never offered a move.
        #expect(!InstallLocation.isTemporary(bundlePath: "/Users/sam/Downloads/repo/.build/debug", home: home))
        #expect(!InstallLocation.isTemporary(bundlePath: "/Users/sam/Downloads/repo/.build/arm64/Ensemble.app", home: home))
    }
}
