import CoreBluetooth
import Foundation
import Observation

/// Attiva il WiFi (access point) della GoPro via Bluetooth Low Energy, come fa l'app Quik,
/// e legge nome rete e password direttamente dalla camera.
///
/// La prima volta la camera deve essere in modalità abbinamento
/// (Preferenze › Connessioni › Connetti dispositivo › App GoPro) e macOS chiederà di confermare l'abbinamento.
@MainActor
@Observable
final class GoProBluetooth: NSObject {
    enum Phase: Equatable {
        case idle, working, done, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var statusText = ""

    struct Candidate: Identifiable {
        let id: UUID
        var name: String
        var advertisedName: String
        var rssi: Int
        let peripheral: CBPeripheral
    }

    /// Una camera può comparire con più identità Bluetooth: per la scelta si raggruppano per nome.
    struct CameraChoice: Identifiable {
        let name: String
        let rssi: Int
        let identities: Int
        var id: String { name }
    }

    var choices: [CameraChoice] {
        Dictionary(grouping: candidates, by: \.name).map { name, list in
            CameraChoice(name: name, rssi: list.map(\.rssi).max() ?? -100, identities: list.count)
        }.sorted { $0.rssi > $1.rssi }
    }
    /// GoPro trovate durante la scansione; se sono più di una l'utente sceglie la sua.
    private(set) var candidates: [Candidate] = []
    private(set) var awaitingChoice = false
    private var chosenName: String?
    private var scanning = false

    var rememberedCameraName: String? { UserDefaults.standard.string(forKey: Self.savedNameKey) }

    // UUID GoPro
    private static func gp(_ n: String) -> CBUUID { CBUUID(string: "b5f9\(n)-aa8d-11e3-9046-0002a5d5c51b") }
    static let controlService = CBUUID(string: "FEA6")
    static let wifiService = gp("0001")
    static let ssidChar = gp("0002")
    static let passwordChar = gp("0003")
    static let apPowerChar = gp("0004")
    static let commandChar = gp("0072")
    static let commandResponseChar = gp("0073")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServiceCount = 0
    private var lastRead: Data?
    private var readingUUID: CBUUID?
    private var waitingForAPResponse = false
    private var apResponseStatus: UInt8?

    private var pending: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    private static let savedPeripheralKey = "bleCameraIdentifier"
    private static let savedNameKey = "bleCameraName"

    func forgetCamera() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
        UserDefaults.standard.removeObject(forKey: Self.savedNameKey)
        statusText = ""
        log("Camera forgotten")
    }

    func choose(_ name: String) {
        guard awaitingChoice else { return }
        chosenName = name
        awaitingChoice = false
        log("User chose: \(name)")
        finish()
    }

    struct Credentials: Sendable {
        let ssid: String
        let password: String
    }

    // MARK: - API

    /// Esegue tutta la sequenza e restituisce le credenziali WiFi della camera.
    func activateWiFi() async throws -> Credentials {
        phase = .working
        do {
            let creds = try await runSequence()
            phase = .done
            return creds
        } catch {
            let msg = error.localizedDescription
            phase = .failed(msg)
            log("ERROR: \(msg)")
            throw error
        }
    }

    /// Spegne l'access point della camera (comando 0x17 = 0): il Mac torna da solo sulla rete di casa.
    func turnOffWiFi() async {
        guard let p = peripheral, p.state == .connected, let command = characteristics[Self.commandChar] else {
            log("Skipping WiFi off: camera not connected over Bluetooth")
            return
        }
        apResponseStatus = nil
        waitingForAPResponse = true
        try? await wait(5, String(localized: "turning off WiFi")) {
            p.writeValue(Data([0x03, 0x17, 0x01, 0x00]), for: command, type: .withResponse)
        }
        waitingForAPResponse = false
        status(String(localized: "Camera WiFi turned off"))
    }

    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        characteristics = [:]
    }

    // MARK: - Sequenza

    private func runSequence() async throws -> Credentials {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)   // delegate sulla main queue
        }
        guard let central else { throw BLEError.message(String(localized: "Bluetooth not available.")) }

        status(String(localized: "Starting Bluetooth…"))
        if central.state != .poweredOn {
            try await wait(10, String(localized: "Bluetooth start-up")) {}
        }
        try checkState(central.state)

        // 1. Camera già connessa in questa sessione
        if let existing = peripheral, existing.state == .connected {
            status(String(localized: "Camera already connected over Bluetooth"))
            return try await pairAndActivate(existing)
        }

        // 2. Camera abbinata in precedenza
        if let idString = UserDefaults.standard.string(forKey: Self.savedPeripheralKey),
           let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("Using the paired camera \(known.name ?? id.uuidString) [\(id.uuidString.prefix(8))]")
            do {
                try await connect(known, central)
                return try await pairAndActivate(known)
            } catch {
                log("Remembered camera not usable (\(error.localizedDescription)), scanning again")
                central.cancelPeripheralConnection(known)
                UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            }
        }

        // 3. Scansione: si provano tutte le identità Bluetooth della camera scelta
        let identities = try await scanForCamera(central)
        var lastError: Error?
        for (i, p) in identities.enumerated() {
            do {
                try await connect(p, central)
                return try await pairAndActivate(p)
            } catch {
                lastError = error
                log("Identity \(i + 1)/\(identities.count) [\(p.identifier.uuidString.prefix(8))] failed: \(error.localizedDescription)")
                central.cancelPeripheralConnection(p)
                if i < identities.count - 1 {
                    status(String(localized: "Trying the camera's other Bluetooth identity (\(i + 2)/\(identities.count))…"))
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        throw lastError ?? BLEError.message(String(localized: "No usable GoPro found."))
    }

    private func pairAndActivate(_ p: CBPeripheral) async throws -> Credentials {
        // 2. Servizi e caratteristiche
        if characteristics[Self.commandChar] == nil || characteristics[Self.ssidChar] == nil {
            status(String(localized: "Reading the camera's services…"))
            characteristics = [:]
            try await wait(15, String(localized: "reading services")) { p.discoverServices([Self.controlService, Self.wifiService]) }
        }
        guard let command = characteristics[Self.commandChar],
              let response = characteristics[Self.commandResponseChar],
              let ssidC = characteristics[Self.ssidChar],
              let passC = characteristics[Self.passwordChar] else {
            throw BLEError.message(String(localized: "The camera doesn't expose the expected GoPro services (found: \(characteristics.keys.map(\.uuidString).sorted().joined(separator: ", ")))."))
        }

        // 3. Notifiche delle risposte (qui macOS può chiedere l'abbinamento)
        status(String(localized: "Pairing / authorization… (if macOS shows a request, click Connect)"))
        try await wait(40, String(localized: "Bluetooth pairing")) { p.setNotifyValue(true, for: response) }

        // 4. Credenziali WiFi
        status(String(localized: "Reading network name and password…"))
        let ssid = try await readString(ssidC, from: p)
        let password = try await readString(passC, from: p)
        log("SSID read: \(ssid)")
        // abbinamento riuscito: da ora questa è la camera da usare
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedPeripheralKey)
        UserDefaults.standard.set(p.name ?? ssid, forKey: Self.savedNameKey)

        // 5. Accensione dell'access point WiFi: comando 0x17 (AP control) = 1
        status(String(localized: "Turning on the camera's WiFi…"))
        apResponseStatus = nil
        waitingForAPResponse = true
        do {
            try await wait(8, String(localized: "WiFi command response")) {
                p.writeValue(Data([0x03, 0x17, 0x01, 0x01]), for: command, type: .withResponse)
            }
        } catch {
            log("No response to command 0x17 (\(error.localizedDescription)), trying GP-0004")
        }
        waitingForAPResponse = false
        if let s = apResponseStatus, s != 0 { log("Camera answered the WiFi command with status \(s)") }
        if apResponseStatus != 0, let power = characteristics[Self.apPowerChar] {
            try? await wait(8, String(localized: "turning on WiFi (GP-0004)")) {
                p.writeValue(Data([0x01]), for: power, type: .withResponse)
            }
        }

        status(String(localized: "Camera WiFi on (\(ssid))"))
        return Credentials(ssid: ssid, password: password)
    }

    private func scanForCamera(_ central: CBCentralManager) async throws -> [CBPeripheral] {
        status(String(localized: "Searching for GoPro cameras over Bluetooth… (keep the camera on and near the Mac)"))
        candidates = []
        chosenName = nil
        scanning = true
        central.scanForPeripherals(withServices: nil, options: nil)
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(500))
            if Date().timeIntervalSince(start) >= 6 && !candidates.isEmpty { break }
        }
        central.stopScan()
        scanning = false
        log("GoPro cameras found: " + candidates.map {
            "\($0.name) (adv \"\($0.advertisedName)\") [\($0.id.uuidString.prefix(8))] \($0.rssi) dBm"
        }.joined(separator: ", "))
        if candidates.isEmpty {
            throw BLEError.message(String(localized: "No GoPro found over Bluetooth. Is the camera on and showing the pairing screen?"))
        }

        let names = choices
        var name = names[0].name
        if names.count > 1 {
            awaitingChoice = true
            status(String(localized: "Found \(names.count) different GoPro cameras: choose yours (the name is in Preferences › Connections › Camera Info)."))
            defer { awaitingChoice = false }
            try await wait(180, String(localized: "camera choice")) {}
            guard let chosenName else { throw BLEError.message(String(localized: "No camera chosen.")) }
            name = chosenName
        }
        let list = candidates.filter { $0.name == name }.sorted { $0.rssi > $1.rssi }
        if list.count > 1 { log("\(name) has \(list.count) Bluetooth identities: trying them all") }
        return list.map(\.peripheral)
    }

    private func connect(_ p: CBPeripheral, _ central: CBCentralManager) async throws {
        peripheral = p
        p.delegate = self
        characteristics = [:]
        status(String(localized: "Connecting over Bluetooth to \(p.name ?? "GoPro")…"))
        log("Identity [\(p.identifier.uuidString.prefix(8))]")
        try await wait(15, String(localized: "Bluetooth connection")) { central.connect(p) }
    }

    private func readString(_ c: CBCharacteristic, from p: CBPeripheral) async throws -> String {
        readingUUID = c.uuid
        lastRead = nil
        try await wait(10, c.uuid == Self.ssidChar ? String(localized: "reading network name") : String(localized: "reading password")) { p.readValue(for: c) }
        readingUUID = nil
        guard let data = lastRead, let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespaces)), !s.isEmpty else {
            throw BLEError.message(String(localized: "Empty value read from the camera."))
        }
        return s
    }

    // MARK: - Utilità

    private func wait(_ seconds: Double, _ what: String, start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending = cont
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                self?.finish(BLEError.message(String(localized: "Timed out: \(what).")))
            }
            start()
        }
    }

    private func finish(_ error: Error? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let c = pending else { return }
        pending = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    private func checkState(_ state: CBManagerState) throws {
        switch state {
        case .poweredOn: return
        case .unauthorized:
            throw BLEError.message(String(localized: "Bluetooth permission denied. Turn it on in System Settings › Privacy & Security › Bluetooth."))
        case .poweredOff: throw BLEError.message(String(localized: "The Mac's Bluetooth is off."))
        case .unsupported: throw BLEError.message(String(localized: "This Mac doesn't support Bluetooth Low Energy."))
        default: throw BLEError.message(String(localized: "Bluetooth not ready (state \(state.rawValue))."))
        }
    }

    private func status(_ s: String) {
        statusText = s
        log(s)
    }

    private func log(_ s: String) {
        AppLog.write("[BLE] \(s)")
    }

    enum BLEError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }
}

// MARK: - Delegate (chiamati sulla main queue)

extension GoProBluetooth: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            log("Bluetooth state: \(state.rawValue)")
            if state == .poweredOn { finish() }
            else if state != .unknown && state != .resetting {
                do { try checkState(state) } catch { finish(error) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let isGoPro = services.contains(Self.controlService)
                || name.lowercased().hasPrefix("gopro") || name.uppercased().hasPrefix("HERO")
            guard isGoPro, scanning else { return }
            let display = peripheral.name ?? (name.isEmpty ? "GoPro" : name)
            if let i = candidates.firstIndex(where: { $0.id == peripheral.identifier }) {
                candidates[i].rssi = rssi
                candidates[i].name = display
            } else {
                candidates.append(Candidate(id: peripheral.identifier, name: display, advertisedName: name,
                                            rssi: rssi, peripheral: peripheral))
                log("Found \(display) (advertised as \"\(name)\") \(rssi) dBm")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            log("Connected over Bluetooth")
            finish()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
            finish(BLEError.message(String(localized: "Bluetooth connection failed: \(error?.localizedDescription ?? String(localized: "unknown error"))")))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log("Bluetooth disconnected \(error.map { "(\($0.localizedDescription))" } ?? "")")
            characteristics = [:]
            finish(BLEError.message(error.map { String(localized: "The camera closed the Bluetooth connection: \($0.localizedDescription)") }
                                     ?? String(localized: "The camera closed the Bluetooth connection.")))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error { finish(error); return }
            let services = peripheral.services ?? []
            log("Services: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
            pendingServiceCount = services.count
            if services.isEmpty { finish(); return }
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] { characteristics[c.uuid] = c }
            pendingServiceCount -= 1
            if pendingServiceCount <= 0 { finish() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                UserDefaults.standard.removeObject(forKey: Self.savedPeripheralKey)
                finish(BLEError.message(String(localized: "Pairing failed: \(error.localizedDescription). Put the camera in pairing mode (Preferences › Connections › Connect Device › GoPro App) and try again.")))
            } else {
                finish()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        let value = characteristic.value
        MainActor.assumeIsolated {
            if uuid == Self.commandResponseChar {
                let bytes = [UInt8](value ?? Data())
                log("Command response: \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
                if waitingForAPResponse, bytes.count >= 3, bytes[1] == 0x17 {
                    apResponseStatus = bytes[2]
                    finish()
                }
                return
            }
            if uuid == readingUUID {
                if let error {
                    finish(BLEError.message(String(localized: "Read not authorized: \(error.localizedDescription). The camera must be paired.")))
                } else {
                    lastRead = value
                    finish()
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            if let error {
                log("Write to \(uuid.uuidString) failed: \(error.localizedDescription)")
                if uuid == Self.apPowerChar { finish(error) }
                return
            }
            // per GP-0072 si attende la notifica su GP-0073; GP-0004 non ha risposta separata
            if uuid == Self.apPowerChar { finish() }
        }
    }
}

/// Log su file per la diagnosi: ~/Library/Logs/GoProConnector.log
enum AppLog {
    static let url: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs/GoProConnector.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
