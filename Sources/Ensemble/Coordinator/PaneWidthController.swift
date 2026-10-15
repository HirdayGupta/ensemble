import AppKit
import EnsembleCore

/// Peace sign and scissors: resizes the session panes of the Claude window you are facing by dragging the
/// dividers between them, one divider at a time, each along the app's one smooth curve. Focus settling on a pane
/// narrower than Claude's chat column widens it to the column the same way (`autoFit`), unless Settings turns it off.
///
/// A drag is a synthetic left-button press, moves and release on the divider, posted through the session event
/// tap like scrolling. The pointer goes to the divider for the drag and is put back exactly where it was after the
/// last one. Every frame checks that Claude is still in front and owns the window under the divider, that no
/// dictation or send has started, and that the keyboard, mouse and trackpad are untouched; otherwise the button
/// is released where it is and nothing more is dragged.
@MainActor
final class PaneWidthController {
    private let ctx: CoordinatorContext
    /// A send is between its request and its result, or waits for a stop: no drag may start or continue.
    var sendBusy: () -> Bool = { false }
    private(set) var isRunning = false
    private var cancelled = false
    /// When this resize began, for the hand-on-the-mouse check, and whether it has posted any event yet.
    private var startedAt: TimeInterval = 0
    private var posted = false

    /// More drags than any row needs (two passes over a row of five), so a layout Claude refuses cannot loop.
    private static let maxDrags = 8
    private static let frameRate = 60.0

    /// Claude's chat column, as last measured from a pane wide enough to show it.
    private var column = ChatColumn.Memory()

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    func cancel() { if isRunning { cancelled = true } }

    func request(_ maximize: Bool, target: ClaudeSession?) {
        let what = maximize ? "Maximize" : "Even out"
        guard !isRunning else { return }
        if let why = ctx.commonRefusal() { ctx.refuse(why, title: what); return }
        guard let target else { ctx.refuse("Look at a Claude session first", title: what, resolves: .whenOnSession); return }
        if let why = blocker() { ctx.refuse(why, title: what); return }
        isRunning = true
        cancelled = false
        posted = false
        startedAt = CACurrentMediaTime()
        let saved = CGEvent(source: nil)?.location
        EnsembleLog.write("pane widths: \(maximize ? "maximize" : "even out") around \(ctx.name(of: target))")
        Task { @MainActor in
            defer {
                if self.posted, let saved { CGWarpMouseCursorPosition(saved) }
                self.isRunning = false
            }
            let outcome = await self.run(target: target) { _, _, k in maximize ? .maximize(k) : .evenOut }
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
        isRunning = true
        cancelled = false
        posted = false
        startedAt = CACurrentMediaTime()
        let saved = CGEvent(source: nil)?.location
        Task { @MainActor in
            defer {
                if self.posted, let saved { CGWarpMouseCursorPosition(saved) }
                self.isRunning = false
            }
            let readings = await self.ctx.bridge.chatColumns(in: row)
            self.column.note(row.map { readings[$0.id]?.column })
            let column = self.column.width
            let outcome = await self.run(target: target) { frames, dividers, k in
                let pane = frames[k]
                let want = ChatColumn.paneWidth(column: column, pane: pane, transcript: readings[target.id]?.transcript)
                let widths = PaneWidths.layout(panes: frames, dividers: dividers).widths
                return SessionFit.widths(current: widths, focus: k, width: want).map { .widths($0) }
            }
            if case .done(drags: 0) = outcome { return }
            EnsembleLog.write("pane widths: fit \(self.ctx.name(of: target)) to the chat column "
                              + "(\(Int(column)) pt, \(self.column.measured == nil ? "default" : "measured")): \(outcome)")
        }
    }

    private enum Outcome: CustomStringConvertible {
        case done(drags: Int)
        case stopped(String)
        case refused(String)
        var refusal: String? { if case .refused(let why) = self { return why }; return nil }
        var description: String {
            switch self {
            case .done(let n): return "done after \(n) drag\(n == 1 ? "" : "s")"
            case .stopped(let why): return "stopped: \(why)"
            case .refused(let why): return "refused: \(why)"
            }
        }
    }

    /// Drags dividers until the planner's goal is met. `plan` is asked once, with the row's pane frames, its
    /// dividers and the target's index, before the first drag; nil means there is nothing to do.
    private func run(target: ClaudeSession,
                     plan: ([CGRect], [Double], Int) -> PaneWidths.Goal?) async -> Outcome {
        var stuck = Set<Int>()
        var last: (divider: Int, fromX: Double)?
        var goal: PaneWidths.Goal?
        for drags in 0...Self.maxDrags {
            let sessions = await ctx.bridge.refreshSessions().sessions
            if !sessions.isEmpty { ctx.sessions = sessions; ctx.changed() }
            let row = PaneWidths.row(of: sessions.first { $0.id == target.id } ?? target, in: sessions)
            guard row.count >= 2, let k = row.firstIndex(where: { $0.id == target.id }) else {
                return drags == 0 ? .refused("Only one session in this window") : .stopped("the sessions changed")
            }
            let splitters = await ctx.bridge.paneDividers(in: target)
            guard let dividers = PaneWidths.dividers(between: row.map(\.frame), splitters: splitters) else {
                return drags == 0 ? .refused("Claude's pane dividers were not found") : .stopped("the dividers changed")
            }
            // A divider that did not follow its last drag has met Claude's own minimum width: leave it there.
            if let l = last, abs(dividers[l.divider] - l.fromX) < 2 { stuck.insert(l.divider) }
            if goal == nil { goal = plan(row.map(\.frame), dividers, k) }
            guard let goal else { return .done(drags: 0) }
            guard let move = PaneWidths.nextMove(panes: row.map(\.frame), dividers: dividers, goal: goal, stuck: stuck) else {
                return .done(drags: drags)
            }
            guard drags < Self.maxDrags else { return .stopped("too many drags") }
            let y = splitters.filter { abs(Double($0.midX) - dividers[move.divider]) < 1 }.first.map { Double($0.midY) }
                ?? Double(row[0].frame.midY)
            if let why = await drag(from: dividers[move.divider], to: move.toX, y: y) { return .stopped(why) }
            last = (move.divider, dividers[move.divider])
        }
        return .done(drags: Self.maxDrags)
    }

    /// Why nothing may be dragged right now, or nil.
    private func blocker() -> String? {
        if !ctx.settings.enabled { return "Ensemble is off" }
        if !ctx.bridge.claudeIsFrontmost() { return "Claude is not in front" }
        if ctx.handsBusy { return "Paused while you type or use the mouse" }
        if ctx.listening != nil || ctx.busy { return "Dictation is starting or stopping" }
        if sendBusy() { return "A send is in progress" }
        if cancelled { return "interrupted" }
        return nil
    }

    /// One divider from `from` to `to` over `PaneWidths.dragDuration`. nil when it finished, else why it stopped.
    private func drag(from: Double, to: Double, y: Double) async -> String? {
        let start = CACurrentMediaTime()
        let since = startedAt
        func point(_ x: Double) -> CGPoint { CGPoint(x: x, y: y) }
        func safe(at x: Double) -> String? {
            if let why = blocker() { return why }
            if ScreenFacts.topWindowOwner(at: point(x)) != ctx.bridge.claudePID { return "Claude does not own the window under the divider" }
            // Hardware input only: the events Ensemble posts here never count, the owner's own hand always does.
            if ClaudeBridge.secondsSincePhysicalInput() < CACurrentMediaTime() - since { return "the keyboard or mouse was used" }
            return nil
        }
        if let why = safe(at: from) { return why }
        posted = true
        ClaudeBridge.ownPointerEvents(began: true)
        defer { ClaudeBridge.ownPointerEvents(began: false) }
        ClaudeBridge.postMouse(.mouseMoved, at: point(from))
        ClaudeBridge.postMouse(.leftMouseDown, at: point(from))
        var x = from
        while true {
            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / Self.frameRate))
            if let why = safe(at: x) {
                ClaudeBridge.postMouse(.leftMouseUp, at: point(x))
                return why
            }
            let p = SmoothCurve.progress(t: CACurrentMediaTime() - start, duration: PaneWidths.dragDuration)
            x = from + (to - from) * p
            ClaudeBridge.postMouse(.leftMouseDragged, at: point(x))
            if p >= 1 { break }
        }
        ClaudeBridge.postMouse(.leftMouseUp, at: point(to))
        // Claude lays out on its next frame; read the result after it has.
        try? await Task.sleep(nanoseconds: 80_000_000)
        return nil
    }
}
