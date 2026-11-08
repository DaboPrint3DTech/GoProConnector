import SwiftUI

@main
struct GoProConnectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = LibraryViewModel()
    @AppStorage(SettingsKeys.tileSize) private var tileSize: Double = 180
    @AppStorage(SettingsKeys.viewMode) private var viewMode: ViewMode = .grid

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKeys.host: "10.5.5.9",
            SettingsKeys.controlPort: 80,
            SettingsKeys.mediaPort: 8080,
            SettingsKeys.destination: SettingsKeys.defaultDestination,
            SettingsKeys.organizeByDate: true,
            SettingsKeys.downloadLRV: false,
            SettingsKeys.confirmDelete: true,
            SettingsKeys.groupByDay: true,
            SettingsKeys.previewHighQuality: false,
        ])
    }

    var body: some Scene {
        WindowGroup("GoPro Connector", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button("Connetti") { Task { await model.smartConnect() } }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(model.state == .connected || model.state == .connecting)
                Button("Aggiorna lista file") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.state != .connected)
                Button("Disconnetti e spegni WiFi GoPro") { Task { await model.disconnectAndRestoreNetwork() } }
                    .disabled(model.state != .connected)
                Divider()
                Button("Scarica selezionati") { model.copy(model.selectedItems) }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(model.selection.isEmpty)
                Button("Sposta selezionati sul Mac") { model.move(model.selectedItems) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Picker("Vista", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.label).tag($0) }
                }
                Button("Ingrandisci icone") { tileSize = min(TileSize.max, tileSize + TileSize.step) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Riduci icone") { tileSize = max(TileSize.min, tileSize - TileSize.step) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Dimensione predefinita") { tileSize = 180 }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessario quando l'app è avviata come eseguibile (swift run) e non come bundle .app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var label: String { self == .grid ? "Icone" : "Elenco" }
    var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum TileSize {
    static let min: Double = 90
    static let max: Double = 420
    static let step: Double = 30
}
