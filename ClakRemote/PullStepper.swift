import CoreGraphics

/// Turns a drag off a key into dial steps, around the point where the finger
/// landed.
///
/// The value follows the finger's angle round that centre: clockwise raises,
/// counterclockwise lowers, one step per `stepAngle` at any distance. Moving
/// straight out or in never changes it. What the distance changes is how
/// finely it lands: near the key it lands on whole steps only, and past
/// `fineRadius` on every quarter too, the finest step macOS has for volume and
/// brightness.
///
/// Pure geometry, no UIKit and no clock, so every path can be replayed in a
/// unit test.
struct PullStepper {
    /// One step for the Mac to take: a whole one, or a quarter.
    struct Step: Equatable {
        /// +1 clockwise, -1 counterclockwise.
        let direction: Int
        let isQuarter: Bool
    }

    /// A half turn over the top of the key is the Mac's whole volume or
    /// brightness range, 16 steps.
    static let stepAngle: CGFloat = .pi / 16
    static let quarterAngle: CGFloat = stepAngle / 4
    /// Inside this radius an angle swings wildly for a tiny movement, so it
    /// counts for nothing; it also holds the tap slop.
    static let deadZone: CGFloat = 24
    /// Past this far out the dial also lands on quarters.
    static let fineRadius: CGFloat = 120
    /// How far back in a finger must come to leave the fine zone once in it,
    /// so hovering at the edge doesn't flicker between the two.
    static let fineOverlap: CGFloat = 10

    /// False for a value with no quarter step, like seeking.
    let allowsFine: Bool

    init(allowsFine: Bool = true) {
        self.allowsFine = allowsFine
    }

    /// Net value since the finger landed, in quarter steps, positive =
    /// clockwise.
    private(set) var quarters = 0
    /// Whether the dial is landing on quarters right now.
    private(set) var isFine = false
    /// How far the finger is from the centre.
    private(set) var radius: CGFloat = 0
    /// The finger's angle round the centre in radians, in screen coordinates
    /// (increasing is clockwise); nil while it is in the dead middle.
    private(set) var angle: CGFloat?
    /// Net turn since the finger landed, in radians, clockwise positive.
    private(set) var turned: CGFloat = 0
    /// Turn, in quarters, that has been set aside rather than paid out.
    /// Near the key the value waits up to three quarters behind the finger
    /// for the next whole step; moving out then must not hand those over at
    /// once, since pulling out never changes the value.
    private var bias: CGFloat = 0

    /// Where the turn began, carried along so that it stays put on screen
    /// while the finger goes round: the start of the ring's scale.
    var startAngle: CGFloat? { angle.map { $0 - turned } }

    /// The value as whole steps and quarters, signed: +3¼, -½, 0.
    static func readout(quarters: Int) -> String {
        guard quarters != 0 else { return "0" }
        let whole = abs(quarters) / 4
        let fraction = ["", "¼", "½", "¾"][abs(quarters) % 4]
        return (quarters > 0 ? "+" : "-") + (whole == 0 ? "" : "\(whole)") + fraction
    }

    /// Feeds the finger's translation from where it landed. Returns the steps
    /// this movement crossed, in the order to send them.
    mutating func move(to translation: CGSize) -> [Step] {
        radius = hypot(translation.width, translation.height)
        let wasFine = isFine
        if allowsFine {
            if radius >= Self.fineRadius {
                isFine = true
            } else if radius < Self.fineRadius - Self.fineOverlap {
                isFine = false
            }
        }

        guard radius >= Self.deadZone else {
            // Coming back out, it picks up from wherever it emerges rather
            // than counting the jump across the middle as a turn.
            angle = nil
            return []
        }
        let now = atan2(translation.height, translation.width)
        if let angle {
            var change = now - angle
            if change > .pi { change -= 2 * .pi }
            if change <= -.pi { change += 2 * .pi }
            turned += change
        }
        angle = now

        var target = turned / Self.quarterAngle - bias
        if isFine, !wasFine {
            bias += target - CGFloat(quarters)
            target = CGFloat(quarters)
        }
        return settle(toward: target)
    }

    mutating func reset() {
        self = PullStepper(allowsFine: allowsFine)
    }

    /// Moves the value toward the finger, a quarter at a time far out and a
    /// whole step at a time near the key, each only once the finger is a full
    /// step's worth past it. Near the key the value always lands on a whole:
    /// one left between wholes by a fine turn is made up with quarters.
    private mutating func settle(toward target: CGFloat) -> [Step] {
        // Absorbs rounding, which would otherwise leave an exact quarter turn
        // a hair short of its eighth step.
        let slack: CGFloat = 1e-6
        var steps: [Step] = []
        while true {
            if isFine {
                if target - CGFloat(quarters) >= 1 - slack {
                    quarters += 1
                    steps.append(Step(direction: 1, isQuarter: true))
                } else if target - CGFloat(quarters) <= -1 + slack {
                    quarters -= 1
                    steps.append(Step(direction: -1, isQuarter: true))
                } else {
                    return steps
                }
            } else {
                let below = Self.floorToWhole(quarters)
                let above = below == quarters ? quarters + 4 : below + 4
                let beneath = below == quarters ? quarters - 4 : below
                if target >= CGFloat(above) - slack {
                    steps += Self.steps(from: quarters, to: above)
                    quarters = above
                } else if target <= CGFloat(beneath) + slack {
                    steps += Self.steps(from: quarters, to: beneath)
                    quarters = beneath
                } else {
                    return steps
                }
            }
        }
    }

    /// A whole step if the gap is one, otherwise the quarters that close it.
    private static func steps(from: Int, to: Int) -> [Step] {
        let direction = to > from ? 1 : -1
        if abs(to - from) == 4 {
            return [Step(direction: direction, isQuarter: false)]
        }
        return Array(repeating: Step(direction: direction, isQuarter: true), count: abs(to - from))
    }

    /// The whole step at or below a value in quarters.
    private static func floorToWhole(_ quarters: Int) -> Int {
        let remainder = ((quarters % 4) + 4) % 4
        return quarters - remainder
    }
}
