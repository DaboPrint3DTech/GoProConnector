import SwiftUI

struct TransfersView: View {
    @Environment(LibraryViewModel.self) private var model

    var body: some View {
        let t = model.transfers
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Trasferimenti").font(.headline)
                    Spacer()
                    if t.isActive, t.bytesPerSecond > 0 {
                        Text("\(Formatters.bytes.string(fromByteCount: Int64(t.bytesPerSecond)))/s")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if t.isActive {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text(t.etaLine).monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    ProgressView(value: t.overallFraction)
                }
            }
            .padding(12)
            Divider()

            if t.jobs.isEmpty {
                Text("Nessun trasferimento. Seleziona dei file e premi Scarica.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(t.jobs.reversed()) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()
            HStack {
                Button("Apri cartella") { NSWorkspace.shared.open(model.destinationURL) }
                Spacer()
                if t.jobs.contains(where: { if case .failed = $0.state { return true }; return $0.state == .cancelled }) {
                    Button("Riprova") { t.retryFailed() }
                }
                Button("Pulisci") { t.clearFinished() }
                    .disabled(!t.jobs.contains { $0.state.isFinished })
                Button("Annulla tutto") { t.cancelAll() }
                    .disabled(!t.isActive)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 420)
    }
}

private struct JobRow: View {
    @Environment(LibraryViewModel.self) private var model
    let job: TransferJob

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: job.item)
                .frame(width: 54, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.item.fileName).font(.callout.weight(.medium))
                    if job.deleteAfter {
                        Text("sposta").font(.caption2).padding(.horizontal, 4)
                            .background(.orange.opacity(0.2), in: Capsule())
                    }
                }
                switch job.state {
                case .running:
                    ProgressView(value: job.fraction)
                    Text(runningText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                default:
                    Text(stateText).font(.caption).foregroundStyle(stateColor)
                }
            }
            Spacer()
            if !job.state.isFinished {
                Button { model.transfers.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else if !job.savedURLs.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(job.savedURLs) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Mostra nel Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var runningText: String {
        var s = "\(Formatters.bytes.string(fromByteCount: job.bytesDone)) di \(Formatters.bytes.string(fromByteCount: job.bytesTotal))"
        if job.fileCount > 1 { s += " · file \(job.currentFile)/\(job.fileCount)" }
        if let eta = model.transfers.eta(for: job) { s += " · \(Formatters.eta(eta))" }
        return s
    }

    private var stateText: String {
        switch job.state {
        case .queued: return "In coda"
        case .running: return ""
        case .done: return job.deleteAfter ? "Spostato sul Mac" : "Completato"
        case .skipped: return "Già presente, saltato"
        case .failed(let msg): return "Errore: \(msg)"
        case .cancelled: return "Annullato"
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
