import SwiftUI
import UIKit

/// Owns keyboard visibility: the toggle button calls toggle() directly on
/// the capture field (synchronous first-responder calls are reliable; driving
/// them from updateUIView is not), and the field reports visibility back.
@Observable
final class KeyboardFocus {
    @ObservationIgnored weak var view: UIView?
    private(set) var isVisible = false

    func toggle() {
        if isVisible {
            view?.resignFirstResponder()
        } else {
            view?.becomeFirstResponder()
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    /// Used when iOS takes the keyboard away without telling the field — it
    /// stays first responder, so nothing else would clear typing mode.
    func dismiss() {
        view?.resignFirstResponder()
        isVisible = false
    }
}

/// Invisible text field that turns the iOS keyboard into a HID keystroke source.
struct KeyInputView: UIViewRepresentable {
    let controller: RemoteController
    let focus: KeyboardFocus

    func makeUIView(context: Context) -> KeyCaptureTextField {
        let field = KeyCaptureTextField()
        field.controller = controller
        field.focus = focus
        focus.view = field
        return field
    }

    func updateUIView(_ uiView: KeyCaptureTextField, context: Context) {
        uiView.controller = controller
        uiView.focus = focus
        focus.view = uiView
    }
}

final class KeyCaptureTextField: UITextField, UITextFieldDelegate {
    weak var controller: RemoteController?
    weak var focus: KeyboardFocus?

    /// Zero-width space kept in the field so the delete key always produces a
    /// shouldChangeCharactersIn callback (an empty field swallows backspace).
    private static let sentinel = "\u{200B}"

    init() {
        super.init(frame: .zero)
        delegate = self
        text = Self.sentinel
        keyboardType = .asciiCapable
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .default
        tintColor = .clear
        textColor = .clear
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - UITextFieldDelegate

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            controller?.deleteBackward()
        } else {
            controller?.type(text: string)
        }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        controller?.pressKey(HIDKey.returnKey)
        return false
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        focus?.setVisible(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        focus?.setVisible(false)
    }
}
