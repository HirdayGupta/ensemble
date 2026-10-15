import AppKit
import EnsembleCore

/// Decides which Claude session the nose is on and moves keyboard focus to it. The decisions themselves
/// (dwell, border margin, what to do on arrival) are `FocusTracker` and `FocusPolicy`; this applies them.
@MainActor
final class FocusController {
    private let ctx: CoordinatorContext
    private var tracker = FocusTracker()
    /// Front-window check cache: who owns the window under the nose, refreshed at most every 0.15 s.
    private var topOwner: (at: CGPoint, t: TimeInterval, pid: pid_t?)?
    private var lastRaiseBlockLog: TimeInterval = 0
    /// The session Ensemble last moved focus to.
    private var lastFocusedId: String?
    /// A look-away focus that was deferred by busy or typing.
    private var pending: (session: ClaudeSession, until: TimeInterval)?
    /// Session to focus once a dictation stop (caused by looking at it) completes.
    private(set) var afterStop: ClaudeSession?
    /// Stops the running dictation but keeps its text (wired by the Coordinator).
    var stopDictation: (String) -> Void = { _ in }
    /// `ctx.sessions`, ordered left to right on screen, with a group per screen/window boundary; recomputed
    /// only when that list or a pane's frame changes, never per frame. Feeds the island's session-columns glyph.
    private var sessionOrderCache: (sessions: [ClaudeSession], ordered: [ClaudeSession], groupOf: [String: Int])?

    /// You switched to another app yourself (keyboard, click or Dock). Until Claude is frontmost again, Ensemble
    /// never brings Claude forward: no raising a covered session, no focus moves. The highlight still follows.
    /// Measured 2026-10-14: a covered-session raise pulled Claude back over a full-screen app twice in 7 s.
    private(set) var userLeftClaude: Bool
    private var activationObserver: NSObjectProtocol?

    init(ctx: CoordinatorContext) {
        self.ctx = ctx
        userLeftClaude = !Self.isClaude(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
    }

    private static func isClaude(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true
    }

    /// Ensemble itself only ever activates Claude, so any other app becoming active was your choice.
    private func activated(_ app: NSRunningApplication?) {
        let left = !Self.isClaude(app)
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        guard left != userLeftClaude else { return }
        userLeftClaude = left
        EnsembleLog.write(left ? "you switched to another app; Claude stays where you put it until you return to it"
                               : "Claude is frontmost again; focus follows the nose")
        if left { pending = nil; tracker.clearCovered() }
    }

    var target: ClaudeSession? { tracker.target }
    var candidate: (session: ClaudeSession?, since: TimeInterval)? { tracker.candidate }

    /// One nose reading. Moves the target after its dwell and raises a covered session the nose rests on.
    /// Returns the session whose window is in front under the nose, if any.
    func observe(nose p: CGPoint, at t: TimeInterval, held: Bool) -> ClaudeSession? {
        // Claude only: the nose counts only over a Claude session whose window is actually in front there.
        var under = FocusTracker.session(at: p, in: ctx.sessions, current: tracker.target) { _ in claudeInFront(at: p, t: t) }
        let dictating = ctx.listening
        // While dictating, a look counts as resting on another session only once the nose is well inside it.
        if let d = dictating, let u = under, u.id != d.id, !EdgeWarnings.restsDeepInside(nose: p, neighbour: u.frame, dictating: d.frame) {
            under = ctx.sessions.first { $0.id == d.id } ?? d
        }
        let speaking = dictating != nil && ctx.speech.locked(at: t)
        if let moved = tracker.observe(under: under, at: t, held: held, listening: dictating != nil, speaking: speaking) { lookedAt(moved) }
        // A Claude session hidden behind another app's window: resting the nose on it brings Claude forward.
        if under == nil, !held, let hidden = ctx.sessions.first(where: { $0.frame.contains(p) }) {
            if tracker.noteCovered(hidden.id, at: t) { raise(hidden, at: t) }
        } else {
            tracker.clearCovered()
        }
        return under
    }

    /// For the trace log: the target and the candidate with how long it has waited.
    func traceState(at t: TimeInterval) -> String {
        let cand = candidate.map { "\($0.session?.id ?? "none")@\(String(format: "%.2f", t - $0.since))" } ?? "-"
        return "target=\(target?.id ?? "-") cand=\(cand)"
    }

    /// The deferred focus retries from the tick for a few seconds.
    func tick() {
        guard let p = pending else { return }
        if CACurrentMediaTime() > p.until || target?.id != p.session.id { pending = nil }
        else if !ctx.busy, ClaudeBridge.secondsSinceTypingOrClick() >= CoordinatorContext.inputQuiet { pending = nil; lookedAt(p.session) }
    }

    /// While dictating: the session focus will move to, and how far its dwell has run.
    func switching() -> SessionSwitch? {
        guard let listening = ctx.listening else { return nil }
        if let next = afterStop { return columns(from: listening, to: next, progress: 1) }
        if let c = candidate, let to = c.session, to.id != listening.id, let now = ctx.latestHead?.t {
            return columns(from: listening, to: to, progress: min(max((now - c.since) / FocusTracker.listeningSwitchDwell, 0), 1))
        }
        return nil
    }

    /// While dictating: the columns toward a neighbouring session, with no progress yet. The island leans its
    /// lit column toward it as the nose nears that session's edge.
    func approach(to id: String) -> SessionSwitch? {
        guard let listening = ctx.listening, let to = ctx.sessions.first(where: { $0.id == id }) else { return nil }
        return columns(from: listening, to: to, progress: 0)
    }

    private func columns(from: ClaudeSession, to: ClaudeSession, progress: Double) -> SessionSwitch {
        let (ordered, groupOf) = sessionOrder()
        var breaks: Set<Int> = []
        if ordered.count > 1 {
            for i in 1..<ordered.count where groupOf[ordered[i].id] != groupOf[ordered[i - 1].id] { breaks.insert(i) }
        }
        return SessionSwitch(name: ctx.name(of: to), progress: progress, sessionCount: ordered.count, groupBreaks: breaks,
                             fromIndex: ordered.firstIndex { $0.id == from.id } ?? 0,
                             toIndex: ordered.firstIndex { $0.id == to.id } ?? 0)
    }

    /// `ctx.sessions`, ordered left to right on screen, recomputed only when that list or a frame changed
    /// (a moved window reorders the columns even though the same sessions are open).
    private func sessionOrder() -> (ordered: [ClaudeSession], groupOf: [String: Int]) {
        let sessions = ctx.sessions
        if let cached = sessionOrderCache, cached.sessions == sessions { return (cached.ordered, cached.groupOf) }
        let screens = NSScreen.screens.map { ScreenGeometry.topLeftFrame(of: $0) }
        let pairs = SessionOrdering.ordered(ctx.sessions, screens: screens)
        let ordered = pairs.map(\.session)
        var groupOf: [String: Int] = [:]
        for pair in pairs { groupOf[pair.session.id] = pair.group }
        sessionOrderCache = (sessions, ordered, groupOf)
        return (ordered, groupOf)
    }

    var hasTargetOrCandidate: Bool { tracker.target != nil || tracker.candidate != nil }
    func forgetTarget() { tracker.forgetTarget() }
    func forgetTargetAndCandidate() { tracker.forgetTargetAndCandidate() }
    func forgetAll() { tracker.forgetAll() }
    func clearAfterStop() { afterStop = nil }
    func clearDeferred() { pending = nil; afterStop = nil }

    private func raise(_ hidden: ClaudeSession, at t: TimeInterval) {
        if userLeftClaude { tracker.clearCovered(); return }
        let typed = ClaudeBridge.secondsSinceTypingOrClick() < CoordinatorContext.inputQuiet
        if ctx.busy || typed {
            if t - lastRaiseBlockLog > 5 { lastRaiseBlockLog = t; EnsembleLog.write("raise held back: \(ctx.busy ? "busy" : "typing or clicking")") }
            return
        }
        tracker.clearCovered()
        EnsembleLog.write("raising Claude: nose rested on a covered session")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)   // a short pause before the raise
            let r = await self.ctx.bridge.focus(hidden, unlessTypedWithin: CoordinatorContext.inputQuiet)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            EnsembleLog.write("raise result: \(r), frontmost now \(front)")
        }
    }

    /// The nose settled on a different session. Focus follows it; a dictation running elsewhere stops first,
    /// keeping its text unsent (switching sessions in Claude while recording would discard it).
    private func lookedAt(_ session: ClaudeSession) {
        let action = FocusPolicy.action(
            for: session, lastFocusedId: lastFocusedId,
            claudeInFront: NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true,
            busy: ctx.busy, secondsSinceInput: ClaudeBridge.secondsSinceTypingOrClick(),
            inputQuiet: CoordinatorContext.inputQuiet, listeningId: ctx.listening?.id)
        switch action {
        case .none:
            pending = nil
        case .retryLater:
            // The nose has already settled and will not "settle" again, so retry from the tick for a few seconds.
            pending = (session, CACurrentMediaTime() + 3)
        case .stopDictationFirst:
            pending = nil
            afterStop = session
            EnsembleLog.write("looked at another session; dictation stopped and kept")
            stopDictation("looked at another session")
        case .focusNow where userLeftClaude:
            pending = nil
        case .focusNow:
            pending = nil
            lastFocusedId = session.id
            EnsembleLog.write("focus moved to a session")
            Task {
                if case .refused = await self.ctx.bridge.focus(session, unlessTypedWithin: CoordinatorContext.inputQuiet) { self.lastFocusedId = nil }
            }
        }
    }

    private func claudeInFront(at p: CGPoint, t: TimeInterval) -> Bool {
        if let c = topOwner, t - c.t < 0.15, hypot(c.at.x - p.x, c.at.y - p.y) < 40 { return c.pid == claudePID(at: t) }
        let pid = ScreenFacts.topWindowOwner(at: p)
        topOwner = (p, t, pid)
        return pid != nil && pid == claudePID(at: t)
    }

    /// Claude's process id, looked up at most once a second: the lookup lists running applications, and this is
    /// asked on every head reading.
    private var claudePIDCache: (pid: pid_t?, t: TimeInterval)?
    private func claudePID(at t: TimeInterval) -> pid_t? {
        if let c = claudePIDCache, t - c.t >= 0, t - c.t < 1 { return c.pid }
        let pid = ctx.bridge.claudePID
        claudePIDCache = (pid, t)
        return pid
    }
}
