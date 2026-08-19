#!/usr/bin/env bash
#
# Clak Remote — macOS discovery helper
# ====================================
# Run this once on a Mac that is already Bluetooth-paired to the SAME iPhone
# for Continuity (Handoff / Universal Clipboard / Instant Hotspot).
#
# Why it's needed: iOS advertises Clak Remote on the iPhone's shared BLE
# identity. A Mac that already knows that iPhone resolves the advertisement to
# "my paired iPhone" and answers from a cached list of its services — a list
# that has no keyboard in it whenever it was refreshed while Clak Remote wasn't
# running. So the Mac never notices the keyboard and Clak Remote never appears
# to pair. This script installs a small background helper (a launchd
# LaunchAgent) that connects once to force the Mac to re-read the iPhone's
# services, which makes macOS claim the keyboard.
#
# The helper stays installed and watches, because the cache goes stale again:
# it re-reads the phone's services in the background whenever Clak Remote is
# left advertising with no Mac picking it up. Nothing to time and nothing to
# re-run — open Clak Remote on the iPhone whenever.
#
# Requirements: Xcode command-line tools (`xcode-select --install`).
# On first run macOS asks to allow Bluetooth — click Allow.
#
# Usage:   ./clak-remote-bootstrap.sh             install the helper
#          ./clak-remote-bootstrap.sh uninstall   remove it
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
    echo "Removed the Clak Remote discovery helper."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$app/Contents/MacOS" "$HOME/Library/LaunchAgents"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.clak.remote.bootstrap</string>
  <key>CFBundleName</key><string>ClakBootstrap</string>
  <key>CFBundleExecutable</key><string>ClakBootstrap</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Connect to Clak Remote so macOS discovers its keyboard.</string>
</dict></plist>
PLIST

cat > "$work/main.swift" <<'SWIFT'
import CoreBluetooth
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = home + "/Library/Application Support/Clak Remote"
let resultFile = supportDir + "/result.txt"
let logFile = supportDir + "/bootstrap.log"
let hid = CBUUID(string: "1812")
let reportMap = CBUUID(string: "2A4B")

/// How long Clak Remote must keep advertising before we step in. macOS
/// re-claims a keyboard it already knows about in ~3s, so anything still
/// advertising well past that is a Mac working from a stale service cache.
/// Clak Remote runs its own, heavier recovery (it rebuilds its GATT database)
/// on a longer fuse — keep this the shorter of the two so the cheap remedy
/// here gets first refusal.
let graceSeconds: TimeInterval = 10
/// No advertisement for this long ends the current run: either macOS claimed
/// the keyboard (the app stops advertising once a host subscribes) or the app
/// was closed. Both mean there is nothing to fix.
let quietSeconds: TimeInterval = 3
let baseCooldown: TimeInterval = 60
let maxCooldown: TimeInterval = 600
let attemptTimeout: TimeInterval = 30
let maxLogBytes: UInt64 = 256 * 1024

setbuf(stdout, nil)  // launchd redirects stdout to the log file; don't buffer

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func note(_ s: String) {
    print("\(clock.string(from: Date()))  \(s)")
}

func report(_ s: String) {
    let line = "\(clock.string(from: Date()))  \(s)"
    print(line)
    try? "\(line)\n".write(toFile: resultFile, atomically: true, encoding: .utf8)
}

/// This helper runs for months, so keep its own log from growing without
/// bound. launchd holds the file open in append mode — truncating underneath
/// it simply restarts the log at zero.
func trimLogIfHuge() {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFile),
          let size = attributes[.size] as? UInt64, size > maxLogBytes else { return }
    _ = truncate(logFile, 0)
    note("(log trimmed)")
}

enum Decision: Equatable {
    case idle       // leave it alone
    case runEnded   // the advertisement stopped — macOS took it, or the app closed
    case force      // still unclaimed past the grace period: step in
}

func decide(now: Date, lastSeen: Date?, advertisingSince: Date?,
            hasCandidate: Bool, cooldownUntil: Date) -> Decision {
    if let lastSeen, now.timeIntervalSince(lastSeen) > quietSeconds { return .runEnded }
    guard let advertisingSince, hasCandidate,
          now >= cooldownUntil,
          now.timeIntervalSince(advertisingSince) >= graceSeconds else { return .idle }
    return .force
}

final class Watchdog: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!

    // Advertisement tracking
    private var candidate: CBPeripheral?
    private var lastSeen: Date?
    private var advertisingSince: Date?

    // Forcing state
    private var isForcing = false
    private var target: CBPeripheral?
    private var attemptWatchdog: DispatchWorkItem?

    /// Backoff so a Mac the user deliberately isn't connecting to (they're
    /// using Clak Remote with a different host) isn't grabbed every minute.
    /// Reset whenever the advertisement stops — that's the signal the last
    /// force worked, or that the run ended on its own.
    private var consecutiveForces = 0
    private var cooldownUntil = Date.distantPast

    private var ticker: DispatchSourceTimer?

    func start() {
        // Rebuilding the helper gives it a new code signature, which macOS
        // treats as a new app for Bluetooth permission. Until someone answers
        // that prompt CoreBluetooth just reports .unknown, so say what is
        // wrong instead of sitting silent forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.cm.state != .poweredOn, self.cm.state != .poweredOff else { return }
            report("Waiting for Bluetooth permission — allow ClakBootstrap in System Settings ▸ Privacy & Security ▸ Bluetooth. (Rebuilding the helper makes macOS treat it as a new app, so this needs approving again.)")
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        // Leeway lets the kernel coalesce this with other wakeups; the
        // thresholds it drives are 3s and 10s, so a second of slop is free.
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    /// Duplicates are what make "still advertising" observable — without them
    /// a peripheral is reported once per scan session and a live advertisement
    /// is indistinguishable from a stale first sighting. They also wake this
    /// process on every advertising packet, so they stay off until there is a
    /// run to track: the first sighting is all the idle state needs.
    private func scan(trackingRun: Bool) {
        cm.stopScan()
        cm.scanForPeripherals(
            withServices: [hid],
            options: trackingRun ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil
        )
    }

    private func tick() {
        guard cm.state == .poweredOn, !isForcing else { return }

        switch decide(now: Date(), lastSeen: lastSeen, advertisingSince: advertisingSince,
                      hasCandidate: candidate != nil, cooldownUntil: cooldownUntil) {
        case .idle:
            break
        case .runEnded:
            note("Clak Remote stopped advertising — macOS has it, or the app was closed")
            forgetRun()
            consecutiveForces = 0
            cooldownUntil = .distantPast
            scan(trackingRun: false)
        case .force:
            if let peripheral = candidate { force(peripheral) }
        }
    }

    private func forgetRun() {
        lastSeen = nil
        advertisingSince = nil
        candidate = nil
    }

    /// Drop an in-flight attempt and every trace of it.
    private func abortAttempt() {
        attemptWatchdog?.cancel()
        attemptWatchdog = nil
        isForcing = false
        if let target {
            cm.cancelPeripheralConnection(target)
        }
        target = nil
    }

    /// Connect and read the (encrypted) Report Map. That read is what makes
    /// macOS re-read the iPhone's services and register the keyboard.
    private func force(_ p: CBPeripheral) {
        isForcing = true
        consecutiveForces += 1
        cm.stopScan()
        note("Still unclaimed after \(Int(graceSeconds))s — forcing a fresh service read (attempt \(consecutiveForces))")

        target = p
        p.delegate = self
        cm.connect(p, options: nil)

        let w = DispatchWorkItem { [weak self] in self?.finish("Attempt timed out") }
        attemptWatchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + attemptTimeout, execute: w)
    }

    /// End the current attempt and go back to watching. Transient failures
    /// (connect drop, stale service cache, read error) need no special
    /// handling — the next advertisement gets another try.
    private func finish(_ why: String? = nil) {
        abortAttempt()

        // Restart the grace measurement from scratch rather than counting the
        // seconds spent connecting as "unclaimed".
        forgetRun()

        let cooldown = min(baseCooldown * pow(2, Double(consecutiveForces - 1)), maxCooldown)
        cooldownUntil = Date().addingTimeInterval(cooldown)
        if let why {
            note("\(why) — watching again (next attempt no sooner than \(Int(cooldown))s)")
        }

        if cm.state == .poweredOn {
            scan(trackingRun: false)
        }
        trimLogIfHuge()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            note("Bluetooth on — watching for Clak Remote")
            forgetRun()
            if !isForcing { scan(trackingRun: false) }
        case .poweredOff:
            note("Bluetooth is off — waiting for it to come back on")
            abortAttempt()
        case .unauthorized:
            report("FAILED — Bluetooth permission denied. Open System Settings ▸ Privacy & Security ▸ Bluetooth, allow ClakBootstrap, then re-run the bootstrap script.")
            exit(2)
        default:
            break  // .unknown/.resetting while the permission prompt is pending
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        guard !isForcing else { return }

        // Every packet from an accepted peripheral lands here; the name can't
        // have changed, so skip re-deriving it.
        if candidate === p {
            lastSeen = Date()
            return
        }

        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.range(of: "clak", options: .caseInsensitive) != nil else { return }

        lastSeen = Date()
        candidate = p
        advertisingSince = lastSeen
        note("Clak Remote is advertising — giving macOS \(Int(graceSeconds))s to claim it")
        scan(trackingRun: true)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([hid])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error e: Error?) {
        finish("Connection failed (\(e?.localizedDescription ?? "unknown error"))")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error e: Error?) {
        guard isForcing else { return }  // our own post-success disconnect
        finish("Disconnected (\(e?.localizedDescription ?? "no error"))")
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard let s = (p.services ?? []).first(where: { $0.uuid == hid }) else {
            finish("Connected but no HID service yet"); return
        }
        p.discoverCharacteristics(nil, for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        guard let ch = (s.characteristics ?? []).first(where: { $0.uuid == reportMap }) else {
            finish("HID service has no Report Map yet"); return
        }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        if let e {
            finish("Report Map read failed (\(e.localizedDescription))"); return
        }
        report("OK — forced a fresh read of Clak Remote (report map \(ch.value?.count ?? 0) bytes). macOS should claim the keyboard now.")
        finish()
    }
}

trimLogIfHuge()
let w = Watchdog()
w.cm = CBCentralManager(delegate: w, queue: nil)
w.start()
RunLoop.main.run()
SWIFT

echo "Building the helper…"
# Build before touching the running helper, so a failure here leaves a working
# one in place rather than none at all.
swiftc "$work/main.swift" -o "$work/ClakBootstrap" -framework CoreBluetooth

# Stop the old helper before overwriting the binary it is running from.
launchctl bootout "$domain/$label" 2>/dev/null || true
rm -f "$result"
cp "$work/ClakBootstrap" "$app/Contents/MacOS/ClakBootstrap"
codesign --force --sign - "$app"

cat > "$agent_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$app/Contents/MacOS/ClakBootstrap</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>Crashed</key><true/></dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PLIST

launchctl bootstrap "$domain" "$agent_plist"
# Re-bootstrapping over a just-removed job can register it without running it,
# leaving the helper dead until the next login. Starting it explicitly is a
# no-op when RunAtLoad already did.
launchctl kickstart "$domain/$label" 2>/dev/null || true

echo "Helper installed and running. If macOS asks to allow Bluetooth, click Allow."
echo "(macOS may also mention a new background item — that's this helper.)"
echo "Waiting for Clak Remote — open it on the iPhone if it isn't already…"

for _ in $(seq 1 40); do
    [ -s "$result" ] && break
    sleep 1
done

echo
if [ -s "$result" ]; then
    cat "$result"
    echo "The helper keeps watching in the background, so if macOS forgets the"
    echo "keyboard again it gets fixed without you re-running anything."
else
    echo "Nothing to fix right now — either macOS already has the keyboard or"
    echo "Clak Remote isn't open. Either way the helper keeps watching in the"
    echo "background and steps in whenever the Mac stops picking the keyboard up."
    echo "Progress log: $log"
    echo "Remove it with: clak-remote-bootstrap.sh uninstall"
fi
