import Foundation

/// A dedicated thread running its own CFRunLoop for the event taps, so a
/// busy main thread (SwiftUI layout, a modal) can't delay the system's
/// keyboard and scroll events or get a tap disabled by timeout.
final class EventTapThread {
    static let shared = EventTapThread(name: "com.clak.app.event-taps")

    private(set) var runLoop: CFRunLoop!
    private var thread: Thread!

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; this timer never
            // fires, it only keeps the loop waiting
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, .greatestFiniteMagnitude, 0, 0, 0
            ) { _ in }
            CFRunLoopAddTimer(self.runLoop, keepAlive, .commonModes)
            ready.signal()
            while true {
                CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
            }
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    var isCurrent: Bool { CFRunLoopGetCurrent() === runLoop }

    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `block` on the tap thread and returns its result. Never call it
    /// from a tap callback path that waits on main.
    ///
    /// `block` is escaping on purpose: the run loop releases a performed block
    /// only after it returns, so the waiter can wake while the tap thread still
    /// holds it, which `withoutActuallyEscaping` traps on.
    func performAndWait<T>(_ block: @escaping () -> T) -> T {
        if isCurrent {
            return block()
        }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        perform {
            result = block()
            done.signal()
        }
        done.wait()
        return result!
    }
}
