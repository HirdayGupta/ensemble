import AppKit
import EnsembleCore

/// Peace sign and scissors: resizes the session panes of the Claude window you are facing with Claude's own keyboard
/// control of the dividers between them. Maximize makes the session you look at as wide as Claude allows and every
/// other pane in its row as narrow; evening out gives each the same width. Focus settling on a pane narrower than
/// Claude's chat column widens it to the column the same way (`autoFit`), unless Settings turns it off.
///
/// A divider is given keyboard focus through Accessibility and moved with arrows, Shift and arrows, Home and End
/// (`PaneKeys` plans which), posted through the session event tap to Claude in front. The pointer never moves.
/// Before every key it checks that Claude is still in front with that divider holding its keyboard, that no
/// dictation, send or Return watch is running, and that the keyboard, mouse and trackpad are untouched; otherwise
/// nothing more is pressed. Afterwards the keyboard goes back to the session's message box, and the session frames
/// are read again during and after, so the highlight follows the pane.
@MainActor
final class PaneWidthController {
    private let ctx: CoordinatorContext
    /// A send is between its request and its result, or waits for a stop: no key may be pressed.
    var sendBusy: () -> Bool = { false }
    /// The Return watch is on (a dictation, or just after one): it would see Ensemble's keys.
    var keyWatchOn: () -> Bool = { false }
    /// The session frames were read again: the highlight is moved to them.
    var framesChanged: () -> Void = {}
    private(set) var isRunning = false
    private var cancelled = false
    /// When this resize began, for the hand-on-the-keyboard-or-mouse check, and whether it has pressed any key.
    private var startedAt: TimeInterval = 0
    private var pressedAny = false
    private var refreshInFlight = false

    /// Plan, press, read back: the second pass corrects what Claude's rounding or a lost key left.
    private static let passes = 2
    /// Claude's frames show a key about 170 ms after it (measured 2026-10-15); the read-back waits this long.
    private static let settle: UInt64 = 220_000_000
    /// Frames are read again after this many keys while a glide runs.
    private static let refreshEvery = 6

    /// Claude's chat column, as last measured from a pane wide enough to show it.
    private var column = ChatColumn.Memory()

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    /// Stops the running resize only: each run clears it as it ends, or `blocker` would refuse every later fit and
    /// peace sign as "interrupted" until Ensemble restarts.
    func cancel() { if isRunning { cancelled = true } }

    func request(_ maximize: Bool, target: ClaudeSession?) {
        let what = maximize ? "Maximize" : "Even out"
        guard !isRunning else { return }
        if let why = ctx.commonRefusal() { ctx.refuse(why, title: what); return }
        guard let target else { ctx.refuse("Look at a Claude session first", title: what, resolves: .whenOnSession); return }
        if let why = blocker() { ctx.refuse(why, title: what); return }
        begin()
        EnsembleLog.write("pane widths: \(maximize ? "maximize" : "even out") around \(place(of: target))")
        Task { @MainActor in
            let outcome = await self.run(target: target) { widths, k, minimum, _ in
                maximize ? PaneKeys.maximizeWidths(widths, focus: k, minimum: minimum) : PaneKeys.evenWidths(widths)
            }
            await self.end(target)
            EnsembleLog.write("pane widths: \(outcome)")
            if let refusal = outcome.refusal { self.ctx.refuse(refusal, title: what) }
        }
    }

    /// Focus has settled on `target`: widen it to Claude's chat column if it is narrower, taking the width equally
    /// from the other panes in its row. Silent: it is not something you asked for, so it never shows a refusal;
    /// anything in the way (a dictation, a send, your hands on the keyboard or mouse, another app in front) skips it.
    func autoFit(_ target: ClaudeSession) {
        guard !isRunning else { return }
        if let why = ctx.commonRefusal() ?? blocker() { EnsembleLog.write("pane widths: no fit (\(why))"); return }
        if ClaudeBridge.secondsSincePhysicalInput() < CoordinatorContext.inputQuiet {
            EnsembleLog.write("pane widths: no fit (the keyboard or mouse is in use)")
            return
        }
        let row = PaneWidths.row(of: target, in: ctx.sessions)
        guard row.count >= 2 else { return }
        begin()
        Task { @MainActor in
            let readings = await self.ctx.bridge.chatColumns(in: row)
            self.column.note(row.map { readings[$0.id]?.column })
            let column = self.column.width
            let outcome = await self.run(target: target) { widths, k, minimum, frames in
                let want = ChatColumn.paneWidth(column: column, pane: frames[k], transcript: readings[target.id]?.transcript)
                return SessionFit.widths(current: widths, focus: k, width: want, minimum: max(PaneWidths.narrowWidth, minimum))
            }
            await self.end(target)
            if case .done(presses: 0) = outcome { return }
            EnsembleLog.write("pane widths: fit \(self.place(of: target)) to the chat column "
                              + "(\(Int(column)) pt, \(self.column.measured == nil ? "default" : "measured")): \(outcome)")
        }
    }

    private enum Outcome: CustomStringConvertible {
        case done(presses: Int)
        case stopped(String)
        case refused(String)
        var refusal: String? { if case .refused(let why) = self { return why }; return nil }
        var description: String {
            switch self {
            case .done(let n): return "done after \(n) key\(n == 1 ? "" : "s")"
            case .stopped(let why): return "stopped: \(why)"
            case .refused(let why): return "refused: \(why)"
            }
        }
    }

    private func begin() {
        isRunning = true
        cancelled = false
        pressedAny = false
        startedAt = CACurrentMediaTime()
    }

    /// The keyboard goes back to the session's message box (a divider keeps it otherwise), and the frames are read
    /// again once Claude has drawn the last key. Clears `cancelled` so one interrupted resize never blocks the next.
    private func end(_ target: ClaudeSession) async {
        if pressedAny {
            EnsembleLog.write("pane widths: \(await ctx.bridge.focusComposerIfNeeded(target))")
            refreshFrames()
            try? await Task.sleep(nanoseconds: Self.settle)
            refreshFrames()
        }
        pressedAny = false
        isRunning = false
        cancelled = false
    }

    /// Plans and presses toward the widths `goal` asks for. `goal` gets the row's pane widths, the target's index,
    /// Claude's minimum pane width and the panes' frames, and answers nil when there is nothing to do.
    private func run(target: ClaudeSession, goal: ([Double], Int, Double, [CGRect]) -> [Double]?) async -> Outcome {
        var total = 0
        for pass in 0..<Self.passes {
            let sessions = await ctx.bridge.refreshSessions().sessions
            if !sessions.isEmpty { ctx.sessions = sessions; framesChanged() }
            let row = PaneWidths.row(of: sessions.first { $0.id == target.id } ?? target, in: sessions)
            guard row.count >= 2, let k = row.firstIndex(where: { $0.id == target.id }) else {
                return pass == 0 ? .refused("Only one session in this window") : .stopped("the sessions changed")
            }
            let found = await ctx.bridge.paneDividers(in: target)
            let xs = PaneWidths.dividers(between: row.map(\.frame), splitters: found.map(\.frame))
            let dividers = (xs ?? []).compactMap { x in found.first { abs(Double($0.frame.midX) - x) < 0.5 } }
            guard let xs, dividers.count == xs.count else {
                return pass == 0 ? .refused("Claude's pane dividers were not found") : .stopped("the dividers changed")
            }
            let widths = PaneWidths.layout(panes: row.map(\.frame), dividers: xs).widths
            let pairs = (0..<(widths.count - 1)).map { widths[$0] + widths[$0 + 1] }
            let minimum = PaneKeys.minimum(pairWidths: pairs, minPercents: dividers.map(\.minPercent))
            guard let want = goal(widths, k, minimum, row.map(\.frame)) else { return .done(presses: total) }
            let presses = PaneKeys.plan(from: widths, to: want, minimum: minimum)
            guard !presses.isEmpty else { return .done(presses: total) }
            EnsembleLog.write("pane widths: pass \(pass + 1), \(presses.count) keys \(Int(PaneKeys.pace(presses.count) * 1000)) ms apart, "
                              + "minimum \(Int(minimum)) pt, \(widths.map { Int($0) }) to \(want.map { Int($0) })")
            if let why = await press(presses, on: dividers.map(\.element), in: target) { return .stopped(why) }
            total += presses.count
            try? await Task.sleep(nanoseconds: Self.settle)
        }
        return .done(presses: total)
    }

    /// The planned keys, one every `PaneKeys.pace`. nil when they all went, else why it stopped.
    private func press(_ presses: [PaneKeys.Press], on dividers: [AXUIElement], in target: ClaudeSession) async -> String? {
        let pace = UInt64(PaneKeys.pace(presses.count) * 1_000_000_000)
        let since = startedAt
        func safe() -> String? {
            if let why = blocker() { return why }
            // Hardware input only: the keys Ensemble posts never count, the owner's own hand always does.
            if ClaudeBridge.secondsSincePhysicalInput() < CACurrentMediaTime() - since { return "the keyboard or mouse was used" }
            return nil
        }
        ClaudeBridge.ownKeys(began: true)
        defer { ClaudeBridge.ownKeys(began: false) }
        var focused: Int?
        for (i, p) in presses.enumerated() {
            if let why = safe() { return why }
            let divider = dividers[p.divider]
            if focused != p.divider {
                if focused != nil { refreshFrames() }
                guard await ctx.bridge.focusDivider(divider, in: target) else { return "the divider did not take the keyboard" }
                focused = p.divider
            } else if !(await ctx.bridge.dividerHoldsKeyboard(divider)) {
                return "the divider lost the keyboard"
            }
            // The checks above waited on Claude: look again right before the key.
            if let why = safe() { return why }
            pressedAny = true
            ClaudeBridge.postKey(p.key)
            if i % Self.refreshEvery == Self.refreshEvery - 1 { refreshFrames() }
            try? await Task.sleep(nanoseconds: pace)
        }
        return nil
    }

    /// Reads the session frames again without waiting for them, at most one read at a time.
    private func refreshFrames() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            let sessions = await self.ctx.bridge.refreshSessions().sessions
            guard !sessions.isEmpty, self.ctx.listening == nil else { return }
            self.ctx.sessions = sessions
            self.framesChanged()
        }
    }

    /// Where `target` sits in its row ("pane 2 of 4"), for logs: never its name, which is the owner's text.
    private func place(of target: ClaudeSession) -> String {
        let row = PaneWidths.row(of: target, in: ctx.sessions)
        guard let i = row.firstIndex(where: { $0.id == target.id }) else { return "a pane" }
        return "pane \(i + 1) of \(row.count)"
    }

    /// Why no key may be pressed right now, or nil.
    private func blocker() -> String? {
        if !ctx.settings.enabled { return "Ensemble is off" }
        if !ctx.bridge.claudeIsFrontmost() { return "Claude is not in front" }
        if ctx.handsBusy { return "Paused while you type or use the mouse" }
        if ctx.listening != nil || ctx.busy { return "Dictation is starting or stopping" }
        if sendBusy() { return "A send is in progress" }
        if keyWatchOn() { return "Dictation has just ended" }
        if cancelled { return "interrupted" }
        return nil
    }
}
