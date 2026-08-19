import Foundation
import Observation

/// The gestures that carry real function but leave no mark on screen.
enum Affordance: String {
    /// Keys that hold a value you can pull out of them.
    case pullKey
    case layerSwipe
    case panelExpand

    /// Taught in this order: whichever is still unknown and costs the most to
    /// miss goes first. A pull key wears a chevron, but nothing says what the
    /// chevron affords, and behind it sit brightness, volume and scrubbing;
    /// expansion only hides extras.
    static let teachingOrder: [Affordance] = [.pullKey, .layerSwipe, .panelExpand]

    var words: String {
        switch self {
        case .pullKey: "Pull a key to adjust"
        case .layerSwipe: "Swipe for keys"
        case .panelExpand: "Pull up for more"
        }
    }

    var glyph: String {
        switch self {
        case .pullKey: "arrow.up.and.down"
        case .layerSwipe: "arrow.left.arrow.right"
        case .panelExpand: "chevron.up"
        }
    }
}

enum HintStyle {
    /// Move the thing in the direction it wants to be moved.
    case peek
    /// Say it, once moving it hasn't worked.
    case words
}

struct Hint: Equatable {
    /// Makes two consecutive hints for the same affordance compare unequal,
    /// so the view's onChange fires for the second one too.
    let sequence: Int
    let affordance: Affordance
    let style: HintStyle
}

/// Decides what to teach and when, so the views only have to ask whether they
/// should currently be demonstrating something.
///
/// The rules matter more than the animations: a hint at the wrong moment is
/// worse than no hint. So it waits for a lull, shows one thing per session,
/// escalates from motion to words only if motion didn't take, and stops
/// permanently the first time you perform the gesture yourself.
@Observable
final class HintCoach {
    private(set) var current: Hint?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var hintedThisSession = false
    @ObservationIgnored private var clearTask: DispatchWorkItem?

    /// Quiet needed before anything is offered, so a hint never lands mid-use.
    static let idleBeforeHint: TimeInterval = 4
    private static let peekAttempts = 3
    private static let wordAttempts = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Ledger

    func isDiscovered(_ affordance: Affordance) -> Bool {
        defaults.bool(forKey: "hint.done.\(affordance.rawValue)")
    }

    /// Performing the gesture retires its teaching for good.
    func markDiscovered(_ affordance: Affordance) {
        guard !isDiscovered(affordance) else { return }
        defaults.set(true, forKey: "hint.done.\(affordance.rawValue)")
        if current?.affordance == affordance {
            clear()
        }
    }

    private func attempts(_ affordance: Affordance) -> Int {
        defaults.integer(forKey: "hint.tries.\(affordance.rawValue)")
    }

    // MARK: - Session

    func sessionBegan() {
        hintedThisSession = false
        clear()
    }

    /// Any touch, or leaving the app, means the hint is no longer welcome.
    func cancel() {
        clear()
    }

    // MARK: - Timing

    func tick(idleFor idle: TimeInterval, reduceMotion: Bool) {
        guard current == nil, !hintedThisSession, idle >= Self.idleBeforeHint else { return }

        let budget = Self.peekAttempts + Self.wordAttempts
        guard let next = Affordance.teachingOrder.first(where: {
            !isDiscovered($0) && attempts($0) < budget
        }) else { return }

        let tries = attempts(next)
        // Motion is the message, so with Reduce Motion on it goes straight to
        // saying it instead.
        let style: HintStyle = (reduceMotion || tries >= Self.peekAttempts) ? .words : .peek

        defaults.set(tries + 1, forKey: "hint.tries.\(next.rawValue)")
        hintedThisSession = true
        sequence += 1
        current = Hint(sequence: sequence, affordance: next, style: style)

        // A peek is over as soon as the motion settles; words have to be read.
        scheduleClear(after: style == .peek ? 1.4 : 3.0)
    }

    private func scheduleClear(after delay: TimeInterval) {
        clearTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.current = nil
        }
        clearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func clear() {
        // @Observable publishes even a nil-to-nil write, and this is called on
        // every frame of a drag.
        guard current != nil || clearTask != nil else { return }
        clearTask?.cancel()
        clearTask = nil
        current = nil
    }
}
