import Foundation

/// Reports waiting for room in CoreBluetooth's notification queue, in send
/// order. Generic over the target so tests don't need CoreBluetooth objects.
///
/// Nothing the host would act on is ever lost: identical repeats are dropped,
/// pointer motion with the same buttons is summed (an absolute position just
/// replaces the previous one), and when the queue is full
/// it collapses to the newest report per target and recipient — the final
/// state, including every key-up, always survives.
struct PendingReportQueue<Target: AnyObject> {

    enum Kind: Equatable {
        case keyboard, consumer, mouse, absolutePointer, other
    }

    struct Entry {
        var data: Data
        let target: Target
        let kind: Kind
        /// nil sends to every subscriber.
        let recipient: UUID?
    }

    enum Outcome: Equatable {
        case appended
        case coalesced
        /// The queue was full and shrank to one entry per target; `dropped`
        /// entries were superseded.
        case collapsed(dropped: Int)
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    var first: Entry? { entries.first }
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    mutating func removeFirst() {
        entries.removeFirst()
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    mutating func removeAll(recipient: UUID) {
        entries.removeAll { $0.recipient == recipient }
    }

    @discardableResult
    mutating func enqueue(_ data: Data, on target: Target, kind: Kind, recipient: UUID? = nil) -> Outcome {
        var pending = data
        // Only the tail merges: reaching past an entry for another target
        // would reorder reports the host must see in sequence.
        if let last = entries.last, last.target === target, last.recipient == recipient {
            if kind != .mouse, last.data == data {
                return .coalesced
            }
            // Only the newest position matters, as long as the buttons match
            if kind == .absolutePointer, last.data.first == data.first {
                entries[entries.count - 1].data = data
                return .coalesced
            }
            if kind == .mouse, let (merged, rest) = Self.mergeMouse(last.data, data) {
                entries[entries.count - 1].data = merged
                guard let rest else { return .coalesced }
                pending = rest
            }
        }

        let entry = Entry(data: pending, target: target, kind: kind, recipient: recipient)
        guard entries.count < capacity else {
            let before = entries.count + 1
            entries.append(entry)
            collapseToLatestState()
            return .collapsed(dropped: before - entries.count)
        }
        entries.append(entry)
        return .appended
    }

    /// Keep only the newest entry per target and recipient, in their original
    /// relative order.
    mutating func collapseToLatestState() {
        var seen = Set<Key>()
        var kept: [Entry] = []
        for entry in entries.reversed() where seen.insert(Key(entry)).inserted {
            kept.append(entry)
        }
        entries = kept.reversed()
    }

    private struct Key: Hashable {
        let target: ObjectIdentifier
        let recipient: UUID?
        init(_ entry: Entry) {
            target = ObjectIdentifier(entry.target)
            recipient = entry.recipient
        }
    }

    /// Sums two mouse reports, `[buttons, dx, dy, wheel(, pan)]`, whose
    /// buttons match. Each axis clamps to the descriptor's ±127; what doesn't
    /// fit comes back as a second report. nil when the reports can't merge.
    static func mergeMouse(_ a: Data, _ b: Data) -> (merged: Data, rest: Data?)? {
        let a = [UInt8](a), b = [UInt8](b)
        guard a.count == b.count, a.count >= 4, a[0] == b[0] else { return nil }

        var merged = a
        var rest = [UInt8](repeating: 0, count: a.count)
        rest[0] = a[0]
        var overflow = false
        for i in 1..<a.count {
            let sum = axis(a[i]) + axis(b[i])
            let clamped = max(-127, min(127, sum))
            merged[i] = UInt8(bitPattern: Int8(clamped))
            rest[i] = UInt8(bitPattern: Int8(sum - clamped))
            overflow = overflow || sum != clamped
        }
        return (Data(merged), overflow ? Data(rest) : nil)
    }

    /// −128 is outside the descriptor's logical range; reading it as −127
    /// also keeps any remainder within Int8.
    private static func axis(_ byte: UInt8) -> Int {
        max(-127, Int(Int8(bitPattern: byte)))
    }
}
