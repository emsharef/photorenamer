import SwiftUI
import AppKit

@main
struct PhotoRenamerApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @StateObject private var piwigo = PiwigoClient()
    @StateObject private var faceManager = FaceManager()
    @State private var isConnected = false

    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.claude.rawValue

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claude
    }

    private var aiAPIKey: String {
        KeychainHelper.load(account: aiProvider.keychainAccount) ?? ""
    }

    var body: some Scene {
        WindowGroup {
            if isConnected {
                AlbumBrowserView(
                    piwigo: piwigo,
                    aiAPIKey: aiAPIKey,
                    aiProvider: aiProvider,
                    faceManager: faceManager,
                    onDisconnect: { isConnected = false }
                )
                .frame(minWidth: 900, minHeight: 600)
            } else {
                SettingsView(
                    piwigo: piwigo,
                    onConnected: { isConnected = true }
                )
            }
        }
    }
}
