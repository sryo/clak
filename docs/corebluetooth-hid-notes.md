# What CoreBluetooth doesn't tell you about being a keyboard

Clak makes a Mac show up as an ordinary Bluetooth keyboard for an iPhone, iPad, or Apple TV. Clak Remote does the reverse: the iPhone becomes a keyboard and trackpad for the Mac. Neither side installs anything on the receiving device, because both apps implement the standard HID over GATT Profile (HOGP) with plain `CBPeripheralManager`. No private frameworks, no kernel extension, no dongle.

Apple doesn't document this as possible. In one place the documentation says a required piece of it can't be done. These are the walls I hit, in the order I hit them, and what got through each one. Nearly all of it lives in [`BLEHIDPeripheralManager.swift`](../Clak/Bluetooth/BLEHIDPeripheralManager.swift), which both apps compile, next to the report map in [`HIDReportMap.swift`](../Clak/Bluetooth/HIDReportMap.swift) and a small Objective-C shim. The Clak Remote recovery timer from section 5 lives in [`RemoteController.swift`](../ClakRemote/RemoteController.swift).

(I tried Classic Bluetooth first. On current macOS, `bluetoothd` owns the HID L2CAP channels, PSM 17 and 19, and an iPhone ignored the custom PSMs I tried instead. BLE was the only road left.)

## 1. The HID service UUID is blocked, unless you spell it out

The first thing a keyboard needs is the HID service, `0x1812`. CoreBluetooth won't publish it. `add(_:)` doesn't throw; the refusal arrives in `peripheralManager(_:didAdd:error:)` as `CBError.uuidNotAllowed` (code 8), "The specified UUID is not allowed for this operation."

```swift
// didAdd reports CBError.uuidNotAllowed
CBMutableService(type: CBUUID(string: "1812"), primary: true)

// Accepted
CBMutableService(type: CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"), primary: true)
```

Every 16-bit Bluetooth UUID is shorthand for a full 128-bit UUID built on the Bluetooth Base UUID, `0000xxxx-0000-1000-8000-00805F9B34FB`. The two forms are the same UUID, and a client that discovers the long one sees an HID service. (You'll find claims that hosts don't treat the long form as the standard service. iOS, iPadOS, tvOS and macOS all bind Clak as an ordinary keyboard.) `CBUUID` even says they're equal, but it stores 2 bytes for one and 16 for the other, and the check in `add(_:)` only seems to recognise the short one.

The blocklist is short. On macOS 27.2, the short form is refused for these seven, and the long form of every one is accepted:

| UUID | Service |
|---|---|
| `1800` | Generic Access |
| `1801` | Generic Attribute |
| `1805` | Current Time |
| `180A` | Device Information |
| `180F` | Battery |
| `1812` | Human Interface Device |
| `181E` | Bond Management |

It reads like the list of services the system's own GATT server already owns. Most of the rest go through in short form, Heart Rate (`180D`) and Scan Parameters (`1813`) included. Clak registers Generic Attribute and Device Information in long form too. Characteristic UUIDs aren't checked: `2A4D`, `2A4B` and the rest work in short form.

The advertisement is the opposite case. The short form is allowed there, and you want it there. A legacy advertising packet holds 31 bytes, and the OS spends 3 of them on Flags. A 16-bit service UUID takes 4, and the name "Clak Remote" takes 13. Swap in the 128-bit UUID and that one field costs 18 bytes, which no longer fits next to the name. CoreBluetooth won't fail when that happens. Advertising is best effort, so the name gets truncated or the UUID moves to an overflow area only Apple devices read. So: long form in the GATT database, short form on the air.

```swift
let advertisementData: [String: Any] = [
    CBAdvertisementDataLocalNameKey: localName,
    CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1812")],
]
```

## 2. `add(_:)` can throw, and Swift can't catch it

Early on, the first `add(_:)` after creating the manager or calling `removeAllServices()` raised `NSInternalInconsistencyException`. That is an Objective-C exception. Swift can't catch it, so the app dies.

I can no longer reproduce that. On macOS 27.2 the first add never threw: not on five fresh managers, not straight after `removeAllServices()`, not without a warm-up. Only two things made `add(_:)` throw:

- A static value on a characteristic that isn't read-only: "Characteristics with cached values must be read-only". My early Battery service, with a value and `.notify`, was exactly this.
- Adding the same `CBMutableService` object twice: "Services cannot be added more than once".

So treat what follows as a precaution. A tiny Objective-C shim turns the exception into a return value:

```objc
+ (nullable NSException *)tryBlock:(void (NS_NOESCAPE ^)(void))block {
    @try { block(); }
    @catch (NSException *exception) { return exception; }
    return nil;
}
```

And a disposable service goes first, so if anything throws, it lands on something that doesn't matter:

```swift
let warmup = CBMutableService(type: Self.warmupServiceUUID, primary: false)
warmup.characteristics = []
services.append(("_warmup", warmup))
```

If the warm-up add throws, the chain moves on to the real services. If a real service throws or comes back with an error, publishing aborts and reports the failure, because advertising an HID keyboard with no HID service behind it gives you a device that's discoverable and can't be paired.

Services go in one at a time. Each waits for its `didAdd` callback, plus a short pause: 0.3 s on macOS and 0.05 s on iOS. The pause dates from the same early trouble around `removeAllServices()` and `add(_:)`, and current macOS didn't need it in testing. The empty secondary service with a made-up UUID stays in the database. Nothing minds.

## 3. iOS connects, pairs, and never subscribes

This one took the longest. The iPhone found the keyboard, connected, wrote Suspend and Exit Suspend to the HID Control Point, and then never subscribed to the Report characteristic. No error anywhere. There were two causes, one on top of the other.

**Encryption.** HOGP puts every characteristic of the HID service behind an encrypted link (Security Mode 1, Level 2 or 3). CoreBluetooth has no "start pairing" call. Pairing happens when a central touches an attribute whose permissions demand encryption:

```swift
CBMutableCharacteristic(type: GATT.reportMap, properties: .read,
                        value: Data(reportMap.descriptor),
                        permissions: .readEncryptionRequired)
```

With plain `.readable`, iOS never starts bonding and never finishes HID setup. With `.readEncryptionRequired`, the first read triggers pairing. Clak encrypts the Report Map, every Report characteristic (the LED output report included), and the Control Point. HID Information and Protocol Mode stay plain `.readable`, which the spec doesn't allow, but no host has objected.

**The Report Reference descriptor.** Apple's documentation says `CBMutableDescriptor` supports only two descriptor types, Characteristic User Description (`0x2901`) and Characteristic Presentation Format (`0x2904`). HOGP needs a third: Report Reference, `0x2908`, two bytes that give each Report characteristic its Report ID and its type (1 input, 2 output, 3 feature). The spec makes it mandatory on every Report characteristic. Without it, iOS can't tell which characteristic carries which report, and it quietly declines to subscribe to any of them.

`0x2908` works anyway, on macOS and on iOS:

```swift
let desc = CBMutableDescriptor(type: CBUUID(string: "2908"),
                               value: Data([reportID, type]))
characteristic.descriptors = (characteristic.descriptors ?? []) + [desc]
```

The documentation is far narrower than the implementation. `add(_:)` accepts almost any descriptor type. It refuses only the ones the system manages itself: `0x2900`, `0x2902` (the subscription descriptor) and `0x2903`, with `CBError.invalidParameters`. The initialiser itself only checks value types. It raises if `0x2901` isn't given a string or `0x2904` isn't given data. The descriptor code still runs inside the exception shim. The moment the descriptor was in place, a freshly paired iPhone subscribed.

This also shapes the reports. Each report gets its own characteristic, and the descriptor carries the ID, so the notification payload leaves the Report ID byte out: 8 bytes for the keyboard, 2 for consumer control (media keys), 4 for the mouse. Clak Remote adds a fifth mouse byte for horizontal scroll and declares high-resolution scrolling. Clak keeps the 4-byte report, so existing bonds stay valid.

One trap while iterating: the host caches the report map. After any change to it, "Forget This Device" and pair again, or you'll be debugging the previous version.

## 4. A bonded host trusts its cache

A bonded central doesn't rediscover services when it reconnects. It trusts what it cached. If the database changed since then, the host can sit on a live, encrypted connection to a keyboard it can't see. CoreBluetooth gives a peripheral app no control over the newer caching tools (Database Hash, Robust Caching), so the Service Changed characteristic (`0x2A05`) is the only lever.

From the peripheral that state has a recognisable shape: the central writes the HID Control Point, which means it believes setup is finished, but it holds no subscription to any input report. When Clak sees any Control Point write in that state, and the central is subscribed to Service Changed, it sends the indication to make the central rediscover. It does that at most once per session, and retries from `peripheralManagerIsReady(toUpdateSubscribers:)` if the indication bounces.

The handle range matters. I send `0x0010–0xFFFF` rather than `0x0001–0xFFFF`. In my testing, a range that covers the Generic Attribute service's own handles made iOS stop honouring later indications altogether. I've found one other report of that, on Apple's developer forums. The spec allows the full range. CoreBluetooth never exposes handles, so `0x0010` is a heuristic: it assumes the Generic Attribute service sits in the first few handles.

This is Clak's mechanism. Clak Remote doesn't publish its own Generic Attribute service (section 5), so on iOS it never fires.

## 5. The Continuity identity fold

The phone said Clak Remote was advertising. My Mac's Bluetooth settings never listed it.

The cause was iCloud. An iOS app doesn't get a Bluetooth identity of its own: everything the phone advertises goes out under the phone's single, resolvable identity. A Mac signed into the same iCloud account is already bonded to that iPhone for Continuity (Handoff, Universal Clipboard, Instant Hotspot), a bond that doesn't appear in the device list. So the Mac hears the advertisement, resolves the rotating address to "my iPhone", and sees no new device worth listing.

To prove it I wrote a small CoreBluetooth scanner. Creating a Bluetooth manager needs a bundle with `NSBluetoothAlwaysUsageDescription`, so I built it as a signed `.app`. A bare `swift` script that creates one is killed with a TCC privacy violation. The scanner saw the "Clak Remote" advertisement with service `1812`, strong and continuous. Connecting to it returned one GATT server holding the iPhone's system services (Apple's Continuity service, Device Information, Current Time, Battery) alongside Clak Remote's HID service. One identity, one merged database.

That turns section 4 into the real problem. The Mac had cached the iPhone's services long before Clak Remote existed, so its copy had no keyboard in it. And the usual fix is out of reach: the Mac isn't subscribed to a Service Changed characteristic belonging to an app it has never discovered.

What broke the loop the first time was forcing a fresh discovery from the Mac. A third-party central connects and reads the Report Map. macOS re-reads the database, and the system HID stack claims the keyboard. It shows up named after the iPhone rather than "Clak Remote", which is the fold again. Typing works. After that, relaunching the app got the keyboard back in about 3 seconds, and later runs took 4 to 6.

It didn't stay fixed. The cache went stale again every few hours, and the Mac-side read stopped being enough: in later measurements it succeeded five times running while macOS still ignored the keyboard. What worked was closing and reopening the iOS app, which republishes the GATT database. It didn't always take on the first republish, but a second one got through. So the recovery moved into the app. While Clak Remote is in the foreground and advertising, which it stops doing once a host subscribes, a timer rebuilds the database and advertises again. The first rebuild comes after 8 seconds, and the delay doubles up to 2 minutes. The timer stands down in the background, because a backgrounded iOS app's advertisement drops its local name and moves its service UUIDs to the overflow area, where the rebuild wouldn't help.

Two likely causes of the recurring staleness turned up along the way:

- **State restoration.** Clak Remote opts into CoreBluetooth state restoration so iOS can relaunch it for a bonded host. iOS also restores the old advertisement. The app then rebuilt its services from scratch, which moves the handles, while the old advertisement kept running, and the new start request failed with `CBError.alreadyAdvertising`. The Mac was looking at an advertisement for a database that no longer matched its cache. Now `willRestoreState` stops any restored advertisement before republishing, and "already advertising" is treated as the success it is.
- **A second Service Changed.** iOS already runs a system GATT server that owns `0x1801`. An app-owned copy dies with the process, and a host that subscribed to that copy loses its rediscovery signal. Clak Remote no longer publishes its own. Reclaiming still works without it, but I haven't watched long enough to know whether it stops the recurrence. macOS Clak keeps it, because there it's the nudge from section 4.

For Macs that still won't look, [`clak-remote-bootstrap.sh`](../clak-remote-bootstrap.sh) installs a small LaunchAgent that stays resident. It watches for a Clak Remote advertisement that nobody claims for 10 seconds and forces the fresh read from the Mac's side. Consecutive forced reads back off from 1 to 10 minutes, so a Mac you're deliberately not connecting won't keep grabbing the phone. Given the measurements above it's a fallback rather than the fix. Its only regular work is a coalesced one-second timer, so it sits near 0% CPU. Its log doubles as a record of how often the cache goes stale.

Some dead ends, so you don't repeat them:

- `retrieveConnectedPeripherals(withServices: [1812])` on the Mac returned nothing for the folded phone, even while macOS held the keyboard. Don't use it to check whether the system has claimed Clak Remote.
- Toggling Bluetooth or killing `bluetoothd` doesn't force a re-read. It reconnects from the cache.
- `hidutil list | grep "Bluetooth Low Energy.*AppleUserHIDEventService"` is the quickest way to tell whether macOS has claimed the keyboard.

## 6. Smaller things

**Nobody tells you a host connected.** A peripheral gets no connect callback. The first sign of a host is a read, a write, or a subscription. Clak treats a subscription to an input report as "connected", stops advertising, and ignores centrals subscribed only to Service Changed, because they can't receive keys.

**Notifications can back up.** `updateValue(_:for:onSubscribedCentrals:)` returns `false` when CoreBluetooth's transmit queue is full. Clak queues the report and drains the queue when `peripheralManagerIsReady(toUpdateSubscribers:)` fires. A pending Service Changed goes first, and new reports wait behind queued ones so keys never arrive out of order.

What the queue does when it grows matters more than it looks. Dropping the oldest report, which Clak used to do, can drop a key-up, and the host then auto-repeats that key forever. So nothing the host would act on is thrown away:

- An identical repeat of the report before it is skipped.
- Pointer motion with the same buttons is summed into the report before it, up to ±127 per axis, so a fast drag stops piling up lag.
- A full queue (64) collapses to the newest report per characteristic. Keystrokes in the middle are lost, but the final state, every key-up included, always survives.

Pastes on macOS wait for room in the queue rather than filling it.

**Send a report as soon as a host subscribes.** Some hosts hold off using a report until its first notification arrives. Clak sends an all-zero report to the subscribing host only, since broadcasting it would release keys another host is holding.

**Validate the whole write batch first.** `didReceiveWrite` can hand you several requests at once, and CoreBluetooth treats them as a unit: answer the first request once, with success or with the first error, and apply nothing if any request is bad.

**What Clak skips from the spec.** iOS, iPadOS and macOS accept all of these gaps, but a stricter host might not:

- **Boot Keyboard reports.** The HID service spec requires them (`2A22`/`2A32`) for keyboards. Clak has none, and Protocol Mode is recorded but reports always use Report protocol.
- **Battery Service.** HOGP requires one. `180F` is on the blocklist in short form, and the early attempt failed for the static-value reason in section 2. Clak on macOS now publishes it in long form, last so no earlier handle moves, with a dynamic, notifying Battery Level answered from the Mac's battery (100 on a desktop). Clak Remote leaves it out: the phone's own GATT database already has one.
- **Appearance.** The spec says a keyboard should advertise it (`0x03C1`). CoreBluetooth has no advertising key for it, and no way to set the GAP Appearance.
- **Device Information.** The PnP ID uses a placeholder vendor ID, `0xFFFF`, with product ID `0x0100`. HID Information is `11 01 00 02`: HID 1.11, no country code, normally connectable, no remote wake.

## Who else found what

I worked out sections 1 to 3 in February 2026. Others have landed on parts of them, mostly as code without the reasons:

- The 128-bit `1812` and the `0x2908` descriptor both appear in 2024 comments on [conath's HID keyboard gist](https://gist.github.com/conath/c606d95d58bbcb50e9715864eeeecf07).
- [stass/blew](https://github.com/stass/blew/blob/main/DESIGN.md) lists the same seven blocked UUIDs on macOS, from late February 2026.

As far as I can tell, sections 4 and 5 aren't written down anywhere else: spotting a stale host from the peripheral side, Service Changed from a CoreBluetooth app, the Continuity fold and everything around it. The same goes for the descriptor rules in section 3 and the gaps in section 6.

## Cheat sheet

| Symptom | Cause | Fix |
|---|---|---|
| `didAdd` fails with `uuidNotAllowed` (code 8) | 16-bit `1812` (and `1800`, `1801`, `1805`, `180A`, `180F`, `181E`) is blocked | Register `00001812-0000-1000-8000-00805F9B34FB`; advertise `1812` |
| Crash inside `add(_:)` | `NSInternalInconsistencyException`: a static value on a non-read-only characteristic, or the same service added twice | Fix the characteristic; keep the Objective-C `@try` shim and a throwaway first service as a precaution |
| iOS connects and never pairs | Attributes are readable without encryption | `.readEncryptionRequired` / `.writeEncryptionRequired` on the HID service's characteristics |
| iOS pairs, writes the Control Point, never subscribes | No Report Reference descriptor | Add `0x2908` with `[reportID, type]` (it works, whatever the docs say) |
| Bonded Mac host reconnects and typing is dead | Stale GATT cache | Clak: indicate Service Changed over `0x0010–0xFFFF` |
| iOS keyboard never appears on a Mac on the same iCloud | Advertisement folds into the phone's known identity; the cached database has no HID service | Republish the database from the app; force a fresh read from the Mac as a fallback |
