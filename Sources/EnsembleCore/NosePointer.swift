import CoreGraphics
import Foundation

/// One screen's share of a calibration: its id, its global top-left frame, and the samples taken on it.
public struct PointerScreen: Equatable, Sendable {
    public var id: String
    public var frame: CGRect
    public var samples: [CalibrationSample]
    /// The screen's physical size in centimetres, when the caller knows it; otherwise the pointer asks
    /// `NosePointer.screenSizeProvider`. Without a size the screen is not corrected for head position.
    public var physicalSize: CGSize?
    public init(id: String, frame: CGRect, samples: [CalibrationSample], physicalSize: CGSize? = nil) {
        self.id = id; self.frame = frame; self.samples = samples; self.physicalSize = physicalSize
    }
}

/// Turns head yaw/pitch into a global screen point using a user calibration, then smooths it.
///
/// Each screen gets its own affine map, fitted from that screen's samples alone, because one linear map
/// cannot describe screens at different angles and sizes (an angled portrait screen next to a flat
/// landscape one). Which screen the head is aimed at is decided in angle space from the yaw/pitch
/// range each screen was calibrated over, never from where an extrapolated map happens to land.
public final class NosePointer {
    struct Model: Codable, Equatable {
        var a, b, c: Double      // x = a*yaw + b*pitch + c
        var d, e, f: Double      // y = d*yaw + e*pitch + f
        var minX, minY, width, height: Double   // bounding box of the calibration targets
    }

    /// The yaw/pitch rectangle a screen was calibrated over, widened a little so its edges and the
    /// bezel beside them still read as that screen.
    struct AngleRegion: Codable, Equatable {
        var minYaw, maxYaw, minPitch, maxPitch: Double

        init(samples: [CalibrationSample], expand: Double) {
            let ys = samples.map(\.yaw), ps = samples.map(\.pitch)
            let y0 = ys.min()!, y1 = ys.max()!, p0 = ps.min()!, p1 = ps.max()!
            let dy = (y1 - y0) * expand, dp = (p1 - p0) * expand
            minYaw = y0 - dy; maxYaw = y1 + dy; minPitch = p0 - dp; maxPitch = p1 + dp
        }

        /// 0 inside the region, otherwise the straight-line angle to its nearest edge.
        func distance(yaw: Double, pitch: Double) -> Double {
            let dy = max(minYaw - yaw, 0, yaw - maxYaw), dp = max(minPitch - pitch, 0, pitch - maxPitch)
            return (dy * dy + dp * dp).squareRoot()
        }

        /// Offset from the centre in units of half the region's size: a tie-break between overlapping regions.
        func centreness(yaw: Double, pitch: Double) -> Double {
            let hy = max((maxYaw - minYaw) / 2, 1e-9), hp = max((maxPitch - minPitch) / 2, 1e-9)
            let ny = (yaw - (minYaw + maxYaw) / 2) / hy, np = (pitch - (minPitch + maxPitch) / 2) / hp
            return (ny * ny + np * np).squareRoot()
        }
    }

    struct ScreenModel: Codable, Equatable {
        var id: String
        var frame: CGRect
        var model: Model         // maps to points local to `frame`
        var region: AngleRegion
        /// Nil for a calibration without head positions (saved by an older version) or one that did not fit.
        var geometry: PositionGeometry?
    }

    private struct Stored: Codable { var screens: [ScreenModel] }

    /// How far (in angle units) the head must be past a shared edge before the pointer changes screen.
    static let switchHysteresis = 0.02
    /// Each side of a calibrated range is widened by this share of the range. The calibration dots sit 8% in
    /// from each screen edge, so about 10% reaches the edge itself.
    static let regionExpansion = 0.15

    /// Set only by the legacy single-model path (`fit(_:)`, or a pre-profile saved model).
    private var model: Model?
    private var screenModels: [ScreenModel] = []
    private var currentScreen: Int?
    private var filterX = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)
    private var filterY = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)
    private var positionTracker = HeadPositionTracker()

    /// When true (the default) a screen with a fitted geometry is aimed by where the head is as well as where
    /// it points. False is exactly the angle-only pointer.
    public var correctsForPosition = true

    /// Looks up a screen's physical size in centimetres by id, at fit time, for screens whose `PointerScreen`
    /// carries none. The app sets this from the display's reported size.
    public var screenSizeProvider: ((String) -> CGSize?)?

    public init() {}

    /// The fitted geometry for a screen, for tests and diagnostics.
    func geometry(forScreen id: String) -> PositionGeometry? { screenModels.first { $0.id == id }?.geometry }

    public var isCalibrated: Bool { model != nil || !screenModels.isEmpty }

    /// The screen the pointer is currently aimed at, or nil before the first reading, with a single
    /// (legacy) model, or when uncalibrated.
    public var activeScreenID: String? { currentScreen.map { screenModels[$0].id } }

    /// Least-squares fit of two affine maps. Returns false when there are fewer than 5 samples or the
    /// head angles do not span two independent directions. A single map over all the samples, with no
    /// notion of screens: the path a calibration from before profiles takes, and what one-off callers use.
    @discardableResult
    public func fit(_ samples: [CalibrationSample]) -> Bool {
        guard let fitted = Self.fitAffine(samples, origin: .zero) else { return false }
        model = fitted
        screenModels = []
        currentScreen = nil
        resetFilter()
        return true
    }

    /// Fits one map per screen. All-or-nothing: if any screen's samples cannot be fitted the old
    /// calibration is kept and this returns false. With exactly one screen the pointer behaves as a single
    /// map would (no clamping, no gap rule), so a one-screen desk points as it always did.
    @discardableResult
    public func fit(screens: [PointerScreen]) -> Bool {
        guard !screens.isEmpty else { return false }
        var out: [ScreenModel] = []
        for s in screens {
            guard let m = Self.fitAffine(s.samples, origin: s.frame.origin),
                  s.frame.width > 0, s.frame.height > 0 else { return false }
            let size = s.physicalSize ?? screenSizeProvider?(s.id)
            let geometry = size.flatMap {
                PositionGeometry.fit(samples: s.samples, frame: s.frame, sizeCm: $0, slopeX: m.a, slopeY: m.e)
            }
            out.append(ScreenModel(id: s.id, frame: s.frame, model: m,
                                   region: AngleRegion(samples: s.samples, expand: Self.regionExpansion),
                                   geometry: geometry))
        }
        screenModels = out
        model = nil
        currentScreen = nil
        resetFilter()
        return true
    }

    /// Fits an affine map from the samples to points relative to `origin`.
    private static func fitAffine(_ samples: [CalibrationSample], origin: CGPoint) -> Model? {
        guard samples.count >= 5 else { return nil }
        let n = Double(samples.count)
        let tx = samples.map { Double($0.target.x - origin.x) }, ty = samples.map { Double($0.target.y - origin.y) }
        let my = samples.map(\.yaw).reduce(0, +) / n
        let mp = samples.map(\.pitch).reduce(0, +) / n
        let mx = tx.reduce(0, +) / n
        let mY = ty.reduce(0, +) / n

        var syy = 0.0, spp = 0.0, syp = 0.0, syx = 0.0, spx = 0.0, syY = 0.0, spY = 0.0
        for (i, s) in samples.enumerated() {
            let dy = s.yaw - my, dp = s.pitch - mp
            let dx = tx[i] - mx, dY = ty[i] - mY
            syy += dy * dy; spp += dp * dp; syp += dy * dp
            syx += dy * dx; spx += dp * dx
            syY += dy * dY; spY += dp * dY
        }
        let det = syy * spp - syp * syp
        guard syy / n > 1e-6, spp / n > 1e-6, det > 1e-6 * syy * spp else { return nil }

        let a = (syx * spp - spx * syp) / det
        let b = (spx * syy - syx * syp) / det
        let d = (syY * spp - spY * syp) / det
        let e = (spY * syy - syY * syp) / det

        let minX = tx.min()!, minY = ty.min()!
        let width = tx.max()! - minX, height = ty.max()! - minY
        guard width > 0, height > 0 else { return nil }

        let fitted = Model(a: a, b: b, c: mx - a * my - b * mp,
                           d: d, e: e, f: mY - d * my - e * mp,
                           minX: minX, minY: minY, width: width, height: height)
        guard [fitted.a, fitted.b, fitted.c, fitted.d, fitted.e, fitted.f].allSatisfy(\.isFinite) else { return nil }
        return fitted
    }

    private static func apply(_ m: Model, yaw: Double, pitch: Double) -> CGPoint? {
        let x = m.a * yaw + m.b * pitch + m.c, y = m.d * yaw + m.e * pitch + m.f
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The angles to feed screen `i`'s map for this reading: the reading's own, or, when the head is away
    /// from where that screen was calibrated, the angles the same aim would have had at the calibration
    /// spot. Nil when the reading points away from that screen altogether.
    private func angles(for index: Int, _ h: HeadObservation, position: HeadPosition?) -> (yaw: Double, pitch: Double)? {
        guard let position, let g = screenModels[index].geometry else { return (h.yaw, h.pitch) }
        return g.equivalentAngles(position: position, yaw: h.yaw, pitch: h.pitch)
    }

    /// The screen to use for this reading, with the angles to use on it. Closest calibrated angle range
    /// wins; the screen already in use keeps it unless another is clearly closer, so the pointer does not
    /// flicker along a shared edge.
    private func chooseScreen(for h: HeadObservation, position: HeadPosition?) -> (index: Int, yaw: Double, pitch: Double)? {
        var scored: [(d: Double, c: Double, yaw: Double, pitch: Double)] = []
        for i in screenModels.indices {
            if let a = angles(for: i, h, position: position) {
                scored.append((screenModels[i].region.distance(yaw: a.yaw, pitch: a.pitch),
                               screenModels[i].region.centreness(yaw: a.yaw, pitch: a.pitch), a.yaw, a.pitch))
            } else {
                scored.append((.infinity, .infinity, h.yaw, h.pitch))
            }
        }
        var best = 0
        for i in 1..<scored.count where (scored[i].d, scored[i].c) < (scored[best].d, scored[best].c) { best = i }
        guard scored[best].d.isFinite else { return nil }
        if let cur = currentScreen, cur < scored.count, cur != best,
           scored[cur].d <= scored[best].d + Self.switchHysteresis { best = cur }
        return (best, scored[best].yaw, scored[best].pitch)
    }

    /// The map's point on screen `index`, or nil when it lands in the gap beyond the screen's edge: a point
    /// just outside is clamped onto the screen, one further out is no target.
    private func resolve(_ index: Int, yaw: Double, pitch: Double) -> CGPoint? {
        let s = screenModels[index]
        guard let local = Self.apply(s.model, yaw: yaw, pitch: pitch) else { return nil }
        if screenModels.count == 1 { return CGPoint(x: local.x + s.frame.minX, y: local.y + s.frame.minY) }
        let w = s.frame.width, ht = s.frame.height
        let cx = min(max(local.x, 0), w), cy = min(max(local.y, 0), ht)
        let margin = max(40, 0.08 * min(w, ht))
        guard hypot(local.x - cx, local.y - cy) <= margin else { return nil }
        return CGPoint(x: cx + s.frame.minX, y: cy + s.frame.minY)
    }

    /// The position to correct with, or nil when correction is off or the reading has none worth using.
    private func usablePosition(_ h: HeadObservation, smoothed: Bool) -> HeadPosition? {
        guard correctsForPosition else { return nil }
        if smoothed { return positionTracker.update(h.position, at: h.t) }
        return h.position.flatMap { HeadPositionTracker.isPlausible($0) ? $0 : nil }
    }

    public func raw(for h: HeadObservation) -> CGPoint? {
        guard h.yaw.isFinite, h.pitch.isFinite else { return nil }
        if let m = model { return Self.apply(m, yaw: h.yaw, pitch: h.pitch) }
        guard !screenModels.isEmpty, let c = chooseScreen(for: h, position: usablePosition(h, smoothed: false)) else { return nil }
        return resolve(c.index, yaw: c.yaw, pitch: c.pitch)
    }

    /// Filtered point. The filter runs in units of the calibration box so its cutoffs mean the same
    /// thing on any display size. When the aimed screen changes the filter restarts, so the pointer
    /// lands on the new screen instead of dragging across the bezel.
    public func point(for h: HeadObservation) -> CGPoint? {
        guard h.t.isFinite, h.yaw.isFinite, h.pitch.isFinite else { return nil }
        if let m = model {
            guard let r = Self.apply(m, yaw: h.yaw, pitch: h.pitch) else { return nil }
            let u = filterX.filter((r.x - m.minX) / m.width, at: h.t)
            let v = filterY.filter((r.y - m.minY) / m.height, at: h.t)
            return CGPoint(x: u * m.width + m.minX, y: v * m.height + m.minY)
        }
        guard !screenModels.isEmpty else { return nil }
        let position = usablePosition(h, smoothed: true)
        guard let c = chooseScreen(for: h, position: position), let r = resolve(c.index, yaw: c.yaw, pitch: c.pitch) else { return nil }
        let index = c.index
        if index != currentScreen { filterX.reset(); filterY.reset(); currentScreen = index }
        let s = screenModels[index], m = s.model
        let lx = r.x - s.frame.minX, ly = r.y - s.frame.minY
        let u = filterX.filter((lx - m.minX) / m.width, at: h.t)
        let v = filterY.filter((ly - m.minY) / m.height, at: h.t)
        return CGPoint(x: u * m.width + m.minX + s.frame.minX, y: v * m.height + m.minY + s.frame.minY)
    }

    /// Smoothing from 0 (light, quickest) to 1 (heaviest, steadiest). Lower minCutoff = steadier when still;
    /// lower beta = less eager to follow fast motion.
    public func setSmoothing(_ level: Double) {
        let k = min(max(level, 0), 1)
        let minCutoff = 1.0 - 0.9 * k        // 1.0 Hz ... 0.1 Hz
        let beta = 4.0 - 3.4 * k             // 4.0 ... 0.6
        filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: 1)
        filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: 1)
    }

    public func resetFilter() {
        filterX.reset()
        filterY.reset()
        positionTracker.reset()
    }

    public var calibration: Data? {
        get {
            if !screenModels.isEmpty { return try? JSONEncoder().encode(Stored(screens: screenModels)) }
            return model.flatMap { try? JSONEncoder().encode($0) }
        }
        set {
            model = nil
            screenModels = []
            currentScreen = nil
            resetFilter()
            guard let data = newValue else { return }
            if let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.screens.isEmpty,
               stored.screens.allSatisfy({ $0.model.width > 0 && $0.model.height > 0 && $0.frame.width > 0 && $0.frame.height > 0 }) {
                screenModels = stored.screens
            } else if let decoded = try? JSONDecoder().decode(Model.self, from: data), decoded.width > 0, decoded.height > 0 {
                model = decoded
            }
        }
    }
}
