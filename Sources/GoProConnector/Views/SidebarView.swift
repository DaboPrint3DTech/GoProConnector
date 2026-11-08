import SwiftUI

struct SidebarView: View {
    @Environment(LibraryViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("Camera") {
                CameraCard()
            }

            if model.state == .connected {
                Section("Type") {
                    kindRow(nil, label: String(localized: "All media"), icon: "square.grid.2x2")
                    ForEach(MediaKind.allCases) { kind in
                        if model.count(of: kind) > 0 {
                            kindRow(kind, label: kind.label, icon: kind.systemImage)
                        }
                    }
                }

                Section("Status") {
                    Picker("Status", selection: $model.downloadFilter) {
                        ForEach(DownloadFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                if !model.availableDays.isEmpty {
                    Section("Days") {
                        dayRow(nil)
                        ForEach(model.availableDays, id: \.self) { dayRow($0) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func kindRow(_ kind: MediaKind?, label: String, icon: String) -> some View {
        Button {
            model.kindFilter = kind
        } label: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Text("\(model.count(of: kind))").foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .listRowBackground(model.kindFilter == kind ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func dayRow(_ day: Date?) -> some View {
        Button {
            model.dayFilter = day
        } label: {
            HStack {
                Text(day.map { Formatters.cameraDay.string(from: $0) } ?? String(localized: "All days"))
                    .lineLimit(1)
                Spacer()
                if let day {
                    Text("\(model.items.filter { Formatters.utcCalendar.startOfDay(for: $0.created) == day }.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.dayFilter == day ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

struct CameraCard: View {
    @Environment(LibraryViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(model.info?.modelName ?? "GoPro")
                    .font(.headline)
            }
            switch model.state {
            case .connected:
                if let s = model.status {
                    if let b = s.batteryPercent {
                        Label("Battery \(b)%", systemImage: batteryIcon(b))
                    }
                    if let free = s.freeSpaceBytes {
                        Label("\(Formatters.bytes.string(fromByteCount: free)) free", systemImage: "sdcard")
                    }
                    if !s.sdCardOK {
                        Label("SD card problem", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Label("\(model.items.count) items · \(Formatters.bytes.string(fromByteCount: model.totalSize))",
                      systemImage: "film.stack")
                if let other = LibraryViewModel.otherConnectionName() {
                    Label("Internet via \(other)", systemImage: "network")
                        .foregroundStyle(.secondary)
                } else {
                    Label("No Internet while on the GoPro", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                        .help("Connect an Ethernet cable to the Mac to stay online while downloading.")
                }
                Button("Disconnect and Turn Off GoPro WiFi") { Task { await model.disconnectAndRestoreNetwork() } }
                    .controlSize(.small)
            case .connecting:
                HStack { ProgressView().controlSize(.small); Text("Connecting…") }
            case .disconnected, .failed:
                Text("Not connected").foregroundStyle(.secondary)
                Button("Connect") { Task { await model.smartConnect() } }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch model.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private func batteryIcon(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct ConnectionView: View {
    @Environment(LibraryViewModel.self) private var model
    @AppStorage(SettingsKeys.wifiSSID) private var ssid = ""
    @State private var password = ""
    @State private var joining = false
    @State private var joinMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text("Connect your GoPro over WiFi").font(.title2.bold())
                        Text("Made for the HERO8 Black (also works with HERO5–HERO7).")
                            .foregroundStyle(.secondary)
                    }
                }

                if case .failed(let msg) = model.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                GroupBox("Automatic connection via Bluetooth (recommended)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Like Quik: the app turns on the camera's WiFi over Bluetooth, reads the network name and password, and connects the Mac by itself.")
                        Text("**First time:** on the GoPro go to Preferences › Connections › Connect Device › GoPro App, and close Quik on your phone (or turn off its Bluetooth). macOS will ask you to allow Bluetooth and to confirm the pairing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button {
                                Task { await model.connectViaBluetooth() }
                            } label: {
                                Label("Turn On WiFi via Bluetooth and Connect", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isLinking)
                            if model.isLinking { ProgressView().controlSize(.small) }
                        }
                        if model.isLinking || !model.bluetooth.statusText.isEmpty {
                            Text(model.linkStatus.isEmpty ? model.bluetooth.statusText : model.linkStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if model.bluetooth.awaitingChoice {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.bluetooth.choices) { c in
                                    Button {
                                        model.bluetooth.choose(c.name)
                                    } label: {
                                        HStack {
                                            Image(systemName: "camera")
                                            Text(c.name).bold()
                                            Text("signal \(c.rssi) dBm").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let name = model.bluetooth.rememberedCameraName, !model.isLinking {
                            HStack(spacing: 6) {
                                Text("Paired camera: \(name)").font(.callout).foregroundStyle(.secondary)
                                Button("Forget") { model.bluetooth.forgetCamera() }
                                    .buttonStyle(.link)
                                    .font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                Text("Or manually").font(.headline).padding(.top, 6)

                GroupBox("Join the Mac to the GoPro's network") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Select it from the macOS WiFi menu, or enter it here and the app will join it for you. While connected to the GoPro, the Mac has no Internet access over WiFi.")
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Network name (e.g. GP2xxxxxxx)", text: $ssid)
                            SecureField("Password", text: $password)
                            Button(joining ? LocalizedStringKey("Joining…") : LocalizedStringKey("Join WiFi")) { join() }
                                .disabled(ssid.isEmpty || password.isEmpty || joining)
                        }
                        if let joinMessage { Text(joinMessage).font(.callout).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Connect (if the Mac is already on the GoPro's network)") {
                    HStack {
                        Text("Camera address: \(GoProEndpoint.fromDefaults().host)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.state == .connecting { ProgressView().controlSize(.small) }
                        Button("Connect to GoPro") { Task { await model.connect() } }
                            .disabled(model.state == .connecting)
                    }
                    .padding(6)
                }
            }
            .padding(30)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onAppear { password = Keychain.password(for: ssid) ?? "" }
        .onChange(of: ssid) { _, new in password = Keychain.password(for: new) ?? "" }
    }

    private func join() {
        joining = true
        joinMessage = nil
        Keychain.setPassword(password, for: ssid)
        Task {
            do {
                try await WiFiJoiner.join(ssid: ssid, password: password)
                joinMessage = String(localized: "Joined \(ssid). Connecting to the camera…")
                try? await Task.sleep(for: .seconds(2))
                await model.connect()
            } catch {
                joinMessage = String(localized: "Can't join: \(error.localizedDescription)")
            }
            joining = false
        }
    }
}
