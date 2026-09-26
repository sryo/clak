import CoreGraphics

/// Turns a pull key's drag into steps by following the finger like a tape.
///
/// The track starts out facing along the key's axis, and every movement counts
/// by how far it went that way, one step per `pointsPerStep` as a straight
/// pull always has. The facing bends with the finger's path, so curling a pull
/// round into a circle of any size just keeps counting: a line is a circle
/// with a very big radius, and nothing has to decide when one became the
/// other. Going back along the path counts down; moving across it counts
/// nothing.
///
/// It also reports how tightly the path bends, so the track on screen can take
/// the gesture's shape. Pure geometry, no UIKit and no clock, so every path
/// can be replayed in a unit test.
struct PullStepper {
    /// The facing is read from the chord over this much of the recent path, so
    /// touch jitter can't steer it.
    static let chordLength: CGFloat = 8
    /// How far off the facing, either way along it, the path may head and
    /// still bend it. Past this the finger is moving across the track.
    static let followAngle: CGFloat = 75 * .pi / 180
    /// The tightest circle a finger draws. The facing turns no faster than
    /// this bend, which keeps a trembling pull from steering it.
    static let tightestRadius: CGFloat = 10
    /// Travel over which the curvature settles on a new value.
    static let curvatureSettling: CGFloat = 12

    let axis: PullAxis
    private let pointsPerStep: CGFloat

    /// Net steps since the finger landed, positive = up / right to begin with.
    private(set) var steps = 0
    /// Signed 1/radius of the path in 1/points, positive when the track bends
    /// clockwise on screen, 0 on a straight line.
    private(set) var curvature: CGFloat = 0

    private var facing: CGVector
    private var travel: CGFloat = 0
    private var steppedTravel: CGFloat = 0
    private var lastPoint = CGPoint.zero
    private var distance: CGFloat = 0
    /// Recent points with the path distance at which each was reached, back to
    /// the last one at least a chord behind.
    private var trail: [(point: CGPoint, distance: CGFloat)] = [(.zero, 0)]

    init(axis: PullAxis, pointsPerStep: CGFloat = ControlMetrics.pointsPerStep) {
        self.axis = axis
        self.pointsPerStep = pointsPerStep
        // Screen y grows downward, so up is -y.
        facing = axis == .vertical ? CGVector(dx: 0, dy: -1) : CGVector(dx: 1, dy: 0)
    }

    /// Feeds the finger's translation from where it landed, in screen
    /// coordinates. Returns the steps this movement crossed.
    mutating func move(to translation: CGSize) -> Int {
        let point = CGPoint(x: translation.width, y: translation.height)
        let dx = point.x - lastPoint.x, dy = point.y - lastPoint.y
        let moved = hypot(dx, dy)
        guard moved > 0 else { return 0 }

        let along = dx * facing.dx + dy * facing.dy
        travel += along
        lastPoint = point
        distance += moved
        trail.append((point, distance))
        while trail.count > 1, trail[1].distance <= distance - Self.chordLength {
            trail.removeFirst()
        }

        let turned = bendFacing(toward: point, moved: moved)
        // Per unit of travel along the track, so going back round a circle
        // bends the same way as going forward.
        let bend = along < 0 ? -turned : turned
        curvature += (bend / moved - curvature) * min(1, moved / Self.curvatureSettling)

        var delta = 0
        // The tolerance absorbs rounding in the running sum, which would
        // otherwise make an exact 14pt pull fall a hair short of its step.
        while travel - steppedTravel >= pointsPerStep - 1e-6 {
            steppedTravel += pointsPerStep
            delta += 1
        }
        while travel - steppedTravel <= -pointsPerStep + 1e-6 {
            steppedTravel -= pointsPerStep
            delta -= 1
        }
        steps += delta
        return delta
    }

    mutating func reset() {
        self = PullStepper(axis: axis, pointsPerStep: pointsPerStep)
    }

    /// Turns the facing to the recent chord when the chord runs along it,
    /// either way. Returns the angle turned, positive clockwise on screen.
    private mutating func bendFacing(toward point: CGPoint, moved: CGFloat) -> CGFloat {
        let tail = trail[0]
        guard distance - tail.distance >= Self.chordLength else { return 0 }
        let cx = point.x - tail.point.x, cy = point.y - tail.point.y
        let chord = hypot(cx, cy)
        // Short against the path it spans: the finger turned round inside it.
        guard chord >= Self.chordLength / 2 else { return 0 }

        let direction = CGVector(dx: cx / chord, dy: cy / chord)
        var dot = direction.dx * facing.dx + direction.dy * facing.dy
        // Heading back along the track bends it just the same.
        let sign: CGFloat = dot < 0 ? -1 : 1
        dot *= sign
        guard dot >= cos(Self.followAngle) else { return 0 }

        let limit = moved / Self.tightestRadius
        let turned = max(-limit, min(limit, atan2((facing.dx * direction.dy - facing.dy * direction.dx) * sign, dot)))
        facing = CGVector(dx: facing.dx * cos(turned) - facing.dy * sin(turned),
                          dy: facing.dx * sin(turned) + facing.dy * cos(turned))
        return turned
    }
}
