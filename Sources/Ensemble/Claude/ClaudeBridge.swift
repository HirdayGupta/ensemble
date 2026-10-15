import AppKit
import ApplicationServices
import EnsembleCore
import CoreGraphics
import Foundation

// Mic discovery through the accessibility tree follows the approach of
// github.com/reneceo/claude-dictation-hotkey (MIT, Rene Banuelos); see Vendor/LICENSE-claude-dictation-hotkey.

/// Everything that talks to Claude desktop. All Accessibility work runs on a private serial queue,
/// never the main thread. `stopDictation` alone uses a second queue so that a stuck read can never
/// delay turning the microphone off.
final class ClaudeBridge: @unchecked Sendable {
    let queue = DispatchQueue(label: "ensemble.claude.bridge", qos: .userInitiated)
    let urgentQueue = DispatchQueue(label: "ensemble.claude.bridge.urgent", qos: .userInteractive)
    /// Dictation start has its own queue so a slow session refresh on `queue` cannot delay it.
    let startQueue = DispatchQueue(label: "ensemble.claude.bridge.start", qos: .userInteractive)
    let inFlight = InFlightTracker()

    private let lock = NSLock()
    private var cache: [String: CachedSession] = [:]
    private var flaggedPID: pid_t = 0
    private var lastStopPressAt: Date?
    private var scrollMethod: ScrollMethod?
    private var noScrollAreaUntil: [String: Date] = [:]
    private var shuttingDown = false
    private var axDisabled = false
    private var lastMicReading: (text: String, at: Date)?

    static let ambientInputAllowlist: Set<String> = []

    init() {}

    // MARK: Claude process

    private var claudeApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).filter { !$0.isTerminated }
    }

    var claudePID: pid_t? { claudeApps.first?.processIdentifier }

    func claudeIsRunning() -> Bool { !claudeApps.isEmpty }

    /// Once set, no new dictation can start; the quit path uses it so a start in flight cannot press after the stop.
    func beginShutdown() { lock.lock(); shuttingDown = true; lock.unlock() }
    var isShuttingDown: Bool { lock.lock(); defer { lock.unlock() }; return shuttingDown }

    /// True when the last discovery was refused because Accessibility is off or the grant is stale.
    var accessibilityDisabled: Bool { lock.lock(); defer { lock.unlock() }; return axDisabled }

    /// What a refusal says when a session cannot be found.
    var sessionNotFound: String {
        accessibilityDisabled ? "Accessibility is off or stale for Ensemble; remove it in Settings and add it again" : "session not found"
    }

    func noteMic(_ text: String) { lock.lock(); lastMicReading = (text, Date()); lock.unlock() }

    /// Both mic sources as of the last read ("mic AX value=1 label=... capture=true, 2.1 s ago"), for logs.
    /// Cached from the last bridge call; reading it never touches Accessibility.
    var micSnapshot: String {
        lock.lock(); defer { lock.unlock() }
        guard let r = lastMicReading else { return "mic not read yet" }
        return "mic \(r.text), \(String(format: "%.1f", Date().timeIntervalSince(r.at))) s ago"
    }

    private func noteAX(_ error: AXError) {
        lock.lock(); axDisabled = error == .apiDisabled; lock.unlock()
    }

    func claudeIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeLabels.bundleID
    }

    var claudeVersion: String? {
        guard let url = claudeApps.first?.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var lastScrollMethod: ScrollMethod? {
        lock.lock(); defer { lock.unlock() }
        return scrollMethod
    }

    /// Longest time any normal-queue Accessibility job has been running, 0 when idle.
    var longestAXCallSeconds: TimeInterval { inFlight.longestSeconds }

    // MARK: Running work

    func run<T>(urgent: Bool = false, onStartQueue: Bool = false, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            (urgent ? urgentQueue : onStartQueue ? startQueue : queue).async {
                let token = urgent ? nil : self.inFlight.begin()
                let result = work()
                if let token { self.inFlight.end(token) }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: Sessions

    func refreshSessions() async -> [ClaudeSession] {
        await run { self.discover().map(\.session) }
    }

    func session(at point: CGPoint) -> ClaudeSession? {
        lock.lock(); defer { lock.unlock() }
        return cache.values.map(\.session)
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Full discovery; replaces the cache. Runs on a bridge queue.
    func discover() -> [CachedSession] {
        guard let pid = claudePID else {
            noteAX(.success)
            replaceCache([])
            return []
        }
        let app = AX.application(pid: pid)
        let justEnabled = ensureManualAccessibility(app: app, pid: pid)

        let cgWindows = Self.cgWindows(pids: Set(claudeApps.map(\.processIdentifier)))
        var found: [CachedSession] = []
        // Right after the flag is set Chromium builds its tree incrementally; give it a few passes.
        for attempt in 0..<(justEnabled ? 8 : 1) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            found = []
            let windows = AX.read(app, kAXWindowsAttribute)
            noteAX(windows.error)
            for (windowIndex, window) in ((windows.value as? [AXUIElement]) ?? []).enumerated() {
                if AX.bool(window, kAXMinimizedAttribute) == true { continue }
                guard let wf = AX.frame(window), wf.width > 50, wf.height > 50 else { continue }
                var number = 0
                if let match = cgWindows.first(where: { Self.close($0.bounds, wf) }) {
                    if !match.onScreen { continue }
                    number = match.number
                }
                found += sessions(in: window, windowNumber: number, idKey: number != 0 ? number : -(windowIndex + 1))
            }
            if !found.isEmpty { break }
        }
        replaceCache(found)
        return found
    }

    private func replaceCache(_ sessions: [CachedSession]) {
        lock.lock(); defer { lock.unlock() }
        cache = Dictionary(sessions.map { ($0.session.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func sessions(in window: AXUIElement, windowNumber: Int, idKey: Int) -> [CachedSession] {
        let mics = Self.collectMics(in: window)
        var result: [CachedSession] = []
        for (i, mic) in mics.enumerated() {
            guard let paneIndex = Self.paneIndex(for: i, among: mics),
                  let pane = Optional(mic.path[paneIndex]),
                  let frame = AX.frame(pane) else { continue }
            let scan = Self.scanPane(pane)
            let id = Self.sessionID(windowKey: idKey, micIndex: i)
            let elements = PaneElements(window: window, pane: pane, mic: mic.element, composer: scan.composer,
                                        sendButton: scan.send, stopButton: scan.stop,
                                        modeControl: scan.mode, transcript: scan.transcript)
            result.append(CachedSession(session: ClaudeSession(id: id, frame: frame, windowNumber: windowNumber, title: scan.title), elements: elements))
        }
        return result
    }

    /// Keyed on the window and the mic's order in it, never on the frame, so dragging or resizing a window
    /// mid-hold does not change the id the stop is looked up by.
    static func sessionID(windowKey: Int, micIndex: Int) -> String { "w\(windowKey)#\(micIndex)" }

    /// A cached session whose mic checkbox still answers; otherwise rediscover and match by id, then by overlap.
    func liveEntry(_ s: ClaudeSession, rescanPane: Bool = false) -> CachedSession? {
        lock.lock()
        let cached = cache[s.id]
        lock.unlock()
        if let cached, Self.isMicCheckbox(cached.elements.mic) {
            guard rescanPane else { return cached }
            var fresh = cached
            let scan = Self.scanPane(cached.elements.pane)
            if scan.composer != nil || scan.send != nil || scan.mode != nil {
                fresh.elements.composer = scan.composer
                fresh.elements.sendButton = scan.send
                fresh.elements.stopButton = scan.stop
                fresh.elements.modeControl = scan.mode
                fresh.elements.transcript = scan.transcript
                lock.lock(); cache[s.id] = fresh; lock.unlock()
                return fresh
            }
        }
        let all = discover()
        if let exact = all.first(where: { $0.session.id == s.id }) { return exact }
        return all.max { overlap($0.session.frame, s.frame) < overlap($1.session.frame, s.frame) }
            .flatMap { overlap($0.session.frame, s.frame) > s.frame.width * s.frame.height * 0.6 ? $0 : nil }
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    // MARK: Accessibility enablement

    /// Electron only builds its accessibility tree for web content after this flag is set; it must be
    /// set again after each Claude launch.
    private func ensureManualAccessibility(app: AXUIElement, pid: pid_t) -> Bool {
        lock.lock()
        let already = flaggedPID == pid
        lock.unlock()
        if already { return false }
        let error = AX.set(app, "AXManualAccessibility", kCFBooleanTrue)
        guard error == .success else { noteAX(error); return false }
        lock.lock(); flaggedPID = pid; lock.unlock()
        return true
    }

    // MARK: Tree scanning

    struct MicHit {
        var element: AXUIElement
        var path: [AXUIElement]       // window ... mic, inclusive
        var roles: [String]
    }

    static func isMicLabel(_ s: String?) -> Bool { s == ClaudeLabels.micIdle || s == ClaudeLabels.micActive }

    static func isMicCheckbox(_ el: AXUIElement) -> Bool {
        let v = AX.multi(el, [kAXRoleAttribute, kAXDescriptionAttribute])
        return (v[0] as? String) == "AXCheckBox" && isMicLabel(v[1] as? String)
    }

    private static let walkAttrs = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute]

    /// Every dictation checkbox under `window` with its ancestor path. The transcript is not entered:
    /// it holds most of the nodes and never contains a composer.
    static func collectMics(in window: AXUIElement, maxNodes: Int = 12_000) -> [MicHit] {
        var hits: [MicHit] = []
        var count = 0
        func go(_ el: AXUIElement, _ path: [AXUIElement], _ roles: [String], _ depth: Int) {
            count += 1
            if count > maxNodes || depth > 70 { return }
            let v = AX.multi(el, walkAttrs)
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            let path = path + [el]
            let roles = roles + [role]
            if role == "AXCheckBox", isMicLabel(desc) {
                hits.append(MicHit(element: el, path: path, roles: roles))
                return
            }
            if desc == ClaudeLabels.transcript { return }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, path, roles, depth + 1) }
        }
        go(window, [], [], 0)
        return hits
    }

    /// Index into `mics[i].path` of the session's pane. The choice itself is `PaneChoice`; this reads the
    /// facts it needs (frame, which session parts and whether the sidebar each ancestor holds) in one walk.
    static func paneIndex(for i: Int, among mics: [MicHit]) -> Int? {
        let me = mics[i]
        let lowest = (me.roles.lastIndex(of: "AXWebArea") ?? 0) + 1
        let micIndex = me.path.count - 1
        guard lowest < micIndex else { return nil }
        let ks = Array(lowest..<micIndex)
        let found = ownParts(under: me.path, from: lowest)
        let ancestors = ks.map { k -> PaneAncestor in
            PaneAncestor(frame: AX.frame(me.path[k]) ?? .zero,
                         hasHeader: found.header >= k, hasTranscript: found.transcript >= k,
                         hasComposer: found.composer >= k, hasSidebar: found.sidebar >= k,
                         otherMics: mics.filter { $0.path.count > k && CFEqual($0.path[k], me.path[k]) }.count - 1)
        }
        return PaneChoice.index(among: ancestors).map { ks[$0] }
    }

    /// For each page part, the deepest index on `path` whose subtree holds it (-1 when not found).
    private static func ownParts(under path: [AXUIElement], from lowest: Int, maxNodes: Int = 12_000)
        -> (header: Int, transcript: Int, composer: Int, sidebar: Int) {
        var r = (header: -1, transcript: -1, composer: -1, sidebar: -1)
        var count = 0
        func go(_ el: AXUIElement, _ shared: Int, _ depth: Int) {
            count += 1
            if count > maxNodes || depth > 70 { return }
            var shared = shared
            if shared + 1 < path.count, CFEqual(el, path[shared + 1]) { shared += 1 }
            let v = AX.multi(el, walkAttrs)
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            if desc == ClaudeLabels.transcript { r.transcript = max(r.transcript, shared); return }
            if desc == ClaudeLabels.sidebar { r.sidebar = max(r.sidebar, shared) }
            if role == "AXButton", let desc, desc.hasSuffix(ClaudeLabels.renameSuffix) { r.header = max(r.header, shared) }
            if role == "AXTextArea", desc == ClaudeLabels.composer { r.composer = max(r.composer, shared) }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, shared, depth + 1) }
        }
        go(path[lowest], lowest, 0)
        return r
    }

    struct PaneScan {
        var composer: AXUIElement?
        var send: AXUIElement?
        var stop: AXUIElement?
        var mode: AXUIElement?
        var transcript: AXUIElement?
        var title: String?
    }

    static func scanPane(_ pane: AXUIElement, maxNodes: Int = 4_000) -> PaneScan {
        var scan = PaneScan()
        var anyTextArea: AXUIElement?
        var anyPopup: AXUIElement?
        var count = 0
        func go(_ el: AXUIElement, _ depth: Int) {
            count += 1
            if count > maxNodes || depth > 60 { return }
            let v = AX.multi(el, walkAttrs)
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            let title = v[2] as? String
            switch role {
            case "AXTextArea":
                if desc == ClaudeLabels.composer, scan.composer == nil { scan.composer = el }
                if anyTextArea == nil { anyTextArea = el }
            case "AXButton":
                if desc == ClaudeLabels.send || title == ClaudeLabels.send { scan.send = scan.send ?? el }
                if desc == ClaudeLabels.stop || title == ClaudeLabels.stop { scan.stop = scan.stop ?? el }
                if scan.title == nil, let desc, desc.hasSuffix(ClaudeLabels.renameSuffix) {
                    scan.title = String(desc.dropLast(ClaudeLabels.renameSuffix.count))
                }
            case "AXPopUpButton":
                if let title, !title.isEmpty {
                    if ClaudeLabels.allModes.contains(title) { scan.mode = scan.mode ?? el }
                    if anyPopup == nil, desc == nil || desc!.isEmpty { anyPopup = el }
                }
            default: break
            }
            if desc == ClaudeLabels.transcript { scan.transcript = el; return }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, depth + 1) }
        }
        go(pane, 0)
        if scan.composer == nil { scan.composer = anyTextArea }
        if scan.mode == nil { scan.mode = anyPopup }
        return scan
    }

    // MARK: Windows

    struct CGWin { var number: Int; var bounds: CGRect; var onScreen: Bool }

    static func cgWindows(pids: Set<pid_t>) -> [CGWin] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [CGWin] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            out.append(CGWin(number: number, bounds: rect, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        return out
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    // MARK: Shared state used by the other extensions

    func notePress(stop: Bool) {
        guard stop else { return }
        lock.lock(); lastStopPressAt = Date(); lock.unlock()
    }

    func secondsSinceStopPress() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastStopPressAt.map { Date().timeIntervalSince($0) }
    }

    func setScrollMethod(_ m: ScrollMethod) {
        lock.lock(); scrollMethod = m; lock.unlock()
    }

    func scrollAreaCooldownActive(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = noScrollAreaUntil[id], until > Date() { return true }
        return false
    }

    func suppressScrollAreaSearch(_ id: String, for seconds: TimeInterval) {
        lock.lock(); noScrollAreaUntil[id] = Date().addingTimeInterval(seconds); lock.unlock()
    }
}
