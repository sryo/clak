import Cocoa

/// AppleScript command: `type text "some string"`
/// Sends the provided text string as HID keystrokes to the connected Bluetooth device.
@objc(TypeTextCommand)
class TypeTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            Log.scripting.error("type text: no text parameter provided")
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            return nil
        }

        guard let appDelegate = AppDelegate.shared else {
            Log.scripting.error("type text: could not access app delegate")
            scriptErrorNumber = NSInternalScriptError
            return nil
        }

        guard case .connected = appDelegate.bluetoothManager.connectionState else {
            Log.scripting.error("type text: no device connected")
            scriptErrorNumber = NSReceiversCantHandleCommandScriptError
            scriptErrorString = "No device is connected. Pair a device before using “type text”."
            return nil
        }

        Log.scripting.info("type text: sending \(text.count) characters")
        appDelegate.bluetoothManager.sendText(text)
        return nil
    }
}

/// AppleScript command: `connect`
/// Starts Bluetooth advertising so a device can connect.
@objc(ConnectCommand)
class ConnectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let appDelegate = AppDelegate.shared else {
            Log.scripting.error("connect: could not access app delegate")
            scriptErrorNumber = NSInternalScriptError
            return nil
        }

        Log.scripting.info("connect: starting advertising via AppleScript")
        appDelegate.bluetoothManager.startAdvertising()
        return nil
    }
}

/// AppleScript command: `disconnect`
/// Disconnects and re-advertises.
@objc(DisconnectCommand)
class DisconnectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let appDelegate = AppDelegate.shared else {
            Log.scripting.error("disconnect: could not access app delegate")
            scriptErrorNumber = NSInternalScriptError
            return nil
        }

        Log.scripting.info("disconnect: reconnecting via AppleScript")
        appDelegate.bluetoothManager.disconnectAndReAdvertise()
        return nil
    }
}
