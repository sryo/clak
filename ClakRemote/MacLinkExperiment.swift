import CoreBluetooth
import Observation
import SwiftUI

/// Experiment (`-ClakRemoteMacLink YES`): reach the Mac from the phone's side
/// as a central, for a Mac on the same iCloud account that folds Clak Remote
/// into its Continuity bond and ignores the advertisement. The odds are low
/// — if a Continuity link is already up, connect() just shares it and the Mac
/// sees nothing new — so it logs everything and ships only with data.
@Observable
final class MacLinker: NSObject {

    /// Nil unless the flag is set: nobody else should get a central manager.
    static let shared: MacLinker? = UserDefaults.standard.bool(forKey: "ClakRemoteMacLink") ? MacLinker() : nil

    struct Candidate: Identifiable {
        let peripheral: CBPeripheral
        let source: String
        var rssi: Int?
        var id: UUID { peripheral.identifier }
        var name: String { peripheral.name ?? "Unnamed (\(peripheral.identifier.uuidString.prefix(8)))" }
    }

    private(set) var candidates: [Candidate] = []
    private(set) var isScanning = false
    private(set) var linkedID: UUID?

    @ObservationIgnored
    private var central: CBCentralManager!

    /// Apple's Continuity service and Device Information, which a Mac linked
    /// to this phone exposes.
    private static let knownServices = [CBUUID(string: "D0611E78-BBB4-4591-A5F8-487910AE4366"),
                                        CBUUID(string: "180A")]
    private static let savedMacKey = "ClakRemoteMacLinkPeripheral"

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Lists linked devices, the Mac chosen last time, and connectable Apple
    /// devices heard in a 10 s scan.
    func refresh() {
        guard central.state == .poweredOn else { return }
        candidates.removeAll()
        for peripheral in central.retrieveConnectedPeripherals(withServices: Self.knownServices) {
            add(peripheral, source: "linked")
        }
        if let saved = UserDefaults.standard.string(forKey: Self.savedMacKey).flatMap(UUID.init(uuidString:)) {
            for peripheral in central.retrievePeripherals(withIdentifiers: [saved]) {
                add(peripheral, source: "chosen before")
            }
        }
        isScanning = true
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.central.stopScan()
            self?.isScanning = false
        }
        Log.bluetooth.notice("MacLink: \(self.candidates.count, privacy: .public) linked or saved candidates, scanning")
    }

    func connect(_ candidate: Candidate) {
        UserDefaults.standard.set(candidate.id.uuidString, forKey: Self.savedMacKey)
        Log.bluetooth.notice("MacLink: connecting to \(candidate.name, privacy: .public) (\(candidate.source, privacy: .public), state=\(candidate.peripheral.state.rawValue, privacy: .public))")
        central.connect(candidate.peripheral)
    }

    private func add(_ peripheral: CBPeripheral, source: String, rssi: Int? = nil) {
        if let index = candidates.firstIndex(where: { $0.id == peripheral.identifier }) {
            candidates[index].rssi = rssi ?? candidates[index].rssi
        } else {
            candidates.append(Candidate(peripheral: peripheral, source: source, rssi: rssi))
        }
    }
}

extension MacLinker: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Answers "is the folded Mac even linked when it ignores us?", which
        // matters whether or not connecting helps
        central.registerForConnectionEvents(options: nil)
        refresh()
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        Log.bluetooth.notice("MacLink: \(event == .peerConnected ? "peer connected" : "peer disconnected", privacy: .public) \(peripheral.name ?? peripheral.identifier.uuidString, privacy: .public)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Apple devices only (manufacturer data starts 4C 00), and only ones
        // that take connections
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.starts(with: [0x4C, 0x00]),
              advertisementData[CBAdvertisementDataIsConnectable] as? Bool == true else { return }
        add(peripheral, source: "scan", rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.bluetooth.notice("MacLink: connected to \(peripheral.name ?? peripheral.identifier.uuidString, privacy: .public)")
        linkedID = peripheral.identifier
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.bluetooth.error("MacLink: connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.bluetooth.notice("MacLink: disconnected \(error?.localizedDescription ?? "", privacy: .public)")
        if linkedID == peripheral.identifier { linkedID = nil }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none"
        Log.bluetooth.notice("MacLink: Mac exposes \(services, privacy: .public)")
    }
}

/// The experiment's picker. Deliberately plain: it never ships without data.
struct MacLinkSheet: View {
    let linker: MacLinker

    var body: some View {
        NavigationStack {
            List(linker.candidates) { candidate in
                Button {
                    linker.connect(candidate)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(candidate.name)
                            Text(candidate.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if linker.linkedID == candidate.id {
                            Image(systemName: "link")
                        } else if let rssi = candidate.rssi {
                            Text("\(rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if linker.candidates.isEmpty {
                    ContentUnavailableView(linker.isScanning ? "Looking…" : "Nothing found",
                                           systemImage: "desktopcomputer")
                }
            }
            .navigationTitle("Connect from this iPhone")
            .toolbar {
                Button("Refresh") { linker.refresh() }
                    .disabled(linker.isScanning)
            }
        }
    }
}
