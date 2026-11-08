import Foundation

/// Tipo di media sulla GoPro.
enum MediaKind: String, CaseIterable, Identifiable, Codable {
    case video
    case photo
    case burst
    case timelapse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Foto"
        case .burst: return "Burst"
        case .timelapse: return "Time Lapse"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "video"
        case .photo: return "photo"
        case .burst: return "square.stack.3d.up"
        case .timelapse: return "timelapse"
        }
    }
}

/// Un elemento della lista media della camera (un file singolo oppure un gruppo burst/timelapse).
struct MediaItem: Identifiable, Hashable, Sendable {
    let directory: String          // es. "100GOPRO"
    let fileName: String           // es. "GH010042.MP4"
    let created: Date              // orario "da parete" della camera, da leggere in UTC
    let size: Int64                // byte (per i gruppi: totale dichiarato dalla camera)
    let groupType: String?         // "b" burst, "t" timelapse, "n" nightlapse, "c" continuous
    let groupID: Int?
    let groupFirst: Int?
    let groupLast: Int?
    let groupMissing: [Int]
    let hasLRV: Bool

    var id: String { "\(directory)/\(fileName)" }
    var path: String { id }

    var fileExtension: String { (fileName as NSString).pathExtension.uppercased() }

    var isGroup: Bool { groupType != nil && groupFirst != nil && groupLast != nil }

    var isVideo: Bool { fileExtension == "MP4" || fileExtension == "MOV" }

    var kind: MediaKind {
        if isVideo { return .video }
        switch groupType {
        case "b"?: return .burst
        case "t"?, "n"?, "c"?: return .timelapse
        default: return .photo
        }
    }

    /// Numero di file effettivi (per i gruppi).
    var fileCount: Int {
        guard isGroup, let first = groupFirst, let last = groupLast else { return 1 }
        return max(0, last - first + 1 - groupMissing.count)
    }

    /// Capitolo del video (GH01xxxx -> 1, GH02xxxx -> 2). nil se non applicabile.
    var chapter: Int? {
        guard isVideo, fileName.count >= 8 else { return nil }
        let chars = Array(fileName)
        guard chars[0] == "G", chars[1] != "O" else { return nil }
        return Int(String(chars[2...3]))
    }

    /// Numero del video condiviso dai capitoli (GH01**0042** -> 42).
    var videoNumber: Int? {
        guard isVideo, fileName.count >= 8 else { return nil }
        let chars = Array(fileName)
        if fileName.hasPrefix("GOPR") { return Int(String(chars[4...7])) }
        return Int(String(chars[4...7]))
    }

    /// Nome del file LRV (video a bassa risoluzione usato per l'anteprima).
    var lrvFileName: String? {
        guard isVideo else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        if base.hasPrefix("GOPR") { return base + ".LRV" }
        // GH010042 / GX010042 -> GL010042
        guard base.count == 8 else { return nil }
        return "GL" + base.dropFirst(2) + ".LRV"
    }

    /// Tutti i nomi file reali che compongono l'elemento.
    var allFileNames: [String] {
        guard isGroup, let gid = groupID, let first = groupFirst, let last = groupLast else {
            return [fileName]
        }
        let missing = Set(groupMissing)
        let ext = (fileName as NSString).pathExtension
        return (first...last).filter { !missing.contains($0) }.map {
            String(format: "G%03d%04d.%@", gid, $0, ext)
        }
    }

    /// Chiave usata per ricordare i file già scaricati.
    var historyKey: String { "\(fileName)|\(size)|\(Int(created.timeIntervalSince1970))" }
}

extension MediaItem {
    /// Crea un elemento a partire da un oggetto "fs" della risposta gpMediaList.
    init?(directory: String, json: [String: Any]) {
        guard let name = json["n"] as? String else { return nil }
        self.directory = directory
        self.fileName = name
        self.created = Date(timeIntervalSince1970: TimeInterval(json.int("cre") ?? json.int("mod") ?? 0))
        self.size = Int64(json.int("s") ?? 0)
        self.groupType = json["t"] as? String
        self.groupID = json.int("g")
        self.groupFirst = json.int("b")
        self.groupLast = json.int("l")
        if let m = json["m"] as? [Any] {
            self.groupMissing = m.compactMap { ($0 as? Int) ?? Int("\($0)") }
        } else {
            self.groupMissing = []
        }
        self.hasLRV = json["glrv"] != nil
    }
}

extension Dictionary where Key == String, Value == Any {
    /// La camera restituisce numeri a volte come stringhe, a volte come interi.
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? String { return Int(v) }
        if let v = self[key] as? Double { return Int(v) }
        return nil
    }
}

enum Formatters {
    /// I timestamp GoPro rappresentano l'ora locale della camera codificata come se fosse UTC.
    static let cameraDate: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let cameraDay: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    static let folderDay: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static var utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "it_IT")
        f.calendar = cal
        return f
    }()

    /// Tempo rimanente leggibile, arrotondato per non "ballare" a ogni aggiornamento.
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        if seconds < 10 { return "pochi secondi" }
        let step: Double = seconds < 60 ? 5 : seconds < 600 ? 10 : 60
        let rounded = (seconds / step).rounded() * step
        return durationFormatter.string(from: rounded) ?? "\(Int(rounded)) s"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
