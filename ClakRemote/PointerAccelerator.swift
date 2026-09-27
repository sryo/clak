import CoreGraphics
import Foundation

/// Apple's parametric pointer-acceleration curve, evaluated exactly as
/// IOHIDFamily's IOHIDParametricAcceleration does (including its habit of
/// raising gain times speed, not speed alone, to each power). Three pieces: a
/// polynomial up to the linear tangent speed, the tangent line from there to
/// the parabolic root, and a square root beyond, each joining the last
/// smoothly. Takes a standardised speed and returns an accelerated one.
struct ParametricAcceleration {
    /// One of the curves a HID service publishes as HIDAccelCurves, in
    /// ordinary numbers rather than 16.16 fixed point.
    struct Curve {
        var index: Double
        var gainLinear: Double
        var gainParabolic: Double = 0
        var gainCubic: Double = 0
        var gainQuartic: Double = 0
        var tangentSpeedLinear: Double = 0
        var tangentSpeedParabolicRoot: Double = 0
    }

    private let curve: Curve
    private var tangent = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
    private var m = (0.0, 0.0)
    private var b = (0.0, 0.0)

    /// The curve for a speed setting, interpolated between the two
    /// published curves either side of it, as the Mac does.
    init(curves: [Curve], index: Double) {
        var current = 0
        for (i, c) in curves.enumerated() where index >= c.index { current = i }
        var c = curves[current]
        if c.index < index, current + 1 < curves.count {
            let a = curves[current], n = curves[current + 1]
            let r = (index - a.index) / (n.index - a.index)
            func mix(_ x: Double, _ y: Double) -> Double { x + r * (y - x) }
            c = Curve(index: mix(a.index, n.index),
                      gainLinear: mix(a.gainLinear, n.gainLinear),
                      gainParabolic: mix(a.gainParabolic, n.gainParabolic),
                      gainCubic: mix(a.gainCubic, n.gainCubic),
                      gainQuartic: mix(a.gainQuartic, n.gainQuartic),
                      tangentSpeedLinear: mix(a.tangentSpeedLinear, n.tangentSpeedLinear),
                      tangentSpeedParabolicRoot: mix(a.tangentSpeedParabolicRoot, n.tangentSpeedParabolicRoot))
        }
        curve = c

        let tl = c.tangentSpeedLinear, tp = c.tangentSpeedParabolicRoot
        if tl != 0 {
            m.0 = Self.slope(c, tl)
            b.0 = Self.polynomial(c, tl) - m.0 * tl
            tangent.0 = tl
            if tp != 0 {
                let y1 = m.0 * tp + b.0
                m.1 = 2 * y1 * m.0
                b.1 = y1 * y1 - m.1 * tp
                tangent.1 = tp
            }
        } else if tp != 0 {
            let y0 = Self.polynomial(c, tp)
            m.1 = Self.slope(c, tp)
            b.1 = y0 * y0 - m.1 * tp
            tangent.0 = tp
        }
    }

    func callAsFunction(_ speed: Double) -> Double {
        if speed <= tangent.0 { return Self.polynomial(curve, speed) }
        if speed <= tangent.1, tangent.0 == curve.tangentSpeedLinear { return m.0 * speed + b.0 }
        return (m.1 * speed + b.1).squareRoot()
    }

    private static func polynomial(_ c: Curve, _ x: Double) -> Double {
        c.gainLinear * x + pow(c.gainParabolic * x, 2) + pow(c.gainCubic * x, 3) + pow(c.gainQuartic * x, 4)
    }

    private static func slope(_ c: Curve, _ x: Double) -> Double {
        c.gainLinear + 2 * x * pow(c.gainParabolic, 2) + 3 * x * x * pow(c.gainCubic, 3) + 4 * pow(x, 3) * pow(c.gainQuartic, 4)
    }
}

/// What a Mac does with pointer motion, in points on its screen.
///
/// Clak Remote reaches the Mac as a mouse, so the Mac runs its own mouse
/// acceleration on every report. Aiming for the feel of a Magic Trackpad means
/// knowing both: the trackpad curve is the target, the mouse curve is what
/// stands in the way. Both are Apple's published curves (a Mac lists them in
/// its I/O registry as HIDAccelCurves) at their default and common settings;
/// the phone can't read the Mac's own settings, so a Mac whose Mouse speed has
/// been moved scales the result accordingly.
enum MacPointer {
    /// Counts per inch a Mac assumes for both a mouse and its trackpad.
    static let resolution = 400.0
    /// The frame rate IOHIDFamily standardises speeds to.
    static let frameRate = 67.0
    /// Report rate the Mac's trackpad declares; speeds are measured per report.
    static let trackpadReportRate = 120.0
    /// Points per inch at no acceleration, with the curve's own scale folded in.
    private static let cursorScale = 96.0 / 67.0

    /// The default Mouse speed, which a Mac applies to Clak Remote.
    static let mouseCurve = ParametricAcceleration(curves: mouseCurves, index: 0.6875)
    /// A Magic Trackpad at a brisk speed setting, the feel to match.
    static let trackpadCurve = ParametricAcceleration(curves: trackpadCurves, index: 2)

    /// Points the Mac moves the pointer for one mouse report of this many
    /// counts. Clak Remote declares no report rate, so the Mac takes the
    /// report's own size as the speed, whenever it arrives.
    static func pixels(forCounts counts: Double) -> Double {
        let speed = max(counts.rounded(.down), 1.0 / 65536)
        return counts * mouseCurve(speed * frameRate / resolution) * cursorScale / speed
    }

    static func pixels(forReport report: (dx: Int8, dy: Int8)) -> CGVector {
        let dx = Double(report.dx), dy = Double(report.dy)
        let length = hypot(dx, dy)
        guard length > 0 else { return .zero }
        let scale = pixels(forCounts: length) / length
        return CGVector(dx: dx * scale, dy: dy * scale)
    }

    /// How fast a Magic Trackpad moves the pointer for a finger moving this
    /// fast: 400 counts per inch in 120 reports a second, each standardised
    /// to the Mac's frame rate before the curve.
    static func trackpadPixelsPerSecond(fingerInchesPerSecond speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        let countsPerReport = speed * resolution / trackpadReportRate
        return speed * resolution * trackpadCurve(countsPerReport * frameRate / resolution) * cursorScale / countsPerReport
    }

    // HIDAccelCurves as a Mac publishes them, 16.16 fixed point converted.
    private static let trackpadCurves: [ParametricAcceleration.Curve] = [
        (0, 65536, 0, 0, 484966, 1376256), (8192, 64881, 32768, 5243, 478413, 1310720),
        (32768, 64225, 43254, 6554, 471859, 1245184), (45056, 62915, 54395, 7864, 465306, 1179648),
        (57344, 61604, 65536, 9830, 458752, 1114112), (65536, 60293, 75366, 11796, 458752, 1048576),
        (98304, 58327, 85197, 13763, 458752, 983040), (131072, 56361, 95027, 15729, 458752, 917504),
        (163840, 54395, 108790, 18350, 458752, 851968), (196608, 65536, 123208, 23593, 458752, 786432),
    ].map(curve)

    private static let mouseCurves: [ParametricAcceleration.Curve] = [
        (0, 65536, 0, 0, 524288, 0), (8192, 60293, 26214, 5243, 537395, 1245184),
        (32768, 60948, 36045, 6554, 543949, 1179648), (45056, 61604, 46531, 7864, 550502, 1114112),
        (57344, 62259, 57672, 9830, 557056, 1048576), (65536, 62915, 69468, 11796, 563610, 983040),
        (98304, 63570, 81920, 14418, 570163, 917504), (131072, 64225, 95027, 17695, 576717, 851968),
        (163840, 64881, 108790, 21627, 583270, 786432), (196608, 65536, 123208, 26214, 589824, 786432),
    ].map(curve)

    private static func curve(_ f: (Double, Double, Double, Double, Double, Double)) -> ParametricAcceleration.Curve {
        let one = 65536.0
        return .init(index: f.0 / one, gainLinear: f.1 / one, gainParabolic: f.2 / one, gainCubic: f.3 / one,
                     tangentSpeedLinear: f.4 / one, tangentSpeedParabolicRoot: f.5 / one)
    }
}

/// Turns finger movement on the phone into mouse reports that, once the Mac
/// has run its mouse acceleration on them, move the pointer as a Magic
/// Trackpad would for the same finger movement.
///
/// Each touch sample adds what a trackpad would have moved to a queue of
/// points owed on the Mac; each report takes the count size whose Mac movement
/// best matches what is owed, and subtracts what the Mac will actually move,
/// so rounding carries rather than accumulating.
struct PointerAccelerator {
    /// Points per inch on an iPhone screen (about 153 to 163 across models).
    static let pointsPerInch: CGFloat = 155
    /// Reports carry at most this many counts per axis.
    private static let maxCounts = 127

    /// How far each report size moves the Mac's pointer, 0...127 counts.
    private static let pixelsByCounts: [Double] = (0...maxCounts).map {
        $0 == 0 ? 0 : MacPointer.pixels(forCounts: Double($0))
    }

    private var owed = CGVector.zero

    /// A touch sample: the finger moved this far, in points, since the last.
    mutating func finger(moved delta: CGVector, over interval: Double) {
        let distance = Double(hypot(delta.dx, delta.dy))
        guard distance > 0 else { return }
        // Touches arrive at 60 to 120 Hz; a longer gap is a pause, not slow travel.
        let dt = min(max(interval, 1.0 / 240), 0.05)
        let inchesPerSecond = distance / dt / Double(Self.pointsPerInch)
        let pixels = MacPointer.trackpadPixelsPerSecond(fingerInchesPerSecond: inchesPerSecond) * dt
        let scale = CGFloat(pixels / distance)
        owed.dx += delta.dx * scale
        owed.dy += delta.dy * scale
        // What reports can't carry soon is dropped, as a trackpad's pointer
        // would never have lagged behind the finger to begin with.
        let limit = CGFloat(Self.pixelsByCounts[Self.maxCounts] * 2)
        let length = hypot(owed.dx, owed.dy)
        if length > limit {
            owed.dx *= limit / length
            owed.dy *= limit / length
        }
    }

    /// The next report to send, or nil while less than half a count is owed.
    mutating func nextReport() -> (dx: Int8, dy: Int8)? {
        let length = Double(hypot(owed.dx, owed.dy))
        guard length >= Self.pixelsByCounts[1] / 2 else { return nil }
        let counts = Self.countsClosest(to: length)
        let dx = Int8((Double(owed.dx) / length * Double(counts)).rounded())
        let dy = Int8((Double(owed.dy) / length * Double(counts)).rounded())
        guard dx != 0 || dy != 0 else { return nil }
        let moved = MacPointer.pixels(forReport: (dx, dy))
        owed.dx -= moved.dx
        owed.dy -= moved.dy
        return (dx, dy)
    }

    mutating func reset() {
        owed = .zero
    }

    private static func countsClosest(to pixels: Double) -> Int {
        var low = 1, high = maxCounts
        while low < high {
            let mid = (low + high) / 2
            if pixelsByCounts[mid] < pixels { low = mid + 1 } else { high = mid }
        }
        if low > 1, abs(pixelsByCounts[low - 1] - pixels) < abs(pixelsByCounts[low] - pixels) {
            return low - 1
        }
        return low
    }
}
