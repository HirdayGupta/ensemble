import ApplicationServices
import CoreGraphics
import EnsembleCore
import Foundation

/// Pane widths. Claude's side-by-side panes are resized only by dragging the divider between two of them; its
/// accessibility tree names each divider (`ClaudeLabels.paneResize`), which is how Ensemble finds where to grab.
extension ClaudeBridge {
    /// The frames of the pane-column dividers in the window holding `s`. Empty when none answer. The transcript is
    /// not entered: it holds most of the nodes and never holds a divider.
    func paneDividers(in s: ClaudeSession) async -> [CGRect] {
        await run {
            guard let entry = self.liveEntry(s) else { return [] }
            var found: [CGRect] = []
            var count = 0
            let deadline = Date().addingTimeInterval(1)
            func go(_ el: AXUIElement, _ depth: Int) {
                count += 1
                if count > 12_000 || depth > 70 || (count % 64 == 0 && Date() >= deadline) { return }
                let v = AX.multi(el, [kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute])
                let desc = v[1] as? String
                if (v[0] as? String) == "AXSplitter", desc == ClaudeLabels.paneResize {
                    if let f = AX.frame(el) { found.append(f) }
                    return
                }
                if desc == ClaudeLabels.transcript { return }
                for c in (v[2] as? [AXUIElement]) ?? [] { go(c, depth + 1) }
            }
            go(entry.elements.window, 0)
            return found
        }
    }

    /// For each session: its transcript's frame, and the chat column's width where that pane is wide enough to
    /// show it (`ChatColumn.measure`). Read only, and shallow: the column sits a few levels under the transcript,
    /// so each walk stops 10 levels down, after 800 nodes or 0.25 s, never reading the message text.
    func chatColumns(in sessions: [ClaudeSession]) async -> [String: (transcript: CGRect?, column: Double?)] {
        await run {
            var out: [String: (transcript: CGRect?, column: Double?)] = [:]
            for s in sessions {
                var entry = self.liveEntry(s)
                if entry?.elements.transcript.flatMap(AX.frame) == nil { entry = self.liveEntry(s, rescanPane: true) }
                guard let transcript = entry?.elements.transcript, let frame = AX.frame(transcript) else {
                    out[s.id] = (nil, nil)
                    continue
                }
                var frames: [CGRect] = []
                let deadline = Date().addingTimeInterval(0.25)
                var n = 0
                AX.walk(transcript, maxDepth: 10, maxNodes: 800) { el, depth in
                    n += 1
                    if n % 32 == 0, Date() >= deadline { return false }
                    if depth > 0, let f = AX.frame(el), f.width >= 400 { frames.append(f) }
                    return true
                }
                out[s.id] = (frame, ChatColumn.measure(transcript: frame, elements: frames))
            }
            return out
        }
    }

    /// One synthetic left-button event at `point`, through the session event tap: the path Claude's web content
    /// receives, as scrolling found (docs/gotchas.md, 3). The caller puts the pointer back when the drag ends.
    static func postMouse(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cgSessionEventTap)
    }
}
