import Cocoa

/// AppleScript command: `type text "some string"`
/// Sends the provided text string as HID keystrokes to the connected Bluetooth device.
class TypeTextCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else {
            Log.scripting.error("type text: no text parameter provided")
            scriptErrorNumber = NSRequiredArgumentsMissingScriptError
            return nil
        }

        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            Log.scripting.error("type text: could not access app delegate")
            scriptErrorNumber = NSInternalScriptError
            return nil
        }

        Log.scripting.info("type text: sending \(text.count) characters")
        appDelegate.bluetoothManager.sendText(text)
        return nil
    }
}

/// AppleScript command: `connect`
/// Starts Bluetooth advertising so a device can connect.
class ConnectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
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
class DisconnectCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            Log.scripting.error("disconnect: could not access app delegate")
            scriptErrorNumber = NSInternalScriptError
            return nil
        }

        Log.scripting.info("disconnect: reconnecting via AppleScript")
        appDelegate.bluetoothManager.disconnectAndReAdvertise()
        return nil
    }
}
