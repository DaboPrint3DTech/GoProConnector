import SwiftUI

enum AppLinks {
    static let githubProfile = URL(string: "https://github.com/DaboPrint3DTech")!
    static let repository = URL(string: "https://github.com/DaboPrint3DTech/GoProConnector")!
}

/// About the app: used in the "About GoPro Connector" window and in Settings › Info.
struct AboutView: View {
    var iconSize: CGFloat = 128
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)

            VStack(spacing: 3) {
                Text("GoPro Connector").font(.title2.bold())
                Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Text("Download photos and videos from your GoPro over WiFi, without a USB cable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 30)

            VStack(spacing: 2) {
                Text("Developed by").font(.caption).foregroundStyle(.secondary)
                Text("DaboPrint3D · Design & Printing").font(.headline)
            }

            HStack(spacing: 10) {
                Button {
                    openURL(AppLinks.githubProfile)
                } label: {
                    Label("DaboPrint3DTech on GitHub", systemImage: "person.crop.circle")
                }
                .help(AppLinks.githubProfile.absoluteString)
                Button {
                    openURL(AppLinks.repository)
                } label: {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help(AppLinks.repository.absoluteString)
            }
            .buttonStyle(.bordered)

            Link("github.com/DaboPrint3DTech", destination: AppLinks.githubProfile)
                .font(.caption)

            Text("© 2026 DaboPrint3D")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(minWidth: 380)
    }
}

/// Menu item that opens the About window.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About GoPro Connector") { openWindow(id: "about") }
    }
}
