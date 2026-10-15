import AppKit
import EnsembleCore

/// Tracks the desk setup (camera plus screen arrangement), detects when it changes, and decides what that
/// means: restore silently, keep working on the screens that are still valid, or ask before pointing and
/// dictation resume. The pure matching lives in `EnsembleCore.SetupEvaluator`; this owns persistence, the
/// camera the engine is actually using, debouncing and the prompt shown on screen.
@MainActor
final class SetupController {
    unowned let ctx: CoordinatorContext

    private(set) var profiles: SetupProfiles
    /// Screens (of the current camera) whose calibration is still usable right now.
    private(set) var validScreenIDs: Set<String> = []
    private(set) var cameraID: String?
    private(set) var cameraName: String?
    private var previousCameraName: String?
    private var pendingDecision: SetupDecision?
    /// Setups the owner chose "Later" for; cleared when the setup changes again or the app relaunches.
    private var dismissedSignature: String?
    private var lastRestoreSignature: String?
    private var debounceTask: Task<Void, Never>?
    private let promptWindow = SetupPromptController()

    /// Wired by the coordinator: the full manual calibration path (every current screen) and a path that
    /// calibrates only the given screens. Both end up back here through `storeFullCalibration`/`storeSubsetCalibration`.
    var startFullCalibration: () -> Void = {}
    var startSubsetCalibration: ([NSScreen]) -> Void = { _ in }

    private static let debounce: UInt64 = 1_000_000_000
    private static let secondsPerScreen = 11

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    init(ctx: CoordinatorContext) {
        self.ctx = ctx
        profiles = Self.load(from: ctx.settings) ?? SetupProfiles()
    }

    var isPromptShowing: Bool { pendingDecision != nil }

    /// Whether a point in global screen space lands on a screen whose calibration is currently usable.
    /// A point on a new or moved screen reads the same as no target: that screen is ignored until it is
    /// calibrated, while the valid screens keep working.
    func isUsable(_ point: CGPoint) -> Bool {
        guard let screen = ScreenGeometry.screen(containing: point), let id = ScreenGeometry.stableID(of: screen) else { return false }
        return validScreenIDs.contains(id)
    }

    // MARK: - Detection

    /// The engine reports which camera it is actually using, at every start and camera switch.
    func cameraInUse(id: String, name: String) {
        migrateLegacyIfNeeded(cameraID: id, cameraName: name)
        if let old = cameraID, old != id {
            previousCameraName = cameraName
            // A different camera's angles mean nothing here; do not point with its leftover model.
            ctx.pointer.calibration = nil
            ctx.invalidateCalibrationCache()
        }
        cameraID = id
        cameraName = name
        scheduleEvaluate()
    }

    /// The screen arrangement changed (`NSApplication.didChangeScreenParametersNotification`).
    func screensChanged() {
        scheduleEvaluate()
    }

    /// Screens and camera changes each fire several notifications in a row; settle for a moment before deciding.
    private func scheduleEvaluate() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func evaluate() {
        guard let cameraID, let cameraName else { return }
        let screens = currentScreens()
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: cameraID, cameraName: cameraName,
                                                previousCameraName: previousCameraName, screens: screens)
        apply(decision)
    }

    private func apply(_ decision: SetupDecision) {
        switch decision {
        case .newCamera(let name, let previous, let count):
            validScreenIDs = []
            ctx.invalidateCalibrationCache()
            let signature = "newCamera:\(cameraID ?? "")"
            guard signature != dismissedSignature else { pendingDecision = nil; promptWindow.hide(); return }
            pendingDecision = decision
            promptWindow.show(newCameraPrompt(name: name, previous: previous, count: count), on: targetScreen())

        case .ready(let name, let valid, let newScreens, let recent):
            let previousValid = validScreenIDs
            validScreenIDs = Set(valid)
            refitPointer()
            ctx.invalidateCalibrationCache()

            guard !newScreens.isEmpty else {
                dismissedSignature = nil
                pendingDecision = nil
                promptWindow.hide()
                announceRestoreIfNeeded(cameraName: name, previousValid: previousValid, recent: recent)
                return
            }
            let signature = "ready:\(cameraID ?? ""):\(Set(newScreens.map(\.id)).sorted().joined(separator: ","))"
            guard signature != dismissedSignature else { pendingDecision = nil; promptWindow.hide(); return }
            pendingDecision = decision
            promptWindow.show(newScreensPrompt(cameraName: name, valid: valid, newScreens: newScreens), on: targetScreen())
        }
    }

    private func announceRestoreIfNeeded(cameraName: String, previousValid: Set<String>, recent: Date?) {
        guard !validScreenIDs.isEmpty, previousValid != validScreenIDs else { return }
        let signature = "\(cameraID ?? ""):\(validScreenIDs.sorted().joined(separator: ","))"
        guard signature != lastRestoreSignature else { return }
        lastRestoreSignature = signature
        let count = validScreenIDs.count
        let date = recent.map { Self.dateFormatter.string(from: $0) } ?? "earlier"
        ctx.overlay.showBanner(
            title: "Desk setup recognised",
            body: "\(cameraName) with \(count) screen\(count == 1 ? "" : "s"). Calibration from \(date) restored.",
            style: .info, seconds: 4)
    }

    // MARK: - The prompt's actions

    /// "Calibrate this screen" / "Calibrate now", or a held thumbs-up while the prompt shows.
    func start() {
        guard let decision = pendingDecision else { return }
        promptWindow.hide()
        switch decision {
        case .newCamera:
            startFullCalibration()
        case .ready(_, _, let newScreens, _):
            if let cameraID, profiles.profile(forCameraID: cameraID)?.hasModelOnly(validScreenIDs) == true {
                // The old single calibration has no samples to combine with a new screen's; redo them together.
                startFullCalibration(); return
            }
            let ids = Set(newScreens.map(\.id))
            let targets = NSScreen.screens.filter { ScreenGeometry.stableID(of: $0).map(ids.contains) == true }
            guard !targets.isEmpty else { return }
            startSubsetCalibration(targets)
        }
    }

    /// "Later": keep the orange "Needs calibration" state and do not ask again for this same setup.
    func later() {
        dismissedSignature = signature(for: pendingDecision)
        pendingDecision = nil
        promptWindow.hide()
    }

    private func signature(for decision: SetupDecision?) -> String? {
        switch decision {
        case .newCamera: return "newCamera:\(cameraID ?? "")"
        case .ready(_, _, let newScreens, _): return "ready:\(cameraID ?? ""):\(Set(newScreens.map(\.id)).sorted().joined(separator: ","))"
        case nil: return nil
        }
    }

    // MARK: - Storing a calibration

    /// A full manual Calibrate: every connected screen was just covered, replacing this camera's whole profile.
    @discardableResult
    func storeFullCalibration(_ results: [ScreenCalibrationResult]) -> Bool {
        guard let cameraID, let cameraName else { return false }
        guard ctx.pointer.fit(screens: results.map { PointerScreen(id: $0.screenID, frame: $0.frame, samples: $0.samples) }) else { return false }
        let now = Date()
        var profile = CameraProfile(cameraID: cameraID, cameraName: cameraName)
        profile.merge(results.map { ScreenCalibration(screenID: $0.screenID, frame: $0.frame, samples: $0.samples, calibratedAt: now) })
        profiles.setProfile(profile)
        save()
        validScreenIDs = Set(results.map(\.screenID))
        finishCalibration(at: now)
        return true
    }

    /// Only the screens the prompt named were just calibrated; every other screen keeps its own samples,
    /// and the fit combines every currently valid screen (the ones just done plus the ones already valid).
    @discardableResult
    func storeSubsetCalibration(_ results: [ScreenCalibrationResult]) -> Bool {
        guard let cameraID, let cameraName else { return false }
        var profile = profiles.profile(forCameraID: cameraID) ?? CameraProfile(cameraID: cameraID, cameraName: cameraName)
        profile.cameraName = cameraName
        let now = Date()
        profile.merge(results.map { ScreenCalibration(screenID: $0.screenID, frame: $0.frame, samples: $0.samples, calibratedAt: now) })
        let newValid = validScreenIDs.union(results.map(\.screenID))
        // Every valid screen keeps its own model; only the screens just done are new. No screen with samples:
        // nothing meaningful to fit yet (should not happen once any calibration has run), so leave the pointer
        // as it was rather than fit an unusable model.
        let screens = profile.pointerScreens(for: newValid)
        guard screens.isEmpty || ctx.pointer.fit(screens: screens) else { return false }
        profiles.setProfile(profile)
        save()
        validScreenIDs = newValid
        finishCalibration(at: now)
        return true
    }

    private func finishCalibration(at date: Date) {
        ctx.settings.calibratedAt = date
        dismissedSignature = nil
        pendingDecision = nil
        lastRestoreSignature = nil
        promptWindow.hide()
        ctx.invalidateCalibrationCache()
    }

    // MARK: - Migration

    /// The pre-profile app kept one calibration for the whole desk. The first time this runs after the
    /// upgrade, that calibration becomes a profile for the camera in use now and the screens connected now,
    /// so nobody loses what they already set up.
    private func migrateLegacyIfNeeded(cameraID: String, cameraName: String) {
        guard profiles.cameras.isEmpty, ctx.settings.calibration != nil else { return }
        let now = ctx.settings.calibratedAt ?? Date()
        var profile = CameraProfile(cameraID: cameraID, cameraName: cameraName, legacyModel: ctx.settings.calibration)
        profile.merge(currentScreens().map { ScreenCalibration(screenID: $0.id, frame: $0.frame, samples: [], calibratedAt: now) })
        profiles.setProfile(profile)
        save()
    }

    /// Points the pointer at what the screens now valid actually have: a fresh fit of their samples, or the
    /// migrated model when the profile came from the old single calibration.
    private func refitPointer() {
        guard let cameraID, !validScreenIDs.isEmpty, let profile = profiles.profile(forCameraID: cameraID) else { return }
        if !profile.hasModelOnly(validScreenIDs), ctx.pointer.fit(screens: profile.pointerScreens(for: validScreenIDs)) {
            return
        }
        if let legacy = profile.legacyModel {
            ctx.pointer.calibration = legacy
        } else {
            // Nothing usable to fit: pointing off rather than the previous camera's or screen set's model.
            validScreenIDs = []
            ctx.pointer.calibration = nil
        }
    }

    // MARK: - Facts and persistence

    private func currentScreens() -> [ScreenSnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let id = ScreenGeometry.stableID(of: screen) else { return nil }
            return ScreenSnapshot(id: id, name: screen.localizedName, frame: ScreenGeometry.topLeftFrame(of: screen))
        }
    }

    /// The screen the owner is facing (wherever the nose is currently resting), or the main screen.
    private func targetScreen() -> NSScreen {
        if let frame = ctx.state.targetFrame, let screen = ScreenGeometry.screen(containing: CGPoint(x: frame.midX, y: frame.midY)) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func save() {
        ctx.settings.setupProfiles = try? JSONEncoder().encode(profiles)
    }

    private static func load(from settings: SettingsStore) -> SetupProfiles? {
        guard let data = settings.setupProfiles else { return nil }
        return try? JSONDecoder().decode(SetupProfiles.self, from: data)
    }

    // MARK: - Prompt text

    private func newCameraPrompt(name: String, previous: String?, count: Int) -> SetupPromptInfo {
        let seconds = Self.secondsPerScreen * max(count, 1)
        let setupLine = previous.map { "Pointing was set up with \($0). " } ?? ""
        return SetupPromptInfo(
            id: "newCamera:\(cameraID ?? "")",
            title: "New camera: \(name)",
            detail: "\(setupLine)Looking and dictation stay paused until you calibrate. \(count) screen\(count == 1 ? "" : "s"), about \(seconds) seconds.",
            primaryLabel: "Calibrate now",
            onPrimary: { [weak self] in self?.start() },
            onLater: { [weak self] in self?.later() })
    }

    private func newScreensPrompt(cameraName: String, valid: [String], newScreens: [ScreenSnapshot]) -> SetupPromptInfo {
        let seconds = Self.secondsPerScreen * newScreens.count
        let newNames = newScreens.map(\.name).joined(separator: ", ")
        let title = newScreens.count == 1 ? "New screen: \(newNames)" : "New screens: \(newNames)"
        let primaryLabel = newScreens.count == 1 ? "Calibrate this screen" : "Calibrate these screens"
        let validNames = NSScreen.screens
            .compactMap { s -> String? in
                guard let id = ScreenGeometry.stableID(of: s), valid.contains(id) else { return nil }
                return s.localizedName
            }
        let detail: String
        if validNames.isEmpty {
            detail = "Calibrate to start pointing. \(newScreens.count) screen\(newScreens.count == 1 ? "" : "s"), about \(seconds) seconds."
        } else {
            let keep = validNames.joined(separator: ", ")
            detail = "Calibrate just \(newScreens.count == 1 ? "this screen" : "these screens")? About \(seconds) seconds. Your \(keep) keeps its calibration and keeps working."
        }
        return SetupPromptInfo(
            id: "ready:\(cameraID ?? ""):\(Set(newScreens.map(\.id)).sorted().joined(separator: ","))",
            title: title, detail: detail, primaryLabel: primaryLabel,
            onPrimary: { [weak self] in self?.start() },
            onLater: { [weak self] in self?.later() })
    }
}
