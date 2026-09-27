import Foundation

/// The echo line's text, kept short so each keystroke costs O(1): appends
/// only grow the string, and once it passes `maxLength` it is cut back to the
/// newest `visibleLength` characters in one go, so a trim (O(visibleLength))
/// happens once per `maxLength - visibleLength` characters typed.
struct EchoBuffer {
    static let visibleLength = 200
    static let maxLength = 250

    private(set) var text = ""
    /// Characters in `text`, kept without rescanning it.
    private(set) var count = 0

    mutating func append(_ piece: String) {
        // A combining mark or joiner merges into the last character, so count
        // what the piece adds next to that character, not on its own
        let added = text.last.map { (String($0) + piece).count - 1 } ?? piece.count
        text += piece
        count += added
        if count > Self.maxLength {
            text = String(text.suffix(Self.visibleLength))
            count = text.count
        }
    }

    mutating func removeLast() {
        guard !text.isEmpty else { return }
        text.removeLast()
        count = max(0, count - 1)
    }

    mutating func removeAll() {
        text = ""
        count = 0
    }
}
