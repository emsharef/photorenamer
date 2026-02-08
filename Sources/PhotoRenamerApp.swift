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

    private var claudeAPIKey: String {
        KeychainHelper.load(account: "claude-api-key") ?? ""
    }

    var body: some Scene {
        WindowGroup {
            if isConnected {
                AlbumBrowserView(
                    piwigo: piwigo,
                    claudeAPIKey: claudeAPIKey,
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
