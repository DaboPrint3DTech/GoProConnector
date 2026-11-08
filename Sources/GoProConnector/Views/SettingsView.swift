import SwiftUI

struct SettingsView: View {
    @Environment(LibraryViewModel.self) private var model
    @AppStorage(SettingsKeys.host) private var host = "10.5.5.9"
    @AppStorage(SettingsKeys.controlPort) private var controlPort = 80
    @AppStorage(SettingsKeys.mediaPort) private var mediaPort = 8080
    @AppStorage(SettingsKeys.destination) private var destination = SettingsKeys.defaultDestination
    @AppStorage(SettingsKeys.organizeByDate) private var organizeByDate = true
    @AppStorage(SettingsKeys.downloadLRV) private var downloadLRV = false
    @AppStorage(SettingsKeys.confirmDelete) private var confirmDelete = true
    @State private var cacheCleared = false

    var body: some View {
        TabView {
            Form {
                Section("Destination folder") {
                    HStack {
                        Text(destination).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            if let url = model.chooseFolder() { destination = url.path }
                        }
                    }
                    Toggle("Organize into subfolders by day (YYYY-MM-DD)", isOn: $organizeByDate)
                    Toggle("Also download low-resolution proxies (.LRV)", isOn: $downloadLRV)
                }
                Section("Safety") {
                    Toggle("Ask before deleting from the camera", isOn: $confirmDelete)
                    Text("\"Move\" deletes a file from the camera only after checking its size on the Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cache") {
                    HStack {
                        Button("Clear Thumbnail Cache") {
                            ThumbnailLoader.shared.clearCache(); cacheCleared = true
                        }
                        Button("Forget Download History") { model.history.clear() }
                        if cacheCleared { Text("Done").foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    TextField("IP address", text: $host)
                    TextField("Control port", value: $controlPort, format: .number.grouping(.never))
                    TextField("Media port", value: $mediaPort, format: .number.grouping(.never))
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Standard values for GoPro HERO5–HERO8: 10.5.5.9, ports 80 and 8080. Changes apply from the next connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Restore Defaults") {
                    host = "10.5.5.9"; controlPort = 80; mediaPort = 8080
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Connection", systemImage: "wifi") }

            AboutView(iconSize: 84)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 430)
    }
}
