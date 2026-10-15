import Testing
@testable import EnsembleCore

@Suite struct ResizeKeysTests {
    @Test func theKeyboardGoesBackOnlyFromADivider() {
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: true, keyboardOnDivider: true) == .now)
    }

    @Test func aBoxYouClickedIntoKeepsTheKeyboard() {
        // A cancelled resize after you clicked into another session's message box leaves the keyboard there.
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: true, keyboardOnDivider: false) == .leave)
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: true, keyboardOnDivider: nil) == .leave)
    }

    @Test func aDividerAskedButNeverPressedIsStillPutBack() {
        // No key was pressed, but the divider may have taken the keyboard: the flag, not a key, decides.
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: true, keyboardOnDivider: true) == .now)
        #expect(ResizeKeys.refocus(askedDivider: false, claudeInFront: true, keyboardOnDivider: true) == .leave)
    }

    @Test func claudeLeavingTheFrontWaitsForItToReturn() {
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: false, keyboardOnDivider: true) == .whenClaudeReturns)
        #expect(ResizeKeys.refocus(askedDivider: true, claudeInFront: false, keyboardOnDivider: nil) == .whenClaudeReturns)
        #expect(ResizeKeys.refocus(askedDivider: false, claudeInFront: false, keyboardOnDivider: true) == .leave)
    }

    @Test func yourKeysAreHeldWhileAResizeRunsAndEnsemblesPass() {
        #expect(ResizeKeys.holds(resizing: true, ownKey: false))
        #expect(!ResizeKeys.holds(resizing: true, ownKey: true))
        #expect(!ResizeKeys.holds(resizing: false, ownKey: false))
    }

    @Test func heldKeysNeverReachADivider() {
        #expect(ResizeKeys.replayHeld(claudeInFront: true, keyboardOnDivider: false))
        #expect(!ResizeKeys.replayHeld(claudeInFront: true, keyboardOnDivider: true))
        #expect(!ResizeKeys.replayHeld(claudeInFront: true, keyboardOnDivider: nil))
        #expect(ResizeKeys.replayHeld(claudeInFront: false, keyboardOnDivider: true))
    }
}
