# What CoreBluetooth doesn't tell you about being a keyboard

Clak makes a Mac show up as an ordinary Bluetooth keyboard for an iPhone, iPad, or Apple TV. Clak Remote does the reverse: the iPhone becomes a keyboard and trackpad for the Mac. Neither side installs anything on the receiving device, because both apps implement the standard HID over GATT Profile (HOGP) with plain `CBPeripheralManager`. No private frameworks, no kernel extension, no dongle.

Apple doesn't document this as possible. In one place the documentation says a required piece of it can't be done. These are the walls I hit, in the order I hit them, and what got through each one. All of it lives in one file, [`BLEHIDPeripheralManager.swift`](../Clak/Bluetooth/BLEHIDPeripheralManager.swift), which both apps compile.

(I tried Classic Bluetooth first. On current macOS, `bluetoothd` owns the HID L2CAP channels, PSM 17 and 19, and an iPhone ignored the custom PSMs I tried instead. BLE was the only road left.)

## 1. The HID service UUID is blocked, unless you spell it out

The first thing a keyboard needs is the HID service, `0x1812`. CoreBluetooth refuses to add it:

```swift
// Refused by add(_:)
CBMutableService(type: CBUUID(string: "1812"), primary: true)

// Accepted
CBMutableService(type: CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"), primary: true)
```

Every 16-bit Bluetooth UUID is shorthand for a full 128-bit UUID built on the Bluetooth Base UUID, `0000xxxx-0000-1000-8000-00805F9B34FB`. The two forms are the same UUID, and a client that discovers the long one sees an HID service. The validation in `add(_:)` only seems to recognise the short one.

I register the Generic Attribute (`0x1801`) and Device Information (`0x180A`) services in long form too. I haven't mapped which SIG services are on the blocklist and which aren't. Characteristic UUIDs aren't checked: `2A4D`, `2A4B` and the rest work in short form.

The advertisement is the opposite case. The short form is allowed there, and you want it there. A legacy advertising packet holds 31 bytes. Flags take 3, a 16-bit service UUID takes 4, and the name "Clak Remote" takes 13. Swap in the 128-bit UUID and that one field costs 18 bytes, which no longer fits next to the name. So: long form in the GATT database, short form on the air.

```swift
let advertisementData: [String: Any] = [
    CBAdvertisementDataLocalNameKey: localName,
    CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
]
```

## 2. The first `add(_:)` throws

On macOS, the first `add(_:)` after creating the manager, or after `removeAllServices()`, can raise `NSInternalInconsistencyException`. That is an Objective-C exception. Swift can't catch it, so the app dies.

The fix has two parts. A tiny Objective-C shim turns the exception into a return value:

```objc
+ (nullable NSException *)tryBlock:(void (NS_NOESCAPE ^)(void))block {
    @try { block(); }
    @catch (NSException *exception) { return exception; }
    return nil;
}
```

And a disposable service goes first, so the exception lands on something that doesn't matter:

```swift
let warmup = CBMutableService(type: Self.warmupServiceUUID, primary: false)
warmup.characteristics = []
services.append(("_warmup", warmup))
```

If the warm-up add throws, the chain moves on to the real services. If a real service throws, publishing aborts and reports the failure, because advertising an HID keyboard with no HID service behind it gives you a device that's discoverable and can't be paired.

Services go in one at a time. Each waits for its `didAdd` callback, plus a 0.3 s pause on macOS, where CoreBluetooth needs settling time around `removeAllServices()` and `add(_:)`. When the warm-up add doesn't throw, an empty secondary service with a made-up UUID stays in the database. Nothing minds.

## 3. iOS connects, pairs, and never subscribes

This one took the longest. The iPhone found the keyboard, connected, wrote Suspend and Exit Suspend to the HID Control Point, and then never subscribed to the Report characteristic. No error anywhere. There were two causes, one on top of the other.

**Encryption.** HOGP requires an encrypted link for the Report Map, the Report characteristics, and the Control Point. CoreBluetooth has no "start pairing" call. Pairing happens when a central touches an attribute whose permissions demand encryption:

```swift
CBMutableCharacteristic(type: GATT.reportMap, properties: .read,
                        value: Data(reportMap.descriptor),
                        permissions: .readEncryptionRequired)
```

With plain `.readable`, iOS never starts bonding and never finishes HID setup. With `.readEncryptionRequired`, the first read triggers pairing.

**The Report Reference descriptor.** Apple's documentation says `CBMutableDescriptor` supports two descriptor types, Characteristic User Description (`0x2901`) and Characteristic Presentation Format (`0x2904`). HOGP needs a third: Report Reference, `0x2908`, two bytes that give each Report characteristic its Report ID and its type (input, output, or feature). Without it, iOS can't tell which characteristic carries which report, and it quietly declines to subscribe to any of them.

`0x2908` works anyway, on macOS and on iOS:

```swift
let desc = CBMutableDescriptor(type: CBUUID(string: "2908"),
                               value: Data([reportID, type]))
characteristic.descriptors = (characteristic.descriptors ?? []) + [desc]
```

The initialiser can raise for descriptor types it rejects, so this runs inside the same exception shim. The moment the descriptor was in place, a freshly paired iPhone subscribed.

This also shapes the reports. Each report gets its own characteristic, and the descriptor carries the ID, so the notification payload leaves the Report ID byte out: 8 bytes for the keyboard, 2 for consumer control (media keys), 4 for the mouse.

One trap while iterating: the host caches the report map. After any change to it, "Forget This Device" and pair again, or you'll be debugging the previous version.

## 4. A bonded host trusts its cache

A bonded central doesn't rediscover services when it reconnects. It trusts what it cached. If the database changed since then, the host can sit on a live, encrypted connection to a keyboard it can't see.

From the peripheral that state has a recognisable shape: the central writes the HID Control Point, which means it believes setup is finished, but it holds no subscription to any input report. When Clak sees exactly that, and the central is subscribed to Service Changed (`0x2A05`), it sends the indication to make the central rediscover.

The handle range matters. I send `0x0010–0xFFFF` rather than `0x0001–0xFFFF`. In my testing, a range that covers the Generic Attribute service's own handles made iOS stop honouring later indications altogether.

## 5. The Continuity identity fold

The phone said Clak Remote was advertising. My Mac's Bluetooth settings never listed it.

The cause was iCloud. An iOS app doesn't get a Bluetooth identity of its own: everything the phone advertises goes out under the phone's single, resolvable identity. A Mac signed into the same iCloud account is already bonded to that iPhone for Continuity (Handoff, Universal Clipboard, Instant Hotspot), a bond that doesn't appear in the device list. So the Mac hears the advertisement, resolves the rotating address to "my iPhone", and sees no new device worth listing.

To prove it I wrote a small CoreBluetooth scanner. It has to be a signed `.app` bundle with `NSBluetoothAlwaysUsageDescription`. A bare `swift` script that touches CoreBluetooth crashes with a TCC privacy violation. The scanner saw the "Clak Remote" advertisement with service `1812`, strong and continuous. Connecting to it returned one GATT server holding the iPhone's system services (Apple's Continuity service, Current Time, Battery) alongside Clak Remote's HID service. One identity, one merged database.

That turns section 4 into the real problem. The Mac had cached the iPhone's services long before Clak Remote existed, so its copy had no keyboard in it. And the usual fix is out of reach: the Mac isn't subscribed to a Service Changed characteristic belonging to an app it has never discovered.

What broke the loop the first time was forcing a fresh discovery from the Mac. A third-party central connects and reads the Report Map. macOS re-reads the database, and the system HID stack claims the keyboard. It shows up named after the iPhone rather than "Clak Remote", which is the fold again. Typing works. After that, relaunching the app gets the keyboard back in 3 to 6 seconds.

It didn't stay fixed. The cache went stale again every few hours, and the Mac-side read stopped being enough: in later measurements it succeeded five times running while macOS still ignored the keyboard. What worked every time was closing and reopening the iOS app, which republishes the GATT database. So the recovery moved into the app. While Clak Remote is in the foreground, advertising, with no host connected, a timer rebuilds the database and advertises again, first after 8 seconds, then backing off to 2 minutes. A host that is part-way through discovery or pairing is left alone for another round.

Two likely causes of the recurring staleness turned up along the way:

- **State restoration.** Clak Remote opts into CoreBluetooth state restoration so iOS can relaunch it for a bonded host. iOS also restores the old advertisement. The app then rebuilt its services from scratch, which moves the handles, while the old advertisement kept running, and the new start request failed with `CBError.alreadyAdvertising`. The Mac was looking at an advertisement for a database that no longer matched its cache. Now `willRestoreState` stops any restored advertisement before republishing, and "already advertising" is treated as the success it is.
- **A second Service Changed.** iOS already runs a system GATT server that owns `0x1801`. An app-owned copy dies with the process, and a host that subscribed to that copy loses its rediscovery signal. Clak Remote no longer publishes its own. macOS Clak keeps it, because there it's the nudge from section 4.

For Macs that still won't look, [`clak-remote-bootstrap.sh`](../clak-remote-bootstrap.sh) installs a small LaunchAgent. It watches for a "Clak Remote" advertisement that nobody claims for 10 seconds and forces the fresh read from the Mac's side. Given the measurements above it's a fallback rather than the fix. It idles at 0% CPU, and its log doubles as a record of how often the cache goes stale.

## Cheat sheet

| Symptom | Cause | Fix |
|---|---|---|
| `add(_:)` refuses the HID service | 16-bit `1812` is blocked | Register `00001812-0000-1000-8000-00805F9B34FB`; advertise `1812` |
| Crash on the first `add(_:)` | `NSInternalInconsistencyException`, uncatchable from Swift | Objective-C `@try` shim and a throwaway first service |
| iOS connects and never pairs | Attributes are readable without encryption | `.readEncryptionRequired` / `.writeEncryptionRequired` on Report Map, Reports, Control Point |
| iOS pairs, writes the Control Point, never subscribes | No Report Reference descriptor | Add `0x2908` with `[reportID, type]` (it works, whatever the docs say) |
| Bonded host reconnects and typing is dead | Stale GATT cache | Indicate Service Changed over `0x0010–0xFFFF` |
| iOS keyboard never appears on a Mac on the same iCloud | Advertisement folds into the phone's known identity; the cached database has no HID service | Republish the database from the app; force a fresh read from the Mac as a fallback |
