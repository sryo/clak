import CoreGraphics
import Foundation

/// What a Mac does with one axis of Clak Remote's scroll wheel, as
/// IOHIDFamily's IOHIDScrollAccelerator does it.
///
/// Clak Remote publishes no scroll curves, so the Mac falls back to its
/// default acceleration table, scaled by the wheel's resolution in counts per
/// inch. It judges how fast the wheel turns from the average gap between the
/// last few reports and how many counts they carried, so reports close
/// together are each worth far more: recorded at the default resolution of 9,
/// the first tick after a pause scrolled a tenth of a line and the sixth
/// nearly nine.
struct MacWheel {
    /// Wheel acceleration at the Mac's default scroll speed.
    static let acceleration = 0.3125
    /// The resolution Clak Remote's wheel declares.
    static let resolution = Double(HIDReportMap.highResolutionScrollCountsPerInch)

    private let multiplier: (Double) -> Double

    init(resolution: Double = MacWheel.resolution) {
        multiplier = TableAcceleration.defaultTable(
            acceleration: Self.acceleration, resolution: resolution, rate: MacPointer.frameRate)
    }

    /// Gaps (ms) and sizes of the last ticks, newest last, as the Mac keeps them.
    private var history: [(gap: Double, size: Double)] = []
    private var lastTime: Double?
    private var direction = 0

    /// Lines the Mac scrolls for a report of `counts` (signed) at `time`, in
    /// seconds, remembering it.
    mutating func tick(counts: Int, at time: Double) -> Double {
        let direction = counts > 0 ? 1 : -1
        let gap = lastTime.map { (time - $0) * 1000 } ?? .infinity
        lastTime = time
        if direction != self.direction || gap > 500 {
            history.removeAll()
            self.direction = direction
        }
        history.append((gap, Double(abs(counts))))
        if history.count > 9 { history.removeFirst(history.count - 9) }

        var span = 0.0, sizes = 0.0, count = 0.0
        for event in history.reversed() {
            sizes += event.size
            count += 1
            if event.gap > 150 {
                span += 150
                break
            }
            span += event.gap
            if span >= 500 { break }
        }
        let averageGap = min(max(span / count, 1), 150)
        var speed = (0x2 / 65536.0 * averageGap * averageGap - 0x3BB / 65536.0 * averageGap + 0x18041 / 65536.0)
            * sizes / count
        speed = max(speed, 1 / 65536.0)
        if count > 2 { speed *= (count * 16).squareRoot() / 4 }
        let lines = multiplier(speed) * 0x199A / 65536.0
        // However gently it turns, a report scrolls at least a tenth of a line.
        return Double(direction) * max(lines, 0.1)
    }

}

/// IOHIDFamily's table acceleration, for the one table Clak Remote gets: the
/// default, whose two curves (flat at 0, a ramp to 150 at 1) are blended at
/// the Mac's acceleration setting.
enum TableAcceleration {
    typealias Point = (x: Double, y: Double)

    private static let flat: [Point] = [(1, 1)]
    private static let ramp: [Point] = [
        (0x713B, 0x6000), (0x44EC5, 0x108000), (0xC0000, 0x5F0000), (0x16EC4F, 0x8B0000),
        (0x1D3B14, 0x948000), (0x227627, 0x960000), (0x246276, 0x960000),
        (0x260000, 0x960000), (0x280000, 0x960000),
    ].map { (x: Double($0.0) / 65536, y: Double($0.1) / 65536) }

    /// The accelerated speed for a speed, as a piecewise-linear function.
    static func defaultTable(acceleration: Double, resolution: Double, rate: Double) -> (Double) -> Double {
        var points: [Double: Point] = [:]
        blend(flat, toward: ramp, ratio: acceleration, into: &points)
        blend(ramp, toward: flat, ratio: acceleration, into: &points)

        var segments: [(m: Double, b: Double, x: Double)] = []
        var previous: Point = (0, 0)
        for point in points.values.sorted(by: { $0.x < $1.x }) {
            let next: Point = (point.x * resolution / rate, point.y * 96 / 67)
            let m = (next.y - previous.y) / (next.x - previous.x)
            segments.append((m, next.y - m * next.x, next.x))
            previous = next
        }
        return { speed in
            var segment = segments[0]
            for s in segments {
                segment = s
                if !(speed > s.x) { break }
            }
            return segment.m * speed + segment.b
        }
    }

    private static func blend(_ from: [Point], toward other: [Point], ratio: Double, into points: inout [Double: Point]) {
        var index = 0
        var p0: Point = (0, 0)
        var p1 = other[0]
        for p in from {
            while p.x > p1.x, index < other.count - 1 {
                p0 = p1
                index += 1
                p1 = other[index]
            }
            let m = (p1.y - p0.y) / (p1.x - p0.x)
            let y = p.x * m + (p1.y - m * p1.x)
            points[p.x] = (p.x, min(p.y, y) + abs(p.y - y) * ratio)
        }
    }
}

/// How a Mac's trackpad scrolls, the feel to match.
enum MacScroll {
    /// A wheel line, in points on the Mac.
    static let pixelsPerLine = 10.0
    /// The trackpad's scroll speed setting at its default.
    static let trackpadAcceleration = 0.3125
    /// About how often a trackpad reports while scrolling.
    static let trackpadReportRate = 90.0

    private static let curve = ParametricAcceleration(curves: trackpadCurves, index: trackpadAcceleration)

    /// Points per second a trackpad scrolls for fingers moving this fast:
    /// 400 counts per inch in regular reports, through the same speed
    /// estimate as the wheel, then the trackpad's own scroll curve.
    static func trackpadPixelsPerSecond(fingerInchesPerSecond speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        let counts = speed * MacPointer.resolution / trackpadReportRate
        let gap = 1000 / trackpadReportRate
        let wheelSpeed = (0x2 / 65536.0 * gap * gap - 0x3BB / 65536.0 * gap + 0x18041 / 65536.0) * counts
        let scale = curve(wheelSpeed * MacPointer.frameRate / MacPointer.resolution) * 96 / 67 / wheelSpeed
        return speed * MacPointer.resolution * scale
    }

    // The trackpad's HIDScrollAccelCurves, as a Mac publishes them.
    private static let trackpadCurves: [ParametricAcceleration.Curve] = [
        (0, 65536, 0, 393216, 786432), (8192, 62259, 39322, 406323, 786432),
        (32768, 58982, 58982, 419430, 786432), (45056, 55706, 78643, 432538, 786432),
        (57344, 52429, 91750, 445645, 786432), (65536, 49152, 104858, 458752, 786432),
        (98304, 45875, 117965, 471859, 786432), (131072, 42598, 131072, 484966, 786432),
        (163840, 39322, 144179, 498074, 786432), (196608, 36045, 157286, 511181, 786432),
    ].map { f in
        let one = 65536.0
        return .init(index: Double(f.0) / one, gainLinear: Double(f.1) / one, gainParabolic: Double(f.2) / one,
                     tangentSpeedLinear: Double(f.3) / one, tangentSpeedParabolicRoot: Double(f.4) / one)
    }
}

/// Turns finger movement along one scroll axis into wheel counts, one report
/// per touch sample, sized so the Mac scrolls as its trackpad would.
///
/// The Mac values counts by how many arrive and how close together, and
/// Bluetooth hands them over in batches, one per connection event. So each
/// size comes from a table of what the Mac does with a steady stream of
/// reports that size, batched the way the link batches them, and the fraction
/// of a count left over carries to the next touch. Nothing predicts single
/// reports, so there is nothing to fall out of step with the link: each
/// delivery carries three or four small reports and moves the page about the
/// same as the last.
struct ScrollAccelerator {
    /// Time between Bluetooth connection events to a Mac, measured.
    static let linkInterval = 0.0301
    private static let maxCounts = 127
    /// The link carries about two reports per connection event; any more
    /// only queue behind it.
    private static let maxReportsPerEvent = 2

    private var carry = 0.0
    /// Pixels per report at each size, 0...127, by reports per delivery in
    /// tenths: built when a stream at that pace first needs one.
    private var tables: [Int: [Double]] = [:]

    /// The reports to send for this much finger movement along the axis, in
    /// points, positive in the wheel's positive direction: usually one, and
    /// more in the same connection event when a fast flick needs more counts
    /// than a report can carry.
    mutating func reports(forFingerMoved distance: CGFloat, over interval: Double) -> [Int] {
        guard distance != 0 else { return [] }
        let dt = min(max(interval, 1.0 / 240), 0.05)
        let inchesPerSecond = abs(Double(distance)) / dt / Double(PointerAccelerator.pointsPerInch)
        let pixels = MacScroll.trackpadPixelsPerSecond(fingerInchesPerSecond: inchesPerSecond) * dt
        let perEvent = Self.linkInterval / dt
        // The fewest equal reports that can carry it.
        var share = 1
        var counts = self.counts(forPixels: pixels, reportsPerDelivery: perEvent)
        while counts >= Double(Self.maxCounts), share < Self.maxReportsPerEvent {
            share += 1
            counts = self.counts(forPixels: pixels / Double(share), reportsPerDelivery: perEvent * Double(share))
        }
        carry += (distance > 0 ? 1 : -1) * counts * Double(share)
        let whole = Int(carry)
        carry -= Double(whole)
        guard whole != 0 else { return [] }
        let each = whole / share
        let extra = whole - each * share
        return (0..<share).map { $0 < abs(extra) ? each + extra.signum() : each }
            .filter { $0 != 0 }
            .map { max(-Self.maxCounts, min(Self.maxCounts, $0)) }
    }

    mutating func reset() {
        carry = 0
    }

    /// The report size, fractional, whose steady stream scrolls this many
    /// pixels a report.
    private mutating func counts(forPixels pixels: Double, reportsPerDelivery: Double) -> Double {
        let key = Int((reportsPerDelivery * 10).rounded())
        if tables[key] == nil { tables[key] = Self.table(reportsPerDelivery: Double(key) / 10) }
        let table = tables[key]!
        for n in 1...Self.maxCounts where table[n] >= pixels {
            let below = table[n - 1]
            return Double(n - 1) + (pixels - below) / (table[n] - below)
        }
        return Double(Self.maxCounts)
    }

    /// What the Mac scrolls per report for a steady stream of each size,
    /// delivered in batches at this average number of reports per connection
    /// event, once its speed estimate has settled.
    private static func table(reportsPerDelivery: Double) -> [Double] {
        (0...maxCounts).map { counts in
            guard counts > 0 else { return 0 }
            var wheel = MacWheel()
            var pixels = 0.0
            var reports = 0
            for delivery in 0..<24 {
                let batch = Int(Double(delivery + 1) * reportsPerDelivery) - Int(Double(delivery) * reportsPerDelivery)
                let time = 1 + Double(delivery) * linkInterval
                for i in 0..<batch {
                    let lines = wheel.tick(counts: counts, at: time + Double(i) * 0.0005)
                    if delivery >= 12 {
                        pixels += lines * MacScroll.pixelsPerLine
                        reports += 1
                    }
                }
            }
            return reports > 0 ? pixels / Double(reports) : 0
        }
    }
}

/// Paces scroll out as one report per Bluetooth connection event, the same
/// size each time at a steady finger speed.
///
/// The link carries about two reports per connection event, roughly every
/// 30 ms, and the Mac moves the page once per event; anything sent faster only
/// queues. Touches arrive at 60 Hz, so the movement pending at a send is one
/// touch's worth one time and two the next, and paying out whatever is pending
/// halves the page's step every few frames. Instead each send pays out the
/// finger's recent speed times the interval, nudged a little toward what is
/// really pending so the total still matches the finger. Sends keep a fixed
/// schedule at the link's interval, driven by a timer finer than touches, so
/// on average each event gets one.
struct ScrollPacer {
    static let interval = ScrollAccelerator.linkInterval
    /// How quickly the speed estimate follows the finger.
    private static let speedSmoothing = 0.05
    /// Share of the gap between what is pending and what the speed implies
    /// that each send closes: enough to keep the total true, small enough
    /// that touch-sized lumps barely show.
    private static let correction: CGFloat = 0.1
    /// A finger this long without moving has stopped.
    private static let stillAfter = 0.05

    private var pending: CGFloat = 0
    private var speed: CGFloat = 0
    private var nextSend: Double?
    private var lastTake: Double?
    private var movedSinceTake = false
    private var still = 0.0

    var isSettled: Bool { pending == 0 && speed == 0 }

    /// A touch sample: the finger moved this far along the axis since the last.
    mutating func finger(moved distance: CGFloat, over interval: Double) {
        pending += distance
        let dt = max(interval, 1.0 / 240)
        speed += (distance / CGFloat(dt) - speed) * CGFloat(min(1, dt / Self.speedSmoothing))
        movedSinceTake = true
    }

    /// A tick of a fling: it moves at this speed, in points per second.
    mutating func fling(speed flingSpeed: CGFloat, over interval: Double) {
        pending += flingSpeed * CGFloat(interval)
        speed = flingSpeed
        movedSinceTake = true
    }

    /// The movement to send at this tick, or nil if it isn't a send slot.
    mutating func take(at time: Double) -> CGFloat? {
        if movedSinceTake {
            still = 0
        } else if let lastTake {
            still += time - lastTake
        }
        movedSinceTake = false
        lastTake = time
        if still > Self.stillAfter { speed = 0 }

        guard !isSettled else {
            nextSend = nil
            return nil
        }
        let slot = nextSend ?? time
        guard time >= slot else { return nil }
        // Keep to the schedule, but don't burst to catch up after a stall.
        nextSend = max(slot + Self.interval, time - Self.interval / 2)

        let amount: CGFloat
        if speed == 0 {
            amount = pending
        } else {
            let nominal = speed * CGFloat(Self.interval)
            amount = nominal + (pending - nominal) * Self.correction
        }
        pending -= amount
        return amount
    }

    mutating func reset() {
        self = ScrollPacer()
    }
}
