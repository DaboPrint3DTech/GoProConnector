import AppKit
import Observation
import SystemConfiguration

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum SortOrder: String, CaseIterable, Identifiable {
    case dateDesc, dateAsc, nameAsc, sizeDesc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dateDesc: return "Più recenti"
        case .dateAsc: return "Meno recenti"
        case .nameAsc: return "Nome"
        case .sizeDesc: return "Dimensione"
        }
    }
}

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, notDownloaded, downloaded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Tutti"
        case .notDownloaded: return "Da scaricare"
        case .downloaded: return "Già scaricati"
        }
    }
}

struct DaySection: Identifiable {
    let day: Date
    let items: [MediaItem]
    var id: Date { day }
}

@MainActor
@Observable
final class LibraryViewModel {
    // Connessione
    private(set) var state: ConnectionState = .disconnected
    private(set) var client: GoProClient?
    private(set) var info: CameraInfo?
    private(set) var status: CameraStatus?
    private(set) var isLoadingList = false

    // Media
    private(set) var items: [MediaItem] = []
    var selection: Set<MediaItem.ID> = []
    var anchorID: MediaItem.ID?

    // Filtri
    var searchText = ""
    var kindFilter: MediaKind? = nil
    var downloadFilter: DownloadFilter = .all
    var sortOrder: SortOrder = .dateDesc
    var dayFilter: Date? = nil

    // UI
    var previewItem: MediaItem?
    var errorMessage: String?

    let history: DownloadHistory
    let transfers: TransferManager
    let bluetooth = GoProBluetooth()
    private(set) var linkStatus = ""
    private(set) var isLinking = false
    private var pollTask: Task<Void, Never>?

    init() {
        let history = DownloadHistory()
        self.history = history
        self.transfers = TransferManager(history: history)
        transfers.clientProvider = { [weak self] in self?.client }
        transfers.onDeletedFromCamera = { [weak self] item in self?.removeLocally([item]) }
    }

    // MARK: - Connessione

    func connect() async {
        state = .connecting
        let c = GoProClient(endpoint: .fromDefaults())
        do {
            let info = try await c.info()
            self.client = c
            self.info = info
            self.state = .connected
            AppLog.write("[HTTP] connesso a \(info.modelName) (\(c.endpoint.host))")
            self.status = try? await c.status()
            startPolling()
            await refresh()
        } catch {
            self.client = nil
            self.state = .failed(Self.networkHint(for: c.endpoint.host) ?? Self.describe(error))
            AppLog.write("[HTTP] connessione fallita: \(error.localizedDescription)")
        }
    }

    /// Come Quik: accende il WiFi della camera via Bluetooth, collega il Mac alla sua rete e si connette.
    func connectViaBluetooth() async {
        guard !isLinking else { return }
        isLinking = true
        defer { isLinking = false }
        state = .connecting
        linkStatus = ""
        let host = GoProEndpoint.fromDefaults().host
        do {
            let creds = try await bluetooth.activateWiFi()
            UserDefaults.standard.set(creds.ssid, forKey: SettingsKeys.wifiSSID)
            Keychain.setPassword(creds.password, for: creds.ssid)

            if Self.networkHint(for: host) != nil {
                linkStatus = "Collegamento del Mac alla rete \(creds.ssid)…"
                AppLog.write("[WiFi] \(linkStatus)")
                var lastError: Error?
                for attempt in 1...6 {
                    do {
                        try await WiFiJoiner.join(ssid: creds.ssid, password: creds.password)
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        AppLog.write("[WiFi] tentativo \(attempt) fallito: \(error.localizedDescription)")
                        linkStatus = "La rete \(creds.ssid) non è ancora visibile, nuovo tentativo (\(attempt)/6)…"
                        try? await Task.sleep(for: .seconds(4))
                    }
                }
                if let lastError {
                    throw NSError(domain: "WiFi", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "WiFi della camera acceso, ma il Mac non riesce a collegarsi a \(creds.ssid): \(lastError.localizedDescription). Prova a selezionarla dal menu WiFi."])
                }
                linkStatus = "In attesa dell'indirizzo IP dalla camera…"
                for _ in 0..<20 where Self.networkHint(for: host) != nil {
                    try? await Task.sleep(for: .milliseconds(750))
                }
            }

            linkStatus = "Connessione alla camera…"
            for attempt in 1...4 {
                await connect()
                if state == .connected { linkStatus = ""; return }
                AppLog.write("[HTTP] tentativo \(attempt) non riuscito")
                state = .connecting
                try? await Task.sleep(for: .seconds(2))
            }
            await connect()
        } catch {
            state = .failed(error.localizedDescription)
            AppLog.write("[LINK] \(error.localizedDescription)")
        }
        linkStatus = ""
    }

    /// Se la camera è sulla sua rete standard (10.5.5.x) ma il Mac non ha un indirizzo in quella rete,
    /// il problema è quasi certamente il WiFi: lo diciamo esplicitamente.
    static func networkHint(for host: String) -> String? {
        guard host.hasPrefix("10.5.5.") else { return nil }
        let addresses = localIPv4Addresses()
        if addresses.contains(where: { $0.hasPrefix("10.5.5.") }) { return nil }
        let current = addresses.first { !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.") }
        return "Il Mac non è collegato alla rete WiFi della GoPro"
            + (current.map { " (indirizzo attuale \($0), è un'altra rete)" } ?? "")
            + ". Attiva il WiFi sulla camera e seleziona la sua rete (GP…) dal menu WiFi del Mac."
    }

    private static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    /// Nome della connessione (es. "Ethernet") che resta disponibile per Internet oltre alla rete della GoPro.
    static func otherConnectionName() -> String? {
        var bsdNames: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let addr = String(cString: host)
            if addr.hasPrefix("10.5.5.") || addr.hasPrefix("127.") || addr.hasPrefix("169.254.") { continue }
            bsdNames.append(String(cString: ptr.pointee.ifa_name))
        }
        guard let bsd = bsdNames.first else { return nil }
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        let match = all.first { (SCNetworkInterfaceGetBSDName($0) as String?) == bsd }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? bsd
    }

    /// Se il Mac è già sulla rete della GoPro si connette direttamente, altrimenti passa dal Bluetooth.
    func smartConnect() async {
        if Self.networkHint(for: GoProEndpoint.fromDefaults().host) == nil {
            await connect()
        } else {
            await connectViaBluetooth()
        }
    }

    /// Disconnette e spegne il WiFi della camera, così il Mac torna sulla rete di casa (e su Internet).
    func disconnectAndRestoreNetwork() async {
        disconnect()
        await bluetooth.turnOffWiFi()
        bluetooth.disconnect()
        linkStatus = ""
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        transfers.cancelAll()
        client = nil
        info = nil
        status = nil
        items = []
        selection = []
        state = .disconnected
    }

    func refresh() async {
        guard let client else { return }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let list = try await client.mediaList()
            AppLog.write("[HTTP] lista file: \(list.count) elementi")
            items = list
            selection = selection.intersection(Set(list.map(\.id)))
            if let day = dayFilter, !availableDays.contains(day) { dayFilter = nil }
        } catch {
            errorMessage = "Impossibile leggere la lista dei file: \(Self.describe(error))"
        }
    }

    /// Interroga periodicamente lo stato: mantiene vivo il WiFi della camera e rileva le disconnessioni.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let client = self.client else { return }
                do {
                    self.status = try await client.status()
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= 3 && !self.transfers.isActive {
                        self.pollTask = nil
                        self.client = nil
                        self.state = .failed("Connessione con la camera persa. Verifica che il WiFi della GoPro sia attivo.")
                        return
                    }
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return "tempo scaduto. Il Mac è collegato al WiFi della GoPro?"
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost:
                return "camera non raggiungibile. Collega il Mac alla rete WiFi della GoPro."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Filtri

    var filteredItems: [MediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var result = items.filter { item in
            if let k = kindFilter, item.kind != k { return false }
            switch downloadFilter {
            case .all: break
            case .downloaded: if !history.contains(item) { return false }
            case .notDownloaded: if history.contains(item) { return false }
            }
            if let day = dayFilter, Formatters.utcCalendar.startOfDay(for: item.created) != day { return false }
            if !query.isEmpty {
                let haystack = [item.fileName, item.directory, item.kind.label,
                                Formatters.cameraDate.string(from: item.created),
                                Formatters.folderDay.string(from: item.created)]
                    .joined(separator: " ").lowercased()
                if !query.split(separator: " ").allSatisfy({ haystack.contains($0) }) { return false }
            }
            return true
        }
        switch sortOrder {
        case .dateDesc: result.sort { ($0.created, $0.fileName) > ($1.created, $1.fileName) }
        case .dateAsc: result.sort { ($0.created, $0.fileName) < ($1.created, $1.fileName) }
        case .nameAsc: result.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .sizeDesc: result.sort { $0.size > $1.size }
        }
        return result
    }

    func sections(for list: [MediaItem]) -> [DaySection] {
        var order: [Date] = []
        var buckets: [Date: [MediaItem]] = [:]
        for item in list {
            let day = Formatters.utcCalendar.startOfDay(for: item.created)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { DaySection(day: $0, items: buckets[$0]!) }
    }

    var availableDays: [Date] {
        Array(Set(items.map { Formatters.utcCalendar.startOfDay(for: $0.created) })).sorted(by: >)
    }

    func count(of kind: MediaKind?) -> Int {
        guard let kind else { return items.count }
        return items.filter { $0.kind == kind }.count
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    // MARK: - Selezione

    var selectedItems: [MediaItem] {
        filteredItems.filter { selection.contains($0.id) }
    }

    func click(_ item: MediaItem, in list: [MediaItem], modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor = anchorID,
           let a = list.firstIndex(where: { $0.id == anchor }),
           let b = list.firstIndex(where: { $0.id == item.id }) {
            let range = list[min(a, b)...max(a, b)].map(\.id)
            if modifiers.contains(.command) {
                selection.formUnion(range)
            } else {
                selection = Set(range)
            }
        } else if modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        } else {
            selection = [item.id]
            anchorID = item.id
        }
    }

    func selectAll() { selection = Set(filteredItems.map(\.id)) }
    func deselectAll() { selection = [] }

    // MARK: - Azioni

    var destinationURL: URL {
        let path = UserDefaults.standard.string(forKey: SettingsKeys.destination) ?? SettingsKeys.defaultDestination
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Copia (scarica) i file sul Mac.
    func copy(_ items: [MediaItem], to folder: URL? = nil) {
        guard !items.isEmpty else { return }
        transfers.enqueue(items, to: folder ?? destinationURL, deleteAfter: false)
    }

    /// Sposta: scarica, verifica e poi cancella dalla camera.
    func move(_ items: [MediaItem], to folder: URL? = nil) {
        guard !items.isEmpty else { return }
        transfers.enqueue(items, to: folder ?? destinationURL, deleteAfter: true)
    }

    func delete(_ items: [MediaItem]) async {
        guard let client else { return }
        var deleted: [MediaItem] = []
        for item in items {
            do {
                try await client.delete(item)
                deleted.append(item)
            } catch {
                errorMessage = "Errore cancellando \(item.fileName): \(Self.describe(error))"
                break
            }
        }
        removeLocally(deleted)
        status = try? await client.status()
    }

    private func removeLocally(_ removed: [MediaItem]) {
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let p = previewItem, ids.contains(p.id) { previewItem = nil }
    }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        panel.directoryURL = destinationURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    func revealInFinder(_ item: MediaItem) {
        if let job = transfers.jobs.last(where: { $0.item.id == item.id && !$0.savedURLs.isEmpty }) {
            NSWorkspace.shared.activateFileViewerSelecting(job.savedURLs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        }
    }
}
