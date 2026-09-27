import SwiftUI
import AppKit

/// Trackpad surface for driving the device cursor: drag moves, click taps,
/// scroll gestures scroll. iPhone needs AssistiveTouch enabled
/// (Settings → Accessibility → Touch); iPad supports pointers natively.
struct TrackpadPaneView: View {
    let bluetoothManager: BluetoothManager

    /// Concentric with the HUD window: inner radius = window radius (12) − inset (8)
    static let cornerRadius: CGFloat = 4
    static let inset: CGFloat = 8

    var body: some View {
        TrackpadSurface(bluetoothManager: bluetoothManager)
            .frame(width: 300, height: 180)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                Text("drag = move · click = tap · scroll = swipe")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
    }
}

private struct TrackpadSurface: NSViewRepresentable {
    let bluetoothManager: BluetoothManager

    func makeNSView(context: Context) -> TrackpadNSView {
        let view = TrackpadNSView()
        view.bluetoothManager = bluetoothManager
        return view
    }

    func updateNSView(_ nsView: TrackpadNSView, context: Context) {
        nsView.bluetoothManager = bluetoothManager
    }
}

/// AppKit view so mouse drags, clicks, and scroll events are all captured natively
/// (SwiftUI has no scroll-event API, and gestures can't coexist with an NSView overlay).
final class TrackpadNSView: NSView {
    weak var bluetoothManager: BluetoothManager?

    private var dragDistance: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    private lazy var pointer = PadPointerSender(scheduler: MainQueueTickScheduler.shared) { [weak self] dx, dy in
        self?.bluetoothManager?.sendMouse(dx: dx, dy: dy)
        return true
    }

    private lazy var scroll = PadScrollSender(scheduler: MainQueueTickScheduler.shared) { [weak self] lines in
        self?.bluetoothManager?.sendMouse(wheel: lines)
    }

    // The HUD window is movable by background — without this, drags move the window
    override var mouseDownCanMoveWindow: Bool { false }

    // mouseDownCanMoveWindow alone is not honored under SwiftUI's hosting view,
    // so also disable window-background dragging while the pointer is over the pad
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.isMovableByWindowBackground = false
    }

    override func mouseExited(with event: NSEvent) {
        window?.isMovableByWindowBackground = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Pad removed (mode toggled) while the pointer was inside — restore dragging
        if newWindow == nil {
            window?.isMovableByWindowBackground = true
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // Let the pad work on the first click even when the window isn't key
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragDistance = 0
        pointer.reset()
    }

    override func mouseDragged(with event: NSEvent) {
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        pointer.move(
            dx: Double(event.deltaX * Constants.Trackpad.sensitivity),
            dy: Double(event.deltaY * Constants.Trackpad.sensitivity)
        )
    }

    override func mouseUp(with event: NSEvent) {
        pointer.flush()
        if dragDistance < Constants.Trackpad.tapThreshold {
            bluetoothManager?.sendMouse(buttons: 0x01)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.bluetoothManager?.sendMouse(buttons: 0x00)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll.scroll(
            deltaY: Double(event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            phase: Self.scrollPhase(of: event)
        )
    }

    private static func scrollPhase(of event: NSEvent) -> PadScrollAccumulator.Phase {
        if !event.momentumPhase.isEmpty {
            return .momentum
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            return .began
        }
        return event.phase.isEmpty ? .other : .changed
    }
}
