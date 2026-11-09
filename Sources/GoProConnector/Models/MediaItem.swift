import Foundation

/// Kind of media on the GoPro.
enum MediaKind: String, CaseIterable, Identifiable, Codable {
    case video
    case photo
    case burst
    case timelapse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .video: return String(localized: "Video")
        case .photo: return String(localized: "Photo")
        case .burst: return String(localized: "Burst")
        case .timelapse: return String(localized: "Time Lapse")
        }
    }

    /// Untranslated prefix for group subfolders, so folder names stay the same in every language.
    var folderPrefix: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Foto"
        case .burst: return "Burst"
        case .timelapse: return "TimeLapse"
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

/// An item in the camera's media list (a single file or a burst/time-lapse group).
struct MediaItem: Identifiable, Hashable, Sendable {
    let directory: String          // e.g. "100GOPRO"
    let fileName: String           // e.g. "GH010042.MP4"
    let created: Date              // camera "wall clock" time, to be read as UTC
    let size: Int64                // bytes (for groups: total reported by the camera)
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

    /// Actual number of files (for groups).
    var fileCount: Int {
        guard isGroup, let first = groupFirst, let last = groupLast else { return 1 }
        return max(0, last - first + 1 - groupMissing.count)
    }

    /// Video chapter (GH01xxxx -> 1, GH02xxxx -> 2); nil when not applicable.
    var chapter: Int? {
        guard isVideo, fileName.count >= 8 else { return nil }
        let chars = Array(fileName)
        guard chars[0] == "G", chars[1] != "O" else { return nil }
        return Int(String(chars[2...3]))
    }

    /// Video number shared by all chapters (GH01**0042** -> 42).
    var videoNumber: Int? {
        guard isVideo, fileName.count >= 8 else { return nil }
        let chars = Array(fileName)
        if fileName.hasPrefix("GOPR") { return Int(String(chars[4...7])) }
        return Int(String(chars[4...7]))
    }

    /// Name of the LRV file (low-resolution video used for previews).
    var lrvFileName: String? {
        guard isVideo else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        if base.hasPrefix("GOPR") { return base + ".LRV" }
        // GH010042 / GX010042 -> GL010042
        guard base.count == 8 else { return nil }
        return "GL" + base.dropFirst(2) + ".LRV"
    }

    /// All the actual file names that make up the item.
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

    /// Key used to remember files that were already downloaded.
    var historyKey: String { "\(fileName)|\(size)|\(Int(created.timeIntervalSince1970))" }
}

extension MediaItem {
    /// Creates an item from an "fs" object of the gpMediaList response.
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
    /// The camera returns numbers sometimes as strings, sometimes as integers.
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? String { return Int(v) }
        if let v = self[key] as? Double { return Int(v) }
        return nil
    }
}

enum Formatters {
    /// GoPro timestamps are the camera's local time encoded as if it were UTC.
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
        return f
    }()

    /// Readable time left, rounded so that it doesn't jump around on every update.
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        if seconds < 10 { return String(localized: "a few seconds") }
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
