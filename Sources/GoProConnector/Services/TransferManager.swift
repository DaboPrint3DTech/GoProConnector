import Foundation
import Observation

/// Ricorda quali file sono già stati scaricati (persistente su disco).
@MainActor
@Observable
final class DownloadHistory {
    private(set) var keys: Set<String> = []
    private let file: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GoProConnector", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("downloaded.json")
        if let data = try? Data(contentsOf: file), let arr = try? JSONDecoder().decode([String].self, from: data) {
            keys = Set(arr)
        }
    }

    func contains(_ item: MediaItem) -> Bool { keys.contains(item.historyKey) }

    func mark(_ item: MediaItem) {
        keys.insert(item.historyKey)
        save()
    }

    func clear() {
        keys.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(keys)) { try? data.write(to: file, options: .atomic) }
    }
}

enum TransferState: Equatable {
    case queued
    case running
    case done
    case skipped
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .queued, .running: return false
        default: return true
        }
    }
}

struct TransferJob: Identifiable {
    let id = UUID()
    let item: MediaItem
    let destinationRoot: URL
    let deleteAfter: Bool
    var state: TransferState = .queued
    var bytesDone: Int64 = 0
    var bytesTotal: Int64
    var currentFile: Int = 0
    var fileCount: Int
    var savedURLs: [URL] = []

    var fraction: Double {
        guard bytesTotal > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

@MainActor
@Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    /// Velocità media sugli ultimi secondi (aggiornata ogni secondo, anche se il trasferimento si blocca).
    private(set) var bytesPerSecond: Double = 0
    /// Secondi stimati per finire tutta la coda; nil se non c'è ancora una stima.
    private(set) var etaSeconds: Double?
    /// true quando la stima usa la velocità dei download precedenti (la misura non è ancora pronta).
    private(set) var etaIsRough = false
    var lastError: String?

    /// Chiamato quando un elemento è stato cancellato dalla camera dopo uno "sposta".
    var onDeletedFromCamera: ((MediaItem) -> Void)?

    let history: DownloadHistory
    private let downloader = Downloader()
    private var worker: Task<Void, Never>?
    var clientProvider: () -> GoProClient? = { nil }

    // Misura della velocità
    private static let speedWindow: TimeInterval = 8
    private static let typicalSpeedKey = "typicalDownloadSpeed"
    private var transferredTotal: Int64 = 0
    private var samples: [(time: Date, bytes: Int64)] = []
    private var hasMeasurement = false
    private var ticker: Task<Void, Never>?
    private var runStart: (time: Date, bytes: Int64)?

    init(history: DownloadHistory) {
        self.history = history
    }

    var isActive: Bool { jobs.contains { !$0.state.isFinished } }

    var pendingCount: Int { jobs.filter { !$0.state.isFinished }.count }

    var overallFraction: Double {
        let active = jobs.filter { $0.state != .cancelled && $0.state != .skipped }
        let total = active.reduce(Int64(0)) { $0 + $1.bytesTotal }
        guard total > 0 else { return 0 }
        let done = active.reduce(Int64(0)) { $0 + ($1.state == .done ? $1.bytesTotal : $1.bytesDone) }
        return Double(done) / Double(total)
    }

    var remainingBytes: Int64 {
        jobs.filter { !$0.state.isFinished }.reduce(Int64(0)) { $0 + max(0, $1.bytesTotal - $1.bytesDone) }
    }

    /// Es. "mancano circa 3 min 20 s · fine verso le 15:42".
    var etaLine: String {
        guard let eta = etaSeconds else {
            return hasMeasurement ? "In attesa di dati dalla camera…" : "Calcolo del tempo rimanente…"
        }
        let finish = Formatters.clock.string(from: Date().addingTimeInterval(eta))
        return "\(etaIsRough ? "circa " : "")\(Formatters.eta(eta)) rimanenti · fine verso le \(finish)"
    }

    /// Riga compatta per la barra di stato.
    var summaryLine: String {
        var parts: [String] = []
        if bytesPerSecond > 0 { parts.append("\(Formatters.bytes.string(fromByteCount: Int64(bytesPerSecond)))/s") }
        parts.append("restano \(Formatters.bytes.string(fromByteCount: remainingBytes))")
        if let eta = etaSeconds {
            parts.append("\(etaIsRough ? "≈ " : "")\(Formatters.eta(eta))")
        } else {
            parts.append("stima in corso…")
        }
        return "Download: " + parts.joined(separator: " · ")
    }

    /// Tempo stimato per finire un singolo elemento in corso.
    func eta(for job: TransferJob) -> Double? {
        guard job.state == .running, hasMeasurement, bytesPerSecond > 1024 else { return nil }
        return Double(max(0, job.bytesTotal - job.bytesDone)) / bytesPerSecond
    }

    func enqueue(_ items: [MediaItem], to root: URL, deleteAfter: Bool) {
        let queuedIDs = Set(jobs.filter { !$0.state.isFinished }.map(\.item.id))
        for item in items where !queuedIDs.contains(item.id) {
            let names = fileNames(for: item)
            jobs.append(TransferJob(item: item, destinationRoot: root, deleteAfter: deleteAfter,
                                    bytesTotal: item.size, fileCount: names.count))
        }
        startIfNeeded()
        updateETA()
    }

    func cancel(_ job: TransferJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if jobs[i].state == .running {
            worker?.cancel()
            downloader.cancelAll()
        }
        if !jobs[i].state.isFinished { jobs[i].state = .cancelled }
    }

    func cancelAll() {
        for i in jobs.indices where !jobs[i].state.isFinished { jobs[i].state = .cancelled }
        worker?.cancel()
        downloader.cancelAll()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    func retryFailed() {
        for i in jobs.indices {
            if case .failed = jobs[i].state { jobs[i].state = .queued; jobs[i].bytesDone = 0 }
            if jobs[i].state == .cancelled { jobs[i].state = .queued; jobs[i].bytesDone = 0 }
        }
        startIfNeeded()
    }

    // MARK: - Esecuzione

    private func fileNames(for item: MediaItem) -> [String] {
        var names = item.allFileNames
        if UserDefaults.standard.bool(forKey: SettingsKeys.downloadLRV), item.hasLRV || item.isVideo,
           let lrv = item.lrvFileName {
            names.append(lrv)
        }
        return names
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        startTicker()
        worker = Task { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - Velocità e tempo stimato

    private func startTicker() {
        guard ticker == nil else { return }
        samples = []
        hasMeasurement = false
        runStart = (Date(), transferredTotal)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        // Ricorda la velocità media: servirà per stimare subito il prossimo download.
        if let start = runStart {
            let bytes = transferredTotal - start.bytes
            let elapsed = Date().timeIntervalSince(start.time)
            if bytes > 20_000_000, elapsed > 3 {
                UserDefaults.standard.set(Double(bytes) / elapsed, forKey: Self.typicalSpeedKey)
            }
        }
        runStart = nil
        samples = []
        hasMeasurement = false
        bytesPerSecond = 0
        etaSeconds = nil
        etaIsRough = false
    }

    private func tick() {
        let now = Date()
        samples.append((now, transferredTotal))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.speedWindow }
        if let first = samples.first, now.timeIntervalSince(first.time) >= 2 {
            bytesPerSecond = Double(transferredTotal - first.bytes) / now.timeIntervalSince(first.time)
            hasMeasurement = true
        }
        updateETA()
    }

    private func updateETA() {
        let remaining = remainingBytes
        guard isActive, remaining > 0 else { etaSeconds = nil; return }
        if hasMeasurement {
            etaIsRough = false
            etaSeconds = bytesPerSecond > 1024 ? Double(remaining) / bytesPerSecond : nil
        } else {
            let typical = UserDefaults.standard.double(forKey: Self.typicalSpeedKey)
            etaIsRough = typical > 0
            etaSeconds = typical > 0 ? Double(remaining) / typical : nil
        }
    }

    private func runLoop() async {
        while let index = jobs.firstIndex(where: { $0.state == .queued }) {
            let jobID = jobs[index].id
            jobs[index].state = .running
            do {
                try await process(jobID: jobID)
            } catch is CancellationError {
                setState(jobID, .cancelled)
            } catch let e as URLError where e.code == .cancelled {
                setState(jobID, .cancelled)
            } catch {
                setState(jobID, .failed(error.localizedDescription))
                lastError = error.localizedDescription
            }
            if Task.isCancelled {
                // l'annullamento ha interrotto il job corrente: si riparte con i successivi
                worker = nil
                startIfNeeded()
                return
            }
            updateETA()
        }
        stopTicker()
        worker = nil
    }

    private func setState(_ id: UUID, _ state: TransferState) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        // non sovrascrivere un annullamento esplicito
        if jobs[i].state == .cancelled && state != .cancelled { return }
        jobs[i].state = state
    }

    private func process(jobID: UUID) async throws {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard let client = clientProvider() else { throw GoProError.notReachable("nessuna camera connessa") }
        let item = job.item
        let fm = FileManager.default

        var folder = job.destinationRoot
        if UserDefaults.standard.bool(forKey: SettingsKeys.organizeByDate) {
            folder.appendPathComponent(Formatters.folderDay.string(from: item.created), isDirectory: true)
        }
        if item.isGroup {
            let base = (item.fileName as NSString).deletingPathExtension
            folder.appendPathComponent("\(item.kind.label.replacingOccurrences(of: " ", with: ""))_\(base)", isDirectory: true)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let names = fileNames(for: item)
        var completedBytes: Int64 = 0
        var allSkipped = true
        var saved: [URL] = []

        for (n, name) in names.enumerated() {
            try Task.checkCancellation()
            update(jobID) { $0.currentFile = n + 1 }

            let isMainSingleFile = !item.isGroup && name == item.fileName
            var target = folder.appendingPathComponent(name)

            if fm.fileExists(atPath: target.path) {
                let existingSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1
                let sameFile = isMainSingleFile ? existingSize == item.size : existingSize > 0
                if sameFile {
                    completedBytes += isMainSingleFile ? item.size : 0
                    saved.append(target)
                    continue
                }
                target = uniqueURL(for: target)
            }
            allSkipped = false

            let partial = target.appendingPathExtension("part")
            let baseBytes = completedBytes
            let url = client.downloadURL(for: item, fileName: name)
            try await downloader.download(url, to: partial) { [weak self] written, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.update(jobID) { job in
                        let newValue = baseBytes + written
                        self.recordSpeed(newValue - job.bytesDone)
                        job.bytesDone = max(job.bytesDone, newValue)
                    }
                }
            }

            let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
            if isMainSingleFile && item.size > 0 && size != item.size {
                try? fm.removeItem(at: partial)
                throw NSError(domain: "GoProConnector", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Dimensione non corrispondente per \(name) (\(size) invece di \(item.size) byte)"
                ])
            }
            try fm.moveItem(at: partial, to: target)
            applyCameraDate(item.created, to: target)
            saved.append(target)
            completedBytes += size
            update(jobID) { $0.bytesDone = completedBytes; if $0.bytesTotal < completedBytes { $0.bytesTotal = completedBytes } }
        }

        history.mark(item)
        update(jobID) { $0.savedURLs = saved }

        if job.deleteAfter {
            try Task.checkCancellation()
            try await client.delete(item)
            onDeletedFromCamera?(item)
        }
        update(jobID) {
            $0.state = (allSkipped && !job.deleteAfter) ? .skipped : .done
            $0.bytesDone = $0.bytesTotal
        }
    }

    private func update(_ id: UUID, _ change: (inout TransferJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func recordSpeed(_ delta: Int64) {
        transferredTotal += max(0, delta)
    }

    private func uniqueURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(i))").appendingPathExtension(ext)
            i += 1
        }
        return candidate
    }

    /// Imposta data di creazione/modifica del file uguale all'ora della ripresa
    /// (l'ora della camera è "da parete", quindi la riportiamo nel fuso locale).
    private func applyCameraDate(_ date: Date, to url: URL) {
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        let local = date.addingTimeInterval(-offset)
        try? FileManager.default.setAttributes([.creationDate: local, .modificationDate: local], ofItemAtPath: url.path)
    }
}
