import SwiftUI

struct ContentView: View {
    @Environment(LibraryViewModel.self) private var model
    @AppStorage(SettingsKeys.tileSize) private var tileSize: Double = 180
    @AppStorage(SettingsKeys.viewMode) private var viewMode: ViewMode = .grid
    @AppStorage(SettingsKeys.confirmDelete) private var confirmDelete = true
    @State private var pendingDelete: [MediaItem] = []
    @State private var showTransfers = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            Group {
                if model.state == .connected {
                    browser
                } else {
                    ConnectionView()
                }
            }
            .toolbar { toolbarContent }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Cerca nome, data, tipo…")
        .sheet(item: $model.previewItem) { item in
            PreviewView(initial: item, items: model.filteredItems)
                .environment(model)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }
        ), titleVisibility: .visible) {
            Button("Elimina dalla GoPro", role: .destructive) {
                let items = pendingDelete
                pendingDelete = []
                Task { await model.delete(items) }
            }
            Button("Annulla", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("I file verranno cancellati definitivamente dalla scheda SD della camera.")
        }
        .alert("Errore", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            guard model.state == .disconnected else { return }
            // Se il Mac non è sulla rete della GoPro ma una camera è già stata abbinata, si usa il Bluetooth.
            let host = GoProEndpoint.fromDefaults().host
            if LibraryViewModel.networkHint(for: host) != nil,
               UserDefaults.standard.string(forKey: "bleCameraIdentifier") != nil {
                await model.connectViaBluetooth()
            } else {
                await model.connect()
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Eliminare \(pendingDelete[0].fileName)?" : "Eliminare \(pendingDelete.count) elementi?"
    }

    func requestDelete(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        if confirmDelete { pendingDelete = items } else { Task { await model.delete(items) } }
    }

    @ViewBuilder
    private var browser: some View {
        let list = model.filteredItems
        VStack(spacing: 0) {
            if model.items.isEmpty && !model.isLoadingList {
                ContentUnavailableView("Nessun file sulla camera", systemImage: "sdcard",
                                       description: Text("La scheda SD è vuota."))
            } else if list.isEmpty && !model.isLoadingList {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                switch viewMode {
                case .grid:
                    MediaGridView(items: list, tileSize: tileSize, onDelete: requestDelete)
                case .list:
                    MediaTableView(items: list, onDelete: requestDelete)
                }
            }
            Divider()
            StatusBar(visibleCount: list.count)
        }
        .overlay {
            if model.isLoadingList && model.items.isEmpty {
                ProgressView("Lettura dei file dalla camera…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onDeleteCommand { requestDelete(model.selectedItems) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Aggiorna", systemImage: "arrow.clockwise")
            }
            .disabled(model.state != .connected || model.isLoadingList)
            .help("Rileggi la lista dei file dalla camera (⌘R)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Vista", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Cambia vista")

            if viewMode == .grid {
                HStack(spacing: 4) {
                    Image(systemName: "photo").imageScale(.small)
                    Slider(value: $tileSize, in: TileSize.min...TileSize.max)
                        .frame(width: 110)
                    Image(systemName: "photo").imageScale(.large)
                }
                .help("Dimensione icone (⌘+ / ⌘-)")
            }

            Menu {
                Picker("Ordina per", selection: $model.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                if viewMode == .grid {
                    Toggle("Raggruppa per giorno", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: SettingsKeys.groupByDay) },
                        set: { UserDefaults.standard.set($0, forKey: SettingsKeys.groupByDay) }
                    ))
                }
            } label: {
                Label("Ordina", systemImage: "arrow.up.arrow.down")
            }
            .help("Ordinamento")

            let selected = model.selectedItems
            Menu {
                Button("Scarica in…") {
                    if let url = model.chooseFolder() { model.copy(selected, to: url) }
                }
                Button("Sposta in…") {
                    if let url = model.chooseFolder() { model.move(selected, to: url) }
                }
                Divider()
                Button("Sposta nella cartella predefinita") { model.move(selected) }
            } label: {
                Label("Scarica", systemImage: "square.and.arrow.down")
            } primaryAction: {
                model.copy(selected)
            }
            .disabled(selected.isEmpty)
            .help("Copia i selezionati sul Mac (⌘D). Il menu offre Sposta (scarica e cancella dalla camera).")

            Button(role: .destructive) {
                requestDelete(selected)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
            .help("Elimina dalla camera (⌫)")

            Button {
                showTransfers.toggle()
            } label: {
                TransferToolbarIcon()
            }
            .help(model.transfers.isActive ? "Trasferimenti — \(model.transfers.summaryLine)" : "Trasferimenti")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersView()
                    .environment(model)
            }
        }
    }
}

struct TransferToolbarIcon: View {
    @Environment(LibraryViewModel.self) private var model

    var body: some View {
        let t = model.transfers
        if t.isActive {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle().trim(from: 0, to: t.overallFraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(t.pendingCount)").font(.system(size: 9, weight: .bold))
            }
            .frame(width: 18, height: 18)
        } else {
            Label("Trasferimenti", systemImage: "arrow.down.circle")
        }
    }
}

struct StatusBar: View {
    @Environment(LibraryViewModel.self) private var model
    let visibleCount: Int

    var body: some View {
        HStack(spacing: 12) {
            if model.isLoadingList { ProgressView().controlSize(.small) }
            Text(summary)
            Spacer()
            if model.transfers.isActive {
                Text(model.transfers.summaryLine)
                    .monospacedDigit()
                ProgressView(value: model.transfers.overallFraction)
                    .frame(width: 120)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var summary: String {
        let sel = model.selection.count
        var s = "\(visibleCount) di \(model.items.count) elementi"
        if sel > 0 {
            let bytes = model.selectedItems.reduce(Int64(0)) { $0 + $1.size }
            s += " · \(sel) selezionati (\(Formatters.bytes.string(fromByteCount: bytes)))"
        }
        return s
    }
}
