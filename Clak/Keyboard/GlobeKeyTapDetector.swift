import Foundation

/// Recognises a tap of the fn/Globe key: pressed and released with nothing
/// else in between. Holding it for fn-arrows or a Globe shortcut isn't a tap.
struct GlobeKeyTapDetector {

    /// kVK_Function, and the Globe key's code on newer Apple keyboards.
    static let keyCodes: Set<UInt16> = [63, 179]

    private var pressedCleanly = false

    /// - Returns: true when this release completes a tap.
    mutating func globeChanged(isDown: Bool) -> Bool {
        if isDown {
            pressedCleanly = true
            return false
        }
        defer { pressedCleanly = false }
        return pressedCleanly
    }

    /// Any other key or modifier while Globe is down spoils the tap.
    mutating func otherInput() {
        pressedCleanly = false
    }
}
