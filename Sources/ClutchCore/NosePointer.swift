import CoreGraphics
import Foundation

/// Turns head yaw/pitch into a global screen point using a user calibration, then smooths it.
public final class NosePointer {
    struct Model: Codable, Equatable {
        var a, b, c: Double      // x = a*yaw + b*pitch + c
        var d, e, f: Double      // y = d*yaw + e*pitch + f
        var minX, minY, width, height: Double   // bounding box of the calibration targets
    }

    private var model: Model?
    private var filterX = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)
    private var filterY = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)

    public init() {}

    public var isCalibrated: Bool { model != nil }

    /// Least-squares fit of two affine maps. Returns false (and keeps the old model) when there are
    /// fewer than 5 samples or the head angles do not span two independent directions.
    @discardableResult
    public func fit(_ samples: [CalibrationSample]) -> Bool {
        guard samples.count >= 5 else { return false }
        let n = Double(samples.count)
        let my = samples.map(\.yaw).reduce(0, +) / n
        let mp = samples.map(\.pitch).reduce(0, +) / n
        let mx = samples.map { Double($0.target.x) }.reduce(0, +) / n
        let mY = samples.map { Double($0.target.y) }.reduce(0, +) / n

        var syy = 0.0, spp = 0.0, syp = 0.0, syx = 0.0, spx = 0.0, syY = 0.0, spY = 0.0
        for s in samples {
            let dy = s.yaw - my, dp = s.pitch - mp
            let dx = Double(s.target.x) - mx, dY = Double(s.target.y) - mY
            syy += dy * dy; spp += dp * dp; syp += dy * dp
            syx += dy * dx; spx += dp * dx
            syY += dy * dY; spY += dp * dY
        }
        let det = syy * spp - syp * syp
        guard syy / n > 1e-6, spp / n > 1e-6, det > 1e-6 * syy * spp else { return false }

        let a = (syx * spp - spx * syp) / det
        let b = (spx * syy - syx * syp) / det
        let d = (syY * spp - spY * syp) / det
        let e = (spY * syy - syY * syp) / det

        let xs = samples.map { Double($0.target.x) }, ys = samples.map { Double($0.target.y) }
        let minX = xs.min()!, minY = ys.min()!
        let width = xs.max()! - minX, height = ys.max()! - minY
        guard width > 0, height > 0 else { return false }

        let fitted = Model(a: a, b: b, c: mx - a * my - b * mp,
                           d: d, e: e, f: mY - d * my - e * mp,
                           minX: minX, minY: minY, width: width, height: height)
        guard [fitted.a, fitted.b, fitted.c, fitted.d, fitted.e, fitted.f].allSatisfy(\.isFinite) else { return false }
        model = fitted
        resetFilter()
        return true
    }

    public func raw(for h: HeadObservation) -> CGPoint? {
        guard let m = model else { return nil }
        return CGPoint(x: m.a * h.yaw + m.b * h.pitch + m.c, y: m.d * h.yaw + m.e * h.pitch + m.f)
    }

    /// Filtered point. The filter runs in units of the calibration box so its cutoffs mean the same
    /// thing on any display size.
    public func point(for h: HeadObservation) -> CGPoint? {
        guard let m = model, let r = raw(for: h) else { return nil }
        let u = filterX.filter((r.x - m.minX) / m.width, at: h.t)
        let v = filterY.filter((r.y - m.minY) / m.height, at: h.t)
        return CGPoint(x: u * m.width + m.minX, y: v * m.height + m.minY)
    }

    public func resetFilter() {
        filterX.reset()
        filterY.reset()
    }

    public var calibration: Data? {
        get { model.flatMap { try? JSONEncoder().encode($0) } }
        set {
            guard let data = newValue, let decoded = try? JSONDecoder().decode(Model.self, from: data),
                  decoded.width > 0, decoded.height > 0 else { model = nil; resetFilter(); return }
            model = decoded
            resetFilter()
        }
    }
}
