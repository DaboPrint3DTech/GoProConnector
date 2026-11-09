import Foundation

/// Camera address. In access point mode the HERO8 answers on 10.5.5.9:
/// - port 80   -> commands (gpControl)
/// - port 8080 -> media server (list, thumbnails, downloads)
struct GoProEndpoint: Equatable, Sendable {
    var host: String = "10.5.5.9"
    var controlPort: Int = 80
    var mediaPort: Int = 8080

    var controlBase: URL { URL(string: "http://\(host):\(controlPort)")! }
    var mediaBase: URL { URL(string: "http://\(host):\(mediaPort)")! }

    static func fromDefaults() -> GoProEndpoint {
        let d = UserDefaults.standard
        var e = GoProEndpoint()
        if let h = d.string(forKey: SettingsKeys.host), !h.isEmpty { e.host = h }
        if d.object(forKey: SettingsKeys.controlPort) != nil { e.controlPort = d.integer(forKey: SettingsKeys.controlPort) }
        if d.object(forKey: SettingsKeys.mediaPort) != nil { e.mediaPort = d.integer(forKey: SettingsKeys.mediaPort) }
        return e
    }
}

struct CameraInfo: Sendable {
    var modelName: String
    var firmware: String
    var serial: String
    var ssid: String
}

struct CameraStatus: Sendable {
    var batteryPercent: Int?
    var freeSpaceBytes: Int64?
    var sdCardOK: Bool
}

enum GoProError: LocalizedError {
    case badResponse(Int)
    case invalidData
    case notReachable(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return String(localized: "The camera answered with HTTP status \(code).")
        case .invalidData: return String(localized: "Invalid response from the camera.")
        case .notReachable(let msg): return String(localized: "Camera not reachable: \(msg)")
        }
    }
}

final class GoProClient: Sendable {
    let endpoint: GoProEndpoint
    private let session: URLSession

    init(endpoint: GoProEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL

    func mediaURL(_ directory: String, _ name: String) -> URL {
        endpoint.mediaBase.appendingPathComponent("videos/DCIM/\(directory)/\(name)")
    }

    func downloadURL(for item: MediaItem, fileName: String? = nil) -> URL {
        mediaURL(item.directory, fileName ?? item.fileName)
    }

    func thumbnailURL(for item: MediaItem) -> URL {
        metadataURL(path: item.path, type: nil)
    }

    func screennailURL(for item: MediaItem) -> URL {
        metadataURL(path: item.path, type: "screennail")
    }

    func lrvURL(for item: MediaItem) -> URL? {
        guard let lrv = item.lrvFileName else { return nil }
        return mediaURL(item.directory, lrv)
    }

    private func metadataURL(path: String, type: String?) -> URL {
        var c = URLComponents(url: endpoint.mediaBase.appendingPathComponent("gp/gpMediaMetadata"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "p", value: path)]
        if let type { c.queryItems?.append(URLQueryItem(name: "t", value: type)) }
        return c.url!
    }

    private func controlURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: endpoint.controlBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    // MARK: - Requests

    private func getJSON(_ url: URL, timeout: TimeInterval = 8) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoProError.badResponse(http.statusCode)
        }
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoProError.invalidData
        }
        return obj
    }

    func info() async throws -> CameraInfo {
        let json = try await getJSON(controlURL("gp/gpControl/info"), timeout: 4)
        let info = json["info"] as? [String: Any] ?? [:]
        return CameraInfo(
            modelName: info["model_name"] as? String ?? "GoPro",
            firmware: info["firmware_version"] as? String ?? "",
            serial: info["serial_number"] as? String ?? "",
            ssid: info["ap_ssid"] as? String ?? ""
        )
    }

    func status() async throws -> CameraStatus {
        let json = try await getJSON(controlURL("gp/gpControl/status"), timeout: 4)
        let status = json["status"] as? [String: Any] ?? [:]
        // 70 = internal battery %, 54 = free SD space in KB, 33 = SD status (0 = ok)
        return CameraStatus(
            batteryPercent: status.int("70"),
            freeSpaceBytes: status.int("54").map { Int64($0) * 1024 },
            sdCardOK: (status.int("33") ?? 0) == 0
        )
    }

    func mediaList() async throws -> [MediaItem] {
        let json = try await getJSON(endpoint.mediaBase.appendingPathComponent("gp/gpMediaList"), timeout: 30)
        let dirs = json["media"] as? [[String: Any]] ?? []
        var items: [MediaItem] = []
        for dir in dirs {
            guard let d = dir["d"] as? String, let fs = dir["fs"] as? [[String: Any]] else { continue }
            items.append(contentsOf: fs.compactMap { MediaItem(directory: d, json: $0) })
        }
        return items
    }

    func delete(_ item: MediaItem) async throws {
        let path = item.isGroup ? "gp/gpControl/command/storage/delete/group" : "gp/gpControl/command/storage/delete"
        _ = try await getJSON(controlURL(path, query: [URLQueryItem(name: "p", value: item.path)]), timeout: 15)
    }

    func fetchData(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoProError.badResponse(http.statusCode)
        }
        return data
    }
}

enum SettingsKeys {
    static let host = "host"
    static let controlPort = "controlPort"
    static let mediaPort = "mediaPort"
    static let destination = "destinationPath"
    static let organizeByDate = "organizeByDate"
    static let downloadLRV = "downloadLRV"
    static let confirmDelete = "confirmDelete"
    static let tileSize = "tileSize"
    static let viewMode = "viewMode"
    static let groupByDay = "groupByDay"
    static let wifiSSID = "wifiSSID"
    static let previewHighQuality = "previewHighQuality"

    static var defaultDestination: String {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appendingPathComponent("GoPro").path
    }
}
