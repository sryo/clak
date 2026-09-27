import XCTest
@testable import Clak

final class KeyboardShortcutManagerTests: XCTestCase {

    private let manager = KeyboardShortcutManager.shared
    private var saved: ShortcutBinding?

    override func setUp() {
        super.setUp()
        saved = manager.registeredShortcuts.first { $0.action == .showPreferences }
    }

    override func tearDown() {
        manager.onChange = nil
        manager.isRecording = false
        if let saved {
            manager.updateShortcut(action: saved.action, keyCode: saved.keyCode,
                                   modifiers: CGEventFlags(rawValue: saved.modifiers))
        }
        super.tearDown()
    }

    /// The key gate snapshot is rebuilt from these; a change it doesn't hear
    /// about would leave the tap routing with stale shortcuts.
    func testRecordingAndBindingChangesAreAnnounced() {
        var changes = 0
        manager.onChange = { changes += 1 }
        manager.isRecording = true
        XCTAssertEqual(changes, 1)
        manager.updateShortcut(action: .showPreferences, keyCode: 43, modifiers: [.maskCommand, .maskAlternate])
        XCTAssertGreaterThanOrEqual(changes, 2)
    }
}
