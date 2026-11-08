import Foundation
import Security

/// Collega il Mac alla rete WiFi della GoPro usando `networksetup`
/// (non richiede i permessi di localizzazione richiesti da CoreWLAN).
enum WiFiJoiner {
    static func wifiInterface() -> String? {
        guard let out = try? run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device:") {
                return lines[i + 1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }

    static func join(ssid: String, password: String) async throws {
        try await Task.detached {
            guard let iface = wifiInterface() else { throw message("Interfaccia WiFi non trovata.") }
            let out = try run("/usr/sbin/networksetup", ["-setairportnetwork", iface, ssid, password])
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {   // networksetup stampa qualcosa solo in caso di errore
                throw message(trimmed)
            }
        }.value
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func message(_ s: String) -> NSError {
        NSError(domain: "WiFi", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}

/// Salvataggio della password WiFi della camera nel Portachiavi.
enum Keychain {
    private static let service = "GoProConnector.wifi"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
