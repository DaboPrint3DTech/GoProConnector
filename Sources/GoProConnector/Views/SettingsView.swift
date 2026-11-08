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
                Section("Cartella di destinazione") {
                    HStack {
                        Text(destination).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Scegli…") {
                            if let url = model.chooseFolder() { destination = url.path }
                        }
                    }
                    Toggle("Organizza in sottocartelle per giorno (AAAA-MM-GG)", isOn: $organizeByDate)
                    Toggle("Scarica anche i proxy a bassa risoluzione (.LRV)", isOn: $downloadLRV)
                }
                Section("Sicurezza") {
                    Toggle("Chiedi conferma prima di eliminare dalla camera", isOn: $confirmDelete)
                    Text("\"Sposta\" cancella il file dalla camera solo dopo averne verificato la dimensione sul Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Cache") {
                    HStack {
                        Button("Svuota cache miniature") {
                            ThumbnailLoader.shared.clearCache(); cacheCleared = true
                        }
                        Button("Dimentica file già scaricati") { model.history.clear() }
                        if cacheCleared { Text("Fatto").foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Generale", systemImage: "gearshape") }

            Form {
                Section {
                    TextField("Indirizzo IP", text: $host)
                    TextField("Porta comandi", value: $controlPort, format: .number.grouping(.never))
                    TextField("Porta media", value: $mediaPort, format: .number.grouping(.never))
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Valori standard GoPro HERO5–HERO8: 10.5.5.9, porte 80 e 8080. Le modifiche valgono alla prossima connessione.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Ripristina valori predefiniti") {
                    host = "10.5.5.9"; controlPort = 80; mediaPort = 8080
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Connessione", systemImage: "wifi") }

            AboutView(iconSize: 84)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 430)
    }
}
