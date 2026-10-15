import CoreGraphics
import Testing
@testable import EnsembleCore

/// Ancestor chains shaped like Claude's real tree (read live): page, content area, optional column,
/// session panel, body. Frames are only used to tell the answers apart.
@Suite struct PaneChoiceTests {
    static let window = CGRect(x: 0, y: 34, width: 1512, height: 883)

    static func a(_ f: CGRect, header: Bool = true, transcript: Bool = true, composer: Bool = true,
                  sidebar: Bool = false, others: Int = 0) -> PaneAncestor {
        PaneAncestor(frame: f, hasHeader: header, hasTranscript: transcript, hasComposer: composer,
                     hasSidebar: sidebar, otherMics: others)
    }

    /// Outermost first. 0 page, 1 content area, 2 session panel, 3 body (no header).
    func single(sidebarInside: Bool) -> [PaneAncestor] {
        let panel = CGRect(x: 8, y: 42, width: 1496, height: 868)
        return [
            Self.a(Self.window, sidebar: true),
            Self.a(sidebarInside ? Self.window : CGRect(x: 260, y: 34, width: 1252, height: 883), sidebar: sidebarInside),
            Self.a(panel),
            Self.a(CGRect(x: 8, y: 71, width: 1496, height: 839), header: false),
        ]
    }

    @Test func oneSessionSidebarOpenPicksThePanel() {
        let chain = single(sidebarInside: false)
        #expect(PaneChoice.index(among: chain) == 2)
    }

    @Test func oneSessionSidebarClosedPicksThePanel() {
        // Closed sidebar still leaves its group (and the top bar buttons) beside the content, never inside the panel.
        var chain = single(sidebarInside: false)
        chain[1].frame = Self.window
        #expect(PaneChoice.index(among: chain) == 2)
        // Even a content wrapper that holds the sidebar group is skipped.
        #expect(PaneChoice.index(among: single(sidebarInside: true)) == 2)
    }

    /// n columns side by side: page and row hold every mic, each column holds only its own.
    func columns(_ n: Int, mine: Int) -> [PaneAncestor] {
        let w = 1512.0 / Double(n)
        let col = CGRect(x: w * Double(mine), y: 34, width: w, height: 883)
        let panel = col.insetBy(dx: 8, dy: 8)
        return [
            Self.a(Self.window, sidebar: true, others: n - 1),
            Self.a(Self.window, others: n - 1),
            Self.a(col),
            Self.a(panel),
            Self.a(panel.insetBy(dx: 0, dy: 29), header: false),
        ]
    }

    @Test(arguments: [2, 4])
    func severalSessionsKeepTheColumn(n: Int) {
        for mine in 0..<n {
            #expect(PaneChoice.index(among: columns(n, mine: mine)) == 2)
        }
    }

    @Test func severalSessionsMatchTheOldRuleEvenWhenPartsAreMissing() {
        var chain = columns(2, mine: 1)
        for i in chain.indices { chain[i].hasTranscript = false }
        #expect(PaneChoice.index(among: chain) == 2)
    }

    @Test func oneSessionWithPartsMissingFallsBackToTheOldAnswer() {
        var chain = single(sidebarInside: false)
        for i in chain.indices { chain[i].hasComposer = false }
        #expect(PaneChoice.index(among: chain) == 0)
    }

    @Test func emptyChainHasNoPane() {
        #expect(PaneChoice.index(among: []) == nil)
    }
}
