import CoreGraphics
import Testing
@testable import EnsembleCore

/// A dictation running in Claude that Ensemble did not start (2026-10-15: the double pinch was refused with
/// "mic is not verifiably off: on" and every thumbs-up with "Nothing dictated in the last 30 seconds").
@Suite struct ClaudeDictationTests {
    @Test func theDoublePinchStopsADictationClaudeIsRunning() {
        #expect(ClaudeDictation.talkStep(target: .on) == .stopRunning)
    }

    @Test func theDoublePinchStartsOnlyWhenTheMicrophoneIsVerifiablyOff() {
        #expect(ClaudeDictation.talkStep(target: .off) == .start)
        // An unclear state is never pressed: a press would start a microphone that is off.
        guard case .refuse(let why) = ClaudeDictation.talkStep(target: .unknown("checkbox says recording but Claude is not capturing audio")) else {
            Issue.record("an unclear microphone must refuse"); return
        }
        #expect(why.contains("nothing pressed"))
    }

    @Test func aSendWhileClaudeDictatesStopsFirst() {
        #expect(ClaudeDictation.sendStep(target: .on) == .stopThenSend)
        #expect(ClaudeDictation.sendStep(target: .off) == .sendDictated)
        #expect(ClaudeDictation.sendStep(target: .unknown("unreadable")) == .sendDictated)
    }

    @Test func aStartPressThatFindsTheMicrophoneOnSaysHowToStopIt() {
        #expect(ClaudeDictation.startRefusal(.on) == "Claude is already dictating here; pinch twice to stop")
        #expect(ClaudeDictation.startRefusal(.off) == nil)
        #expect(ClaudeDictation.startRefusal(.unknown("x"))?.hasPrefix("Claude's microphone reads neither on nor off") == true)
    }
}

@Suite struct ForeignDictationsTests {
    @Test func aDictationSeenToEndCountsFromWhenItEnded() {
        var f = ForeignDictations()
        f.observe(present: ["a", "b"], recordingNow: ["a"], at: 100)
        #expect(f.isRecording("a"))
        #expect(f.endedAgo("a", now: 101) == nil)
        f.observe(present: ["a", "b"], recordingNow: [], at: 105)
        #expect(!f.isRecording("a"))
        #expect(f.endedAgo("a", now: 110) == 5)
        #expect(f.endedAgo("b", now: 110) == nil)
    }

    @Test func aDictationNeverSeenRecordingIsNotDictated() {
        var f = ForeignDictations()
        f.observe(present: ["a"], recordingNow: [], at: 1)
        f.observe(present: ["a"], recordingNow: [], at: 2)
        #expect(f.endedAgo("a", now: 3) == nil)
    }

    @Test func recordingAgainClearsTheEnd() {
        var f = ForeignDictations()
        f.observe(present: ["a"], recordingNow: ["a"], at: 1)
        f.observe(present: ["a"], recordingNow: [], at: 2)
        f.observe(present: ["a"], recordingNow: ["a"], at: 3)
        #expect(f.isRecording("a"))
        #expect(f.endedAgo("a", now: 4) == nil)
    }

    @Test func aSessionThatLeavesTheListTakesItsHistoryAlong() {
        var f = ForeignDictations()
        f.observe(present: ["a"], recordingNow: ["a"], at: 1)
        f.observe(present: ["b"], recordingNow: [], at: 2)    // a layout change: "a" is gone, not ended
        #expect(!f.isRecording("a"))
        #expect(f.endedAgo("a", now: 3) == nil)
        f.observe(present: ["a"], recordingNow: [], at: 4)    // the same id again may name another pane
        #expect(f.endedAgo("a", now: 5) == nil)
    }

    @Test func forgettingEndsWhatWasSeen() {
        var f = ForeignDictations()
        f.observe(present: ["a", "b"], recordingNow: ["a", "b"], at: 1)
        f.observe(present: ["a", "b"], recordingNow: [], at: 2)
        f.forget("a")
        #expect(f.endedAgo("a", now: 3) == nil)
        #expect(f.endedAgo("b", now: 3) == 1)
        f.forgetAll()
        #expect(f.endedAgo("b", now: 3) == nil)
        #expect(!f.isRecording(nil))
    }
}

@Suite struct SendSourceTests {
    @Test func theMostRecentDictationWithinTheWindowIsSent() {
        #expect(SendRules.dictated(ensembleAgo: nil, claudeAgo: nil) == nil)
        #expect(SendRules.dictated(ensembleAgo: 5, claudeAgo: nil)?.source == .ensemble)
        #expect(SendRules.dictated(ensembleAgo: nil, claudeAgo: 4)?.source == .claude)
        #expect(SendRules.dictated(ensembleAgo: nil, claudeAgo: 4)?.ago == 4)
        #expect(SendRules.dictated(ensembleAgo: 10, claudeAgo: 3)?.source == .claude)
        #expect(SendRules.dictated(ensembleAgo: 3, claudeAgo: 10)?.source == .ensemble)
        #expect(SendRules.dictated(ensembleAgo: 3, claudeAgo: 3)?.source == .ensemble)
    }

    @Test func aDictationOlderThanTheWindowNeverCounts() {
        #expect(SendRules.dictated(ensembleAgo: 31, claudeAgo: nil) == nil)
        #expect(SendRules.dictated(ensembleAgo: nil, claudeAgo: 30.5) == nil)
        #expect(SendRules.dictated(ensembleAgo: 40, claudeAgo: 20)?.source == .claude)
    }
}

/// 2026-10-15 15:12:25: a dictation into a lone pane at 1289,39 630x1309 stopped; a second later Claude showed four
/// panes and the send read a pane at 1280,30 640x1327: "The draft is empty".
@Suite struct SessionMatchTests {
    let dictated = ClaudeSession(id: "w11#0", frame: CGRect(x: 1289, y: 39, width: 630, height: 1309), windowNumber: 11, title: "Plan")

    @Test func anotherWindowsPaneAtTheSamePlaceIsNotTheSession() {
        let other = ClaudeSession(id: "w12#2", frame: CGRect(x: 1280, y: 30, width: 640, height: 1327), windowNumber: 12, title: "Plan")
        #expect(!SessionMatch.same(dictated, other))
        #expect(SessionMatch.pick(dictated, among: [other]) == nil)
    }

    @Test func theSameIdInAnotherPlaceIsNotTheSession() {
        // One window went from one pane to four: its first checkbox is now the leftmost pane.
        let moved = ClaudeSession(id: "w11#0", frame: CGRect(x: 0, y: 30, width: 640, height: 1327), windowNumber: 11, title: "Plan")
        #expect(!SessionMatch.same(dictated, moved))
    }

    @Test func theSamePaneUnderANewIdIsFound() {
        let panes = [
            ClaudeSession(id: "w11#0", frame: CGRect(x: 0, y: 30, width: 640, height: 1327), windowNumber: 11, title: "Notes"),
            ClaudeSession(id: "w11#1", frame: CGRect(x: 640, y: 30, width: 640, height: 1327), windowNumber: 11, title: "Docs"),
            ClaudeSession(id: "w11#2", frame: CGRect(x: 1280, y: 30, width: 640, height: 1327), windowNumber: 11, title: "Plan"),
        ]
        #expect(SessionMatch.pick(dictated, among: panes) == 2)
    }

    @Test func aDifferentTitleAtTheSamePlaceIsNotTheSession() {
        let renamed = ClaudeSession(id: "w11#0", frame: dictated.frame, windowNumber: 11, title: "Other")
        #expect(!SessionMatch.same(dictated, renamed))
        let unread = ClaudeSession(id: "w11#0", frame: dictated.frame, windowNumber: 11, title: nil)
        #expect(SessionMatch.same(dictated, unread))
    }

    @Test func itsOwnIdWinsWhenSeveralPass() {
        let a = ClaudeSession(id: "w11#3", frame: dictated.frame, windowNumber: 11, title: nil)
        let b = ClaudeSession(id: "w11#0", frame: dictated.frame.insetBy(dx: 10, dy: 10), windowNumber: 11, title: "Plan")
        #expect(SessionMatch.pick(dictated, among: [a, b]) == 1)
    }
}
