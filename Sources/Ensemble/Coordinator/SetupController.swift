import AppKit
import EnsembleCore

/// What a calibration run is for, fixed when it starts.
enum CalibrationPurpose: Equatable {
    /// Every screen, replacing everything this spot held (nil or unknown: the first spot, or a new one).
    case wholeSpot(String?)
    /// Only the screens covered, into this spot; its other screens and every other spot keep theirs.
    case screens(String?)
    /// A new spot beside the ones already saved.
    case newSpot
}

/// The screens a calibration visits, what it is for, and a line for its intro naming the position, if any.
struct CalibrationPlan {
    let screens: [NSScreen]
    let purpose: CalibrationPurpose
    let note: String?
    /// For a run over only some screens: an already calibrated screen and its centre sample, so the first dot needs
    /// a turn away from that screen rather than only stillness.
    var firstDotFrom: (frame: CGRect, centre: CalibrationSample)? = nil
}

/// What storing a calibration run came to.
enum CalibrationStoreOutcome: Equatable {
    case saved
    /// The samples could not be fitted, or no screen is valid with them.
    case didNotFit
    /// `screenID`'s samples repeat the angle range of `otherScreenID`, already calibrated from the same spot.
    case repeats(screenID: String, otherScreenID: String)
}

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
    private var debounceTask: Task<Void, Never>?
    /// Which camera reports and refits are news; see `SetupChangeFilter`.
    private var changes = SetupChangeFilter()
    /// Connected screens with their stable ids, in `NSScreen.screens` order. Read on every head reading
    /// (`isUsable`) and status pass; rebuilt only when the arrangement changes.
    private var screenIDCache: [(frame: CGRect, id: String?)]?
    private let promptWindow = SetupPromptController()

    /// Wired by the coordinator: the manual calibration path (every current screen, the position in use) and a
    /// path that runs a given plan. Both end up back here through `storeCalibration`.
    var startFullCalibration: () -> Void = {}
    var runPlan: (CalibrationPlan) -> Void = { _ in }

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
        let screens = connectedScreens
        // Same rule as `ScreenGeometry.screen(containing:)`: off every screen counts as the first one.
        guard let id = (screens.first { $0.frame.contains(point) } ?? screens.first)?.id else { return false }
        return validScreenIDs.contains(id)
    }

    /// The stable ids of the connected screens, from the cache.
    var connectedScreenIDs: [String] { connectedScreens.compactMap(\.id) }

    private var connectedScreens: [(frame: CGRect, id: String?)] {
        if let cached = screenIDCache { return cached }
        let fresh = NSScreen.screens.map { (frame: ScreenGeometry.topLeftFrame(of: $0), id: ScreenGeometry.stableID(of: $0)) }
        screenIDCache = fresh
        return fresh
    }

    // MARK: - Detection

    /// The engine reports which camera it is actually using, at every start and camera switch, and again with
    /// every frame-rate reading (about once a second). Only a different camera is acted on: re-deciding the setup
    /// each second refitted the pointer, and that restarted its smoothing, a visible hitch in the dot.
    func cameraInUse(id: String, name: String) {
        guard changes.cameraReported(id: id, name: name) else { return }
        migrateLegacyIfNeeded(cameraID: id, cameraName: name)
        if let old = cameraID, old != id {
            previousCameraName = cameraName
            // A different camera's angles mean nothing here; do not point with its leftover model.
            ctx.pointer.calibration = nil
            changes.forgetFit()
            ctx.invalidateCalibrationCache()
        }
        cameraID = id
        cameraName = name
        if ctx.settings.lastCameraID != id { ctx.settings.lastCameraID = id }
        scheduleEvaluate()
    }

    /// The screen arrangement changed (`NSApplication.didChangeScreenParametersNotification`).
    func screensChanged() {
        screenIDCache = nil
        scheduleEvaluate()
    }

    /// At launch, before the camera starts: point with the saved calibration of the camera used last, so the
    /// pointer is calibrated from the first head reading instead of a second or more after the camera reports.
    /// That report then confirms it (the same camera and screens change nothing) or replaces it. False when there
    /// is nothing saved that fits the screens connected now.
    func restoreAtLaunch() -> Bool {
        // The screen arrangement in Settings and the panel shows from launch, before the camera reports.
        defer { publish() }
        guard let id = ctx.settings.lastCameraID, let profile = profiles.profile(forCameraID: id),
              case .ready(_, let valid, _, _) = SetupEvaluator.evaluate(
                profiles: profiles, cameraID: id, cameraName: profile.cameraName, previousCameraName: nil, screens: currentScreens()),
              !valid.isEmpty else { return false }
        cameraID = id
        cameraName = profile.cameraName
        validScreenIDs = Set(valid)
        refitPointer()
        ctx.invalidateCalibrationCache()
        return ctx.pointer.isCalibrated
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
        defer { publish() }
        screenIDCache = nil
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
            if let screen = targetScreen() { promptWindow.show(newCameraPrompt(name: name, previous: previous, count: count), on: screen) }

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
            if let screen = targetScreen() { promptWindow.show(newScreensPrompt(cameraName: name, valid: valid, newScreens: newScreens), on: screen) }
        }
    }

    private func announceRestoreIfNeeded(cameraName: String, previousValid: Set<String>, recent: Date?) {
        guard !validScreenIDs.isEmpty, previousValid != validScreenIDs else { return }
        let signature = "\(cameraID ?? ""):\(validScreenIDs.sorted().joined(separator: ","))"
        // Persisted, so a relaunch on the same setup does not announce it again.
        guard signature != ctx.settings.lastRestoreSignature else { return }
        ctx.settings.lastRestoreSignature = signature
        let count = validScreenIDs.count
        let date = recent.map { Self.dateFormatter.string(from: $0) } ?? "earlier"
        ctx.overlay.showBanner(
            title: "Desk setup recognised",
            body: "\(cameraName) with \(count) screen\(count == 1 ? "" : "s"). Calibration from \(date) restored.",
            style: .success, seconds: 4)
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
            runPlan(CalibrationPlan(screens: targets, purpose: .screens(spotInUseID), note: nil,
                                    firstDotFrom: firstDotReference(for: targets)))
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

    /// The profile of the camera in use.
    private var profile: CameraProfile? { cameraID.flatMap { profiles.profile(forCameraID: $0) } }

    /// The spot the pointer uses now, or the first spot before any reading picked one.
    var spotInUseID: String? {
        guard let spots = profile?.spots, let first = spots.first else { return nil }
        if let id = ctx.pointer.activeSpotID, spots.contains(where: { $0.id == id }) { return id }
        return first.id
    }

    /// What a Calibrate press runs. Nil when the screen asked for is no longer connected.
    func plan(for request: CalibrationRequest) -> CalibrationPlan? {
        let all = NSScreen.screens
        let profile = self.profile
        let spots = profile?.spots ?? []
        let inUse = spotInUseID
        let inUseName = spots.first { $0.id == inUse }?.name
        let several = spots.count > 1
        // The old single calibration has no samples to sit beside new ones; only a full calibration replaces it.
        let modelOnly = profile?.hasModelOnly(validScreenIDs) == true
        let whole = CalibrationPlan(screens: all, purpose: .wholeSpot(inUse),
                                    note: several ? inUseName.map { "Replaces \($0), the position in use now." } : nil)
        switch request {
        case .recalibrate:
            return whole
        case .newPosition:
            guard let profile, !profile.spots.isEmpty, !modelOnly else { return whole }
            return CalibrationPlan(screens: all, purpose: .newSpot,
                                   note: "Adds \(profile.nextSpot.name). Sit or stand where you want it to work.")
        case .screen(let id):
            if modelOnly { return whole }
            let targets = all.filter { ScreenGeometry.stableID(of: $0) == id }
            guard !targets.isEmpty else { return nil }
            return CalibrationPlan(screens: targets, purpose: .screens(inUse),
                                   note: several ? inUseName.map { "Updates this screen in \($0), the position in use now." } : nil,
                                   firstDotFrom: firstDotReference(for: targets))
        }
    }

    /// The calibrated screen nearest the first of `targets`, in the spot in use, for that run's first dot.
    private func firstDotReference(for targets: [NSScreen]) -> (frame: CGRect, centre: CalibrationSample)? {
        guard let first = targets.first, let spot = spotInUseID, let profile else { return nil }
        let ids = Set(targets.compactMap { ScreenGeometry.stableID(of: $0) })
        return profile.neighbour(of: ScreenGeometry.topLeftFrame(of: first), inSpot: spot,
                                 validScreenIDs: validScreenIDs, excluding: ids)
    }

    /// A screen's display name, for messages; the id itself when it is no longer connected.
    func name(ofScreenID id: String) -> String {
        NSScreen.screens.first { ScreenGeometry.stableID(of: $0) == id }?.localizedName ?? id
    }

    /// Stores what a calibration run collected as its purpose says, then refits the pointer over every screen
    /// that is valid now, from every spot: each screen keeps its own map per spot, so replacing one screen or one
    /// spot leaves the other screens' maps, planes and regions exactly as they were. Nothing is stored if the
    /// fit fails, or when a screen's samples repeat another screen's angle range from the same spot.
    @discardableResult
    func storeCalibration(_ results: [ScreenCalibrationResult], purpose: CalibrationPurpose) -> CalibrationStoreOutcome {
        guard let cameraID, let cameraName else { return .didNotFit }
        var profile = self.profile ?? CameraProfile(cameraID: cameraID, cameraName: cameraName)
        profile.cameraName = cameraName
        let now = Date()
        let done = results.map { ScreenCalibration(screenID: $0.screenID, frame: $0.frame, samples: $0.samples, calibratedAt: now) }
        func existing(_ id: String?) -> String? {
            id.flatMap { id in profile.spots.contains { $0.id == id } ? id : nil } ?? profile.spots.first?.id
        }
        let spotID: String
        switch purpose {
        case .wholeSpot(let id):
            profile.dropLegacy()
            if let spot = existing(id) { profile.replaceSpot(spot, with: done); spotID = spot } else { spotID = profile.addSpot(done) }
        case .screens(let id):
            if let spot = existing(id) { profile.store(done, inSpot: spot); spotID = spot } else { spotID = profile.addSpot(done) }
        case .newSpot:
            spotID = profile.addSpot(done)
        }
        var next = profiles
        next.setProfile(profile)
        guard case .ready(_, let valid, _, _) = SetupEvaluator.evaluate(
            profiles: next, cameraID: cameraID, cameraName: cameraName, previousCameraName: nil, screens: currentScreens()) else { return .didNotFit }
        let newValid = Set(valid)
        for result in done {
            if let other = profile.screenRepeated(by: result.samples, forScreen: result.screenID, inSpot: spotID, validScreenIDs: newValid) {
                EnsembleLog.write("calibration not saved: \(result.screenID) repeats the angles of \(other) in \(spotID)")
                return .repeats(screenID: result.screenID, otherScreenID: other)
            }
        }
        // A screen still on the migrated model keeps pointing with it (refitPointer); nothing else to fit then.
        var maps = 0
        if !profile.hasModelOnly(newValid) {
            let screens = profile.pointerScreens(for: newValid)
            guard !screens.isEmpty, ctx.pointer.fit(screens: screens) else { return .didNotFit }
            maps = screens.count
            changes.fittedFrom(.init(cameraID: cameraID, validScreenIDs: newValid, profile: profile))
        } else {
            changes.forgetFit()
        }
        profiles = next
        save()
        validScreenIDs = newValid
        finishCalibration(at: now)
        publish()
        let saved = done.map { "\($0.screenID)@\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
        EnsembleLog.write("calibration saved: \(saved) in \(spotID) (\(purpose)); pointing on \(newValid.sorted()) with \(maps) screen maps")
        return .saved
    }

    /// Forgets one saved position; the others keep pointing. A screen only that position covered asks to be
    /// calibrated again, the same as a new screen.
    func removeSpot(_ id: String) {
        guard var profile = self.profile, profile.spots.count > 1 else { return }
        profile.removeSpot(id)
        profiles.setProfile(profile)
        save()
        // Its maps go with it, even if no screen is left to refit.
        ctx.pointer.calibration = nil
        changes.forgetFit()
        evaluate()
    }

    private func finishCalibration(at date: Date) {
        ctx.settings.calibratedAt = date
        dismissedSignature = nil
        pendingDecision = nil
        ctx.settings.lastRestoreSignature = nil
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
    /// migrated model when the profile came from the old single calibration. Skipped when nothing it fits from
    /// changed since the last fit: a refit restarts the pointer's smoothing.
    private func refitPointer() {
        guard let cameraID, !validScreenIDs.isEmpty, let profile = profiles.profile(forCameraID: cameraID) else { return }
        let key = SetupChangeFilter.FitKey(cameraID: cameraID, validScreenIDs: validScreenIDs, profile: profile)
        guard changes.needsFit(key, pointerCalibrated: ctx.pointer.isCalibrated) else { return }
        if !profile.hasModelOnly(validScreenIDs), ctx.pointer.fit(screens: profile.pointerScreens(for: validScreenIDs)) {
            changes.fittedFrom(key)
            return
        }
        if let legacy = profile.legacyModel {
            ctx.pointer.calibration = legacy
            changes.fittedFrom(key)
        } else {
            // Nothing usable to fit: pointing off rather than the previous camera's or screen set's model.
            validScreenIDs = []
            ctx.pointer.calibration = nil
            changes.forgetFit()
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
    /// Nil when no screen is attached (a closed lid with no display): the prompt is skipped and shows on the next change.
    private func targetScreen() -> NSScreen? {
        if let frame = ctx.targetFrame, let screen = ScreenGeometry.screen(containing: CGPoint(x: frame.midX, y: frame.midY)) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// What Settings lists: the camera's saved positions and the connected screens.
    private func publish() {
        let summaries = (profile?.spots ?? []).map { spot -> CalibrationSpotSummary in
            let n = spot.screens.filter { !$0.samples.isEmpty }.count
            let screens = n == 0 ? "Earlier calibration" : "\(n) screen\(n == 1 ? "" : "s")"
            let date = spot.calibratedAt.map { Self.dateFormatter.string(from: $0) }
            return CalibrationSpotSummary(id: spot.id, name: spot.name, detail: [screens, date].compactMap { $0 }.joined(separator: ", "))
        }
        ctx.state.set(\.calibrationSpots, summaries)
        ctx.state.set(\.spotInUse, spotInUseID)
        let all = NSScreen.screens
        let descriptions = all.enumerated().map { ScreenDescription(name: $0.element.localizedName, frame: ScreenGeometry.topLeftFrame(of: $0.element), isMain: $0.offset == 0) }
        let spots = profile?.spots ?? []
        let choices = all.enumerated().compactMap { index, screen -> ScreenChoice? in
            guard let id = ScreenGeometry.stableID(of: screen) else { return nil }
            let place = ScreenLayout.position(of: descriptions[index], among: descriptions)
            var dates: [String: Date] = [:]
            for spot in spots {
                if let screenCalibration = spot.screens.first(where: { $0.screenID == id }) { dates[spot.id] = screenCalibration.calibratedAt }
            }
            return ScreenChoice(id: id, name: all.count > 1 ? "\(screen.localizedName), \(place)" : screen.localizedName,
                                displayName: screen.localizedName, frame: descriptions[index].frame, isMain: index == 0,
                                calibrated: validScreenIDs.contains(id), calibratedAt: dates)
        }
        ctx.state.set(\.screenChoices, choices)
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
