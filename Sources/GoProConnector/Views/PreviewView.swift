import SwiftUI
import AVKit

struct PreviewView: View {
    @Environment(LibraryViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.previewHighQuality) private var highQuality = false
    let initial: MediaItem
    let items: [MediaItem]
    @State private var index = 0
    @State private var confirmDelete = false

    private var item: MediaItem { items.indices.contains(index) ? items[index] : initial }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= items.count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName).font(.headline)
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                Spacer()
                if item.isVideo {
                    Toggle("Original quality", isOn: $highQuality)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Plays the original file instead of the low-resolution LRV proxy (needs more bandwidth)")
                }
                Button("Download") { model.copy([item]) }
                Button("Move") { model.move([item]) }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete from GoPro")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            Divider()

            ZStack {
                Color.black
                if item.isVideo {
                    VideoPreview(item: item, highQuality: highQuality)
                        .id("\(item.id)-\(highQuality)")
                } else {
                    PhotoPreview(item: item)
                        .id(item.id)
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 560, idealHeight: 720)
        .onAppear { index = items.firstIndex(of: initial) ?? 0 }
        .confirmationDialog("Delete \(item.fileName) from the GoPro?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let target = item
                Task { await model.delete([target]) }
            }
        }
    }

    private var details: String {
        var parts = [item.kind.label, Formatters.cameraDate.string(from: item.created),
                     Formatters.bytes.string(fromByteCount: item.size)]
        if item.isGroup { parts.append(String(localized: "\(item.fileCount) photos")) }
        if let ch = item.chapter { parts.append(String(localized: "chapter \(ch)")) }
        parts.append(String(localized: "\(index + 1) of \(items.count)"))
        return parts.joined(separator: " · ")
    }

    private func step(_ d: Int) {
        index = min(max(0, index + d), items.count - 1)
    }
}

struct PhotoPreview: View {
    @Environment(LibraryViewModel.self) private var model
    let item: MediaItem
    @State private var full: NSImage?
    @State private var loadingFull = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let full {
                Image(nsImage: full).resizable().aspectRatio(contentMode: .fit)
            } else {
                ThumbnailView(item: item, kind: "screennail")
                    .aspectRatio(contentMode: .fit)
            }
            if loadingFull {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading original image…")
                }
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
        }
        .task(id: item.id) {
            guard let client = model.client else { return }
            loadingFull = true
            let name = item.allFileNames.first ?? item.fileName
            if let data = try? await client.fetchData(client.downloadURL(for: item, fileName: name), timeout: 60) {
                full = NSImage(data: data)
            }
            loadingFull = false
        }
    }
}

struct VideoPreview: View {
    @Environment(LibraryViewModel.self) private var model
    let item: MediaItem
    let highQuality: Bool
    @State private var player: AVPlayer?
    @State private var errorText: String?
    @State private var observation: NSKeyValueObservation?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().controlSize(.large)
            }
            if let errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(errorText).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .onAppear { setup() }
        .onDisappear {
            player?.pause()
            player = nil
            observation = nil
        }
    }

    private func setup() {
        guard let client = model.client else { return }
        let lrv = client.lrvURL(for: item)
        let url = (!highQuality && lrv != nil) ? lrv! : client.downloadURL(for: item)
        // AVFoundation doesn't recognise the .LRV extension, so the MIME type is set explicitly.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let playerItem = AVPlayerItem(asset: asset)
        let isLRV = url == lrv
        observation = playerItem.observe(\AVPlayerItem.status) { obj, _ in
            if obj.status == .failed {
                Task { @MainActor in
                    if isLRV {
                        // fallback: some videos have no LRV proxy
                        let fallback = AVPlayer(url: client.downloadURL(for: item))
                        player = fallback
                        fallback.play()
                    } else {
                        errorText = String(localized: "Can't stream the video.\n\(obj.error?.localizedDescription ?? "")")
                    }
                }
            }
        }
        let p = AVPlayer(playerItem: playerItem)
        player = p
        p.play()
    }
}
