import AppKit
import SwiftUI

/// What the setup-change prompt shows: a title, one detail line and a primary action, plus "Later".
/// `id` is the prompt's identity (which setup it is about) and drives both SwiftUI's view identity and
/// equality; the closures are not compared.
struct SetupPromptInfo: Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let primaryLabel: String
    let onPrimary: () -> Void
    let onLater: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Sits under the status island: no coloured status dots, just the ask. While it shows, a held thumbs-up
/// starts the primary action instead of sending (the coordinator wires that).
struct SetupPromptCard: View {
    let info: SetupPromptInfo

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text(info.title).font(.headline).foregroundStyle(.white)
                Text(info.detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(info.primaryLabel, action: info.onPrimary).ensembleButtonStyle(prominent: true)
                Button("Later", action: info.onLater).ensembleButtonStyle()
            }
            Text("or hold a thumbs-up to start").font(.caption2).foregroundStyle(.white.opacity(0.4))
        }
        .padding(16)
        .frame(maxWidth: 380)
        .fixedSize(horizontal: true, vertical: false)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Owns the one small floating panel for the setup-change prompt. Unlike the click-through overlay panels
/// (which never take focus or intercept clicks, by design), this one has real buttons, sized to its own
/// content rather than the whole screen, the same way the hotkey's floating panel works.
@MainActor
final class SetupPromptController {
    private var panel: SetupPromptPanel?

    /// Shows (or replaces) the prompt near the top of `screen`, under where the status island sits.
    func show(_ info: SetupPromptInfo, on screen: NSScreen) {
        let panel = self.panel ?? SetupPromptPanel()
        self.panel = panel
        let host = NSHostingView(rootView: SetupPromptCard(info: info))
        host.sizingOptions = []
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 70))
        let wasVisible = panel.isVisible
        panel.alphaValue = wasVisible ? panel.alphaValue : 0
        panel.orderFrontRegardless()
        guard !wasVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fades the prompt out, never cutting it off mid-animation (the same rule the overlay panels follow).
    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let panel = self?.panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }
}

private final class SetupPromptPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
