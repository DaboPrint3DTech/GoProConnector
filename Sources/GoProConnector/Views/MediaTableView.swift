import SwiftUI

struct MediaTableView: View {
    @Environment(LibraryViewModel.self) private var model
    let items: [MediaItem]
    let onDelete: ([MediaItem]) -> Void

    var body: some View {
        @Bindable var model = model
        Table(items, selection: $model.selection) {
            TableColumn("") { item in
                ThumbnailView(item: item)
                    .frame(width: 64, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(70)

            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    Text(item.fileName)
                    if model.history.contains(item) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Already downloaded")
                    }
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Type") { item in
                Label(item.isGroup ? "\(item.kind.label) (\(item.fileCount))" : item.kind.label,
                      systemImage: item.kind.systemImage)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Date") { item in
                Text(Formatters.cameraDate.string(from: item.created)).monospacedDigit()
            }
            .width(min: 120, ideal: 150)

            TableColumn("Size") { item in
                Text(Formatters.bytes.string(fromByteCount: item.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Folder") { item in
                Text(item.directory).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                MediaContextMenu(item: item, onDelete: onDelete)
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                model.previewItem = item
            }
        }
        .onKeyPress(.space) {
            if let first = model.selectedItems.first { model.previewItem = first }
            return .handled
        }
    }
}
