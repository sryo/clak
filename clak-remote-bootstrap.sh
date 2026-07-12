#!/usr/bin/env bash
#
# Clak Remote — macOS bootstrap agent
# ===================================
# Run this once on a Mac that is already Bluetooth-paired to the SAME iPhone
# for Continuity (Handoff / Universal Clipboard / Instant Hotspot).
#
# Why it's needed: iOS advertises Clak Remote on the iPhone's shared BLE
# identity. A Mac that already knows that iPhone resolves the advertisement to
# "my paired iPhone" and reuses a cached list of its services from before Clak
# Remote existed — so it never notices the new keyboard and Clak Remote never
# appears to pair. This script installs a small background helper (a launchd
# LaunchAgent) that waits for Clak Remote to advertise, connects once to force
# the Mac to re-read the iPhone's services, and then retires itself. From then
# on macOS claims the keyboard and reconnects to it automatically — no timing
# to get right: open Clak Remote on the iPhone whenever, the helper is waiting.
#
# Requirements: Xcode command-line tools (`xcode-select --install`).
# On first run macOS asks to allow Bluetooth — click Allow.
#
# Usage:   ./clak-remote-bootstrap.sh             install the helper
#          ./clak-remote-bootstrap.sh uninstall   remove it early
# The helper removes itself once the bootstrap has succeeded.
set -euo pipefail

label="com.clak.remote.bootstrap"
support="$HOME/Library/Application Support/Clak Remote"
app="$support/ClakBootstrap.app"
agent_plist="$HOME/Library/LaunchAgents/$label.plist"
log="$support/bootstrap.log"
result="$support/result.txt"
domain="gui/$(id -u)"

if [ "${1:-install}" = "uninstall" ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$agent_plist"
    rm -rf "$support"
    echo "Removed the Clak Remote bootstrap helper."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$app/Contents/MacOS" "$HOME/Library/LaunchAgents"
# Stop any older helper before overwriting the binary it may be running from.
launchctl bootout "$domain/$label" 2>/dev/null || true
rm -f "$result"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.clak.remote.bootstrap</string>
  <key>CFBundleName</key><string>ClakBootstrap</string>
  <key>CFBundleExecutable</key><string>ClakBootstrap</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Connect once to Clak Remote so macOS discovers its keyboard.</string>
</dict></plist>
PLIST

cat > "$work/main.swift" <<'SWIFT'
import CoreBluetooth
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = home + "/Library/Application Support/Clak Remote"
let resultFile = supportDir + "/result.txt"
let agentPlist = home + "/Library/LaunchAgents/com.clak.remote.bootstrap.plist"
let hid = CBUUID(string: "1812")
let reportMap = CBUUID(string: "2A4B")

setbuf(stdout, nil)  // launchd redirects stdout to the log file; don't buffer

func report(_ s: String) {
    print(s)
    try? s.write(toFile: resultFile, atomically: true, encoding: .utf8)
}

final class Boot: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var target: CBPeripheral?
    var attemptWatchdog: DispatchWorkItem?

    func scan() {
        target = nil
        cm.scanForPeripherals(withServices: [hid], options: nil)
    }

    // Transient failures (connect drop, stale service cache, read error) just
    // mean "try again on the next advertisement" — the agent never gives up.
    func retry(_ why: String) {
        print("\(why) — will retry")
        attemptWatchdog?.cancel()
        if let t = target { cm.cancelPeripheralConnection(t) }
        target = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if cm.state == .poweredOn { scan() }
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("Bluetooth on — waiting for Clak Remote to advertise…")
            scan()
        case .poweredOff:
            print("Bluetooth is off — waiting for it to come back on.")
        case .unauthorized:
            report("FAILED — Bluetooth permission denied. Open System Settings ▸ Privacy & Security ▸ Bluetooth, allow ClakBootstrap, then re-run the bootstrap script.")
            exit(2)
        default:
            break  // .unknown/.resetting while the permission prompt is pending
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard target == nil else { return }
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.lowercased().contains("clak") else { return }
        c.stopScan(); target = p; p.delegate = self; c.connect(p, options: nil)
        let w = DispatchWorkItem { [self] in retry("Attempt timed out") }
        attemptWatchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([hid])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error e: Error?) {
        retry("Connection failed (\(e?.localizedDescription ?? "unknown error"))")
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error e: Error?) {
        retry("Disconnected (\(e?.localizedDescription ?? "no error"))")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard let s = (p.services ?? []).first(where: { $0.uuid == hid }) else {
            retry("Connected but no HID service yet"); return
        }
        p.discoverCharacteristics(nil, for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        guard let ch = (s.characteristics ?? []).first(where: { $0.uuid == reportMap }) else {
            retry("HID service has no Report Map yet"); return
        }
        // Reading the encrypted Report Map is what forces the full HID re-discovery.
        p.readValue(for: ch)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        if let e { retry("Report Map read failed (\(e.localizedDescription))"); return }
        attemptWatchdog?.cancel()
        report("OK — Clak Remote discovered (report map \(ch.value?.count ?? 0) bytes). macOS will claim the keyboard and auto-reconnect from now on.")
        // Job done for good: stop launching at login. The app bundle and log
        // stay behind for inspection; `clak-remote-bootstrap.sh uninstall`
        // removes everything.
        try? FileManager.default.removeItem(atPath: agentPlist)
        exit(0)
    }
}

let b = Boot()
b.cm = CBCentralManager(delegate: b, queue: nil)
RunLoop.main.run()
SWIFT

echo "Building bootstrap helper…"
swiftc "$work/main.swift" -o "$app/Contents/MacOS/ClakBootstrap" -framework CoreBluetooth
codesign --force --sign - "$app"

cat > "$agent_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$app/Contents/MacOS/ClakBootstrap</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PLIST

launchctl bootstrap "$domain" "$agent_plist"

echo "Helper installed and running. If macOS asks to allow Bluetooth, click Allow."
echo "(macOS may also mention a new background item — that's this helper; it"
echo "retires itself once its job is done.)"
echo "Waiting for Clak Remote — open it on the iPhone if it isn't already…"

for _ in $(seq 1 40); do
    [ -s "$result" ] && break
    sleep 1
done

echo
if [ -s "$result" ]; then
    cat "$result"
else
    echo "Not yet — that's fine. The helper keeps watching in the background and"
    echo "finishes the moment Clak Remote is open and advertising on the iPhone."
    echo "Progress log: $log"
    echo "Remove it early with: clak-remote-bootstrap.sh uninstall"
fi
