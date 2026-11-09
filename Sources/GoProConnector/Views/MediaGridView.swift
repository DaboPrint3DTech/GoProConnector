import SwiftUI

struct MediaGridView: View {
    @Environment(LibraryViewModel.self) private var model
    @AppStorage(SettingsKeys.groupByDay) private var groupByDay = true
    let items: [MediaItem]
    let tileSize: Double
    let onDelete: ([MediaItem]) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 12)]
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                if groupByDay && (model.sortOrder == .dateDesc || model.sortOrder == .dateAsc) {
                    ForEach(model.sections(for: items)) { section in
                        Section {
                            tiles(section.items)
                        } header: {
                            SectionHeader(section: section)
                        }
                    }
                } else {
                    tiles(items)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        .onKeyPress(.space) {
            if let first = model.selectedItems.first { model.previewItem = first }
            return .handled
        }
        .onKeyPress(.return) {
            if let first = model.selectedItems.first { model.previewItem = first }
            return .handled
        }
        .onKeyPress(.escape) {
            model.deselectAll()
            return .handled
        }
    }

    private func tiles(_ list: [MediaItem]) -> some View {
        ForEach(list) { item in
            MediaTile(item: item, size: tileSize,
                      selected: model.selection.contains(item.id),
                      downloaded: model.history.contains(item))
                .onTapGesture(count: 2) { model.previewItem = item }
                .simultaneousGesture(TapGesture().onEnded {
                    model.click(item, in: items, modifiers: NSEvent.modifierFlags)
                    focused = true
                })
                .contextMenu { MediaContextMenu(item: item, onDelete: onDelete) }
        }
    }
}

struct SectionHeader: View {
    @Environment(LibraryViewModel.self) private var model
    let section: DaySection

    var body: some View {
        HStack {
            Text(Formatters.cameraDay.string(from: section.day)).font(.headline)
            Text("\(section.items.count) items").foregroundStyle(.secondary)
            Spacer()
            Button("Select Day") {
                model.selection.formUnion(section.items.map(\.id))
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
    }
}

struct MediaTile: View {
    let item: MediaItem
    let size: Double
    let selected: Bool
    let downloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                ThumbnailView(item: item)
                    .frame(height: size * 0.5625)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 4) {
                    Image(systemName: item.kind.systemImage)
                    if item.isGroup { Text("\(item.fileCount)") }
                    if let ch = item.chapter, ch > 1 { Text("ch. \(ch)") }
                }
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(5)
            }
            .overlay(alignment: .topTrailing) {
                if downloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 16))
                        .padding(5)
                        .help("Already downloaded")
                }
            }

            if size >= 120 {
                Text(item.fileName).font(.caption.weight(.medium)).lineLimit(1)
                Text("\(Formatters.cameraDate.string(from: item.created)) · \(Formatters.bytes.string(fromByteCount: item.size))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

struct ThumbnailView: View {
    @Environment(LibraryViewModel.self) private var model
    let item: MediaItem
    var kind: String = "thumb"
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: item.kind.systemImage)
                    .font(.title)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: item.id) {
            guard let client = model.client else { return }
            let url = kind == "screennail" ? client.screennailURL(for: item) : client.thumbnailURL(for: item)
            image = await ThumbnailLoader.shared.image(for: item, url: url, client: client, kind: kind)
            failed = image == nil
        }
    }
}

struct MediaContextMenu: View {
    @Environment(LibraryViewModel.self) private var model
    let item: MediaItem
    let onDelete: ([MediaItem]) -> Void

    /// If the clicked item is part of the selection, act on the whole selection.
    private var targets: [MediaItem] {
        model.selection.contains(item.id) ? model.selectedItems : [item]
    }

    var body: some View {
        let t = targets
        let suffix = t.count > 1 ? " (\(t.count))" : ""
        Button("Preview") { model.previewItem = item }
        Divider()
        Button("Download to Mac\(suffix)") { model.copy(t) }
        Button("Download to…\(suffix)") { if let url = model.chooseFolder() { model.copy(t, to: url) } }
        Button("Move to Mac\(suffix)") { model.move(t) }
        Button("Move to…\(suffix)") { if let url = model.chooseFolder() { model.move(t, to: url) } }
        Divider()
        if model.history.contains(item) {
            Button("Show in Finder") { model.revealInFinder(item) }
        }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t.map(\.fileName).joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Delete from GoPro\(suffix)", role: .destructive) { onDelete(t) }
    }
}
