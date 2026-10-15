import Foundation
import EnsembleCore

/// Sends what was dictated when a thumbs-up asks for it, if nothing has changed since.
@MainActor
final class SendController {
    private let ctx: CoordinatorContext
    private(set) var lastSpoken: (session: ClaudeSession, stoppedAt: Date)?
    /// Thumbs-up made straight from the fist: send once the stop is confirmed.
    var afterStop = false

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    func spoke(in session: ClaudeSession) { lastSpoken = (session, Date()) }
    func forget() { lastSpoken = nil }

    func request() {
        guard ctx.settings.mapping.send != nil else { return }
        // Acting only on Claude: a thumbs-up made while another app is in front sends nothing.
        guard claudeInFront() else { return }
        guard ctx.listening == nil, !ctx.busy else {
            ctx.refuse("Send ignored: busy (\(ctx.listening != nil ? "still listening" : "a step in flight"))")
            return
        }
        if let why = ctx.commonRefusal() { ctx.refuse(why); return }
        let spokenAgo = lastSpoken.map { Date().timeIntervalSince($0.stoppedAt) }
        if let why = SendRules.refusal(spokenAgo: spokenAgo, inputAge: ClaudeBridge.secondsSinceTypingOrClick()) { ctx.refuse(why); return }
        guard let spoken = lastSpoken else { return }
        let session = spoken.session
        if let other = ctx.bridge.otherProcessCapturingInput() { ctx.refuse("\(other) is using a microphone"); return }
        Task { @MainActor in
            guard let text = await self.ctx.bridge.draftText(session), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.ctx.refuse("The draft is empty"); return
            }
            // The draft read takes a moment; a new dictation or keystroke may have started meanwhile.
            guard self.ctx.listening == nil, !self.ctx.busy else { self.ctx.refuse("Send dropped: something else started"); return }
            guard self.claudeInFront() else { return }
            if let why = SendRules.typedRefusal(spokenAgo: Date().timeIntervalSince(spoken.stoppedAt), inputAge: ClaudeBridge.secondsSinceTypingOrClick()) {
                self.ctx.refuse(why); return
            }
            EnsembleLog.write("sending (\(text.count) characters)")
            self.sendNow(session, shown: text)
        }
    }

    /// Refuses with the "Not sent" notice unless Claude is the app in front. The bridge checks again right before the press.
    private func claudeInFront() -> Bool {
        guard let why = SendRules.frontRefusal(claudeInFront: ctx.bridge.claudeIsFrontmost()) else { return true }
        ctx.refuse("Not sent: \(why)")
        return false
    }

    private func sendNow(_ session: ClaudeSession, shown: String) {
        guard claudeInFront() else { return }
        ctx.busy = true
        Task { @MainActor in
            let result = await self.ctx.bridge.sendDraft(session, shown: shown)
            self.ctx.busy = false
            switch result {
            case .done:
                EnsembleLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
                self.ctx.overlay.showBanner(title: "Sent", body: self.ctx.name(of: session), style: .sent, seconds: 1.5)
            case .refused(let why): self.ctx.refuse("Not sent: \(why)")
            case .unknown(let why):
                // Send was pressed but not confirmed: a second thumbs-up must not press it again.
                self.lastSpoken = nil
                self.ctx.refuse("Not sent: \(why)")
            }
        }
    }
}
