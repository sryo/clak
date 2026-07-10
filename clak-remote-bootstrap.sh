#!/usr/bin/env bash
#
# Clak Remote — one-time macOS bootstrap
# =====================================
# Run this once on a Mac that is already Bluetooth-paired to the SAME iPhone
# for Continuity (Handoff / Universal Clipboard / Instant Hotspot).
#
# Why it's needed: iOS advertises Clak Remote on the iPhone's shared BLE
# identity. A Mac that already knows that iPhone resolves the advertisement to
# "my paired iPhone" and reuses a cached list of its services from before Clak
# Remote existed — so it never notices the new keyboard and Clak Remote never
# appears to pair. This tool connects once and forces the Mac to re-read the
# iPhone's services, after which macOS claims the keyboard and reconnects to it
# automatically from then on (no need to run this again on this Mac).
#
# Requirements: Xcode command-line tools (`xcode-select --install`).
# On first run macOS asks to allow Bluetooth — click Allow.
#
# Usage: open Clak Remote on the iPhone (foreground, showing "Advertising"),
#        then run:  ./clak-remote-bootstrap.sh
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/ClakBootstrap.app"
result="$work/result.txt"
mkdir -p "$app/Contents/MacOS"

cat > "$app/Contents/Info.plist" <<PLIST
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

sed "s|__RESULT__|$result|" > "$work/main.swift" <<'SWIFT'
import CoreBluetooth
import Foundation

let out = "__RESULT__"
let hid = CBUUID(string: "1812")
let reportMap = CBUUID(string: "2A4B")
func write(_ s: String) { try? s.write(toFile: out, atomically: true, encoding: .utf8) }

final class Boot: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var target: CBPeripheral?
    var searching = false

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            // The app advertises the HID service until a host claims it as a
            // keyboard; scan for that advertisement and force a re-read.
            c.scanForPeripherals(withServices: [hid], options: nil)
            // Only start the "not found" clock once we're actually scanning, so a
            // slow tap on the Bluetooth-permission prompt doesn't trip a false fail.
            guard !searching else { return }
            searching = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                write("DONE: FAILED — Clak Remote not found. Open the app on the iPhone (foreground, showing \"Advertising\") and re-run.")
                exit(1)
            }
        case .unauthorized:
            write("DONE: FAILED — Bluetooth permission denied. Open System Settings ▸ Privacy & Security ▸ Bluetooth, enable it, and re-run.")
            exit(2)
        case .poweredOff:
            write("DONE: FAILED — turn Bluetooth on and re-run."); exit(3)
        default:
            break  // .unknown/.resetting while the permission prompt is pending
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.lowercased().contains("clak") else { return }
        c.stopScan(); target = p; p.delegate = self; c.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([hid])
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard (p.services ?? []).contains(where: { $0.uuid == hid }) else {
            write("DONE: FAILED — connected but no HID service found."); exit(4)
        }
        for s in p.services ?? [] where s.uuid == hid { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        // Reading the encrypted Report Map is what forces the full HID re-discovery.
        for ch in s.characteristics ?? [] where ch.uuid == reportMap { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        if let e { write("DONE: FAILED — \(e.localizedDescription)") }
        else { write("DONE: OK — Clak Remote discovered (report map \(ch.value?.count ?? 0) bytes). macOS will claim the keyboard and auto-reconnect from now on.") }
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

echo "Make sure Clak Remote is open and in the foreground on your iPhone."
echo "Launching… if macOS asks to use Bluetooth, click Allow."
open "$app"

for _ in $(seq 1 40); do
    [ -f "$result" ] && grep -q "DONE" "$result" && break
    sleep 1
done

echo
if [ -f "$result" ]; then sed 's/^DONE: //' "$result"; else echo "FAILED — helper did not report back (was the Bluetooth prompt approved?)."; fi
