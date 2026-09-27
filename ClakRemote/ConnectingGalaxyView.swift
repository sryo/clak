import SwiftUI

/// The wait, and the moment it ends. While waiting, a galaxy of dots turns
/// slowly around `origin`. On connecting they spiral in, the core only ever
/// getting smaller, squeeze down to a speck, and burst from it into a circle
/// that covers the whole surface; the trackpad is swapped in underneath and
/// the circle fades off it.
///
/// Mass reads as density, not size: the core never outgrows a small cluster,
/// so the one big change on screen is the burst.
///
/// Fills its container, which should be the surface, so the burst reaches the
/// corners. Clock-driven off `connectedAt` so the sequence plays out the same
/// however often the view updates.
struct ConnectingGalaxyView: View {
    /// Galaxy centre in this view's own space; nil draws nothing.
    let origin: CGPoint?
    let connectedAt: Date?
    /// Nothing can happen until the person acts, as with Bluetooth denied.
    var isDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When the circle has all but covered the surface, so what's under it
    /// can change unseen.
    static let coveredAfter: TimeInterval = 1.35
    /// When there's nothing left to draw.
    static let finishedAfter: TimeInterval = 1.8
    static let reducedMotionCrossfade: TimeInterval = 0.25

    /// Room the waiting galaxy needs around its centre.
    static let footprint: CGFloat = 2 * (extent + 4)

    private static let dotRadius: CGFloat = 2.8
    private static let count = 96
    private static let extent: Double = 80

    /// Scattered over the disc at random, but never closer than a few points,
    /// so nothing lines up into strands. Seeded, so it's the same galaxy every time.
    private static let homes: [(r: Double, a: Double)] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var points: [(x: Double, y: Double)] = []
        while points.count < count {
            let r = extent * sqrt(next()), a = next() * 2 * .pi
            let p = (x: r * cos(a), y: r * sin(a))
            if points.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) > 8 }) { points.append(p) }
        }
        return points.map { (hypot($0.x, $0.y), atan2($0.y, $0.x)) }
    }()
    /// Smaller toward the rim
    private static let sizes: [CGFloat] = homes.map { dotRadius * (1.05 - 0.45 * CGFloat($0.r / extent)) }
    private static let totalArea = sizes.reduce(0) { $0 + $1 * $1 }

    // The connect, in seconds from `connectedAt`. The rim starts falling last.
    private static func fallStart(_ i: Int) -> Double { 0.25 * pow(homes[i].r / extent, 0.7) }
    private static let fallTime = 0.45
    private static let landed = 0.7
    private static let squeezeEnd = 0.82
    private static let burstStart = 0.9
    private static let burstTime = 0.6
    private static let fadeStart = 1.4

    var body: some View {
        GeometryReader { geo in
            if let origin {
                TimelineView(.animation(paused: isDimmed || (reduceMotion && connectedAt == nil))) { tl in
                    let since = connectedAt.map { tl.date.timeIntervalSince($0) } ?? -1
                    // Far enough to clear the corner furthest from the origin
                    let cover = [CGPoint.zero, CGPoint(x: geo.size.width, y: 0), CGPoint(x: 0, y: geo.size.height), CGPoint(x: geo.size.width, y: geo.size.height)]
                        .map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
                    Canvas { ctx, _ in
                        ctx.addFilter(.alphaThreshold(min: 0.5, color: .accentColor))
                        ctx.addFilter(.blur(radius: 0.9))
                        ctx.drawLayer { layer in
                            if reduceMotion {
                                drawStill(in: layer, center: origin)
                            } else {
                                draw(in: layer, center: origin, t: tl.date.timeIntervalSinceReferenceDate, since: since, cover: cover)
                            }
                        }
                    }
                    .opacity(opacity(since))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func opacity(_ since: Double) -> Double {
        let dim = isDimmed ? 0.3 : 1
        guard since >= 0 else { return dim }
        if reduceMotion { return dim * (1 - smooth(since / Self.reducedMotionCrossfade)) }
        return dim * (1 - smooth((since - Self.fadeStart) / 0.35))
    }

    private func drawStill(in layer: GraphicsContext, center c: CGPoint) {
        for (i, home) in Self.homes.enumerated() {
            let r = Self.sizes[i]
            fill(layer, at: CGPoint(x: c.x + home.r * cos(home.a), y: c.y + home.r * sin(home.a)), rx: r, ry: r, angle: 0)
        }
    }

    private func draw(in layer: GraphicsContext, center c: CGPoint, t: Double, since: Double, cover: CGFloat) {
        var absorbed: CGFloat = 0
        var jiggle: CGFloat = 0
        if since < Self.burstStart {
            for (i, home) in Self.homes.enumerated() {
                let r = Self.sizes[i]
                let p = waiting(i, home, t: t)
                guard since >= 0 else {
                    fill(layer, at: CGPoint(x: c.x + p.x, y: c.y + p.y), rx: r, ry: r, angle: 0)
                    continue
                }
                let x = (since - Self.fallStart(i)) / Self.fallTime
                if x >= 1 {
                    absorbed += r * r
                    let tau = since - Self.fallStart(i) - Self.fallTime
                    jiggle += r * r / Self.totalArea * 4 * CGFloat(exp(-9 * tau) * sin(26 * tau))
                    continue
                }
                let here = infall(p, x: max(x, 0)), next = infall(p, x: min(max(x, 0) + 0.02, 1))
                // Shrinking as it falls, stretched along its path
                let squash = 1 - 0.5 * CGFloat(max(x, 0))
                let stretch = 1 + 0.8 * CGFloat(max(x, 0))
                fill(layer, at: CGPoint(x: c.x + here.x, y: c.y + here.y),
                     rx: r * squash * stretch, ry: r * squash / stretch,
                     angle: atan2(next.y - here.y, next.x - here.x))
            }
        }
        guard since >= 0 else { return }
        let jig = min(max(jiggle, -0.05), 0.05)
        let rc = coreRadius(since, absorbed: absorbed / Self.totalArea, cover: cover)
        // A shiver while it's held small, just before the burst
        let shiver: CGFloat = since > Self.squeezeEnd && since < Self.burstStart ? 0.1 * CGFloat(sin(since * 190)) : 0
        fill(layer, at: c, rx: rc * (1 + jig + shiver), ry: rc * (1 - jig - shiver), angle: 0)
    }

    /// Where a dot drifts while waiting: barely drawing together with the
    /// rest, and turning, the core faster than the rim.
    private func waiting(_ i: Int, _ home: (r: Double, a: Double), t: Double) -> CGPoint {
        let k = Double(i)
        let edge = home.r / Self.extent
        let gather = 1 - 0.08 * (0.5 + 0.5 * sin(t * 2 * .pi / 5.5))
        let a = home.a + t * (0.32 - 0.14 * edge)
        let r = home.r * gather
        return CGPoint(
            x: r * cos(a) + 1.5 * sin(t * 2 * .pi / (4.1 + 0.09 * k) + k * 1.9),
            y: r * sin(a) + 1.5 * cos(t * 2 * .pi / (5.3 + 0.07 * k) + k * 2.7)
        )
    }

    /// Gravity pulls it in, accelerating to the end, and it spins up as it
    /// closes like a skater pulling their arms in.
    private func infall(_ p: CGPoint, x: Double) -> CGPoint {
        let fall = x * x * x
        let spin = 2.2 * fall
        let k = 1 - fall
        let cx = p.x * k, cy = p.y * k
        return CGPoint(x: cx * cos(spin) - cy * sin(spin), y: cx * sin(spin) + cy * cos(spin))
    }

    /// Never bigger than a small cluster: fills to ~8.5pt, sinks as the last
    /// mass lands, squeezes to 3pt, holds a beat, then bursts. The burst
    /// starts slow so it visibly comes out of the speck.
    private func coreRadius(_ since: Double, absorbed m: CGFloat, cover: CGFloat) -> CGFloat {
        let accreted = 14 * sqrt(m) * (1 - 0.6 * m * m)
        if since < Self.landed { return accreted }
        if since < Self.squeezeEnd {
            let x = (since - Self.landed) / (Self.squeezeEnd - Self.landed)
            return 5.6 - 2.6 * CGFloat(x * x * x)
        }
        if since < Self.burstStart { return 3 }
        let x = min((since - Self.burstStart) / Self.burstTime, 1)
        let eased = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        return 3 + (cover - 3) * CGFloat(eased)
    }

    private func fill(_ layer: GraphicsContext, at p: CGPoint, rx: CGFloat, ry: CGFloat, angle: Double) {
        guard rx > 0.1 else { return }
        let blob = Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry))
            .applying(CGAffineTransform(rotationAngle: angle))
            .applying(CGAffineTransform(translationX: p.x, y: p.y))
        layer.fill(blob, with: .color(.black))
    }

    private func smooth(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

#Preview {
    ConnectingGalaxyView(origin: CGPoint(x: 180, y: 300), connectedAt: nil)
        .frame(width: 360, height: 600)
        .background(.black)
}
