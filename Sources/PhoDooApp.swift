import SwiftUI
import AppKit

@main
struct PhoDooApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @StateObject private var photoSource = PhotoSource()
    @StateObject private var faceManager = FaceManager()
    @State private var isConnected = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

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
                    photoSource: photoSource,
                    aiAPIKey: aiAPIKey,
                    aiProvider: aiProvider,
                    faceManager: faceManager,
                    onDisconnect: {
                        photoSource.disconnect()
                        isConnected = false
                    }
                )
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    if let window = NSApplication.shared.windows.first {
                        let screen = window.screen ?? NSScreen.main
                        let screenSize = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
                        let width = min(1280, screenSize.width * 0.85)
                        let height = min(860, screenSize.height * 0.85)
                        window.setContentSize(NSSize(width: width, height: height))
                        window.center()
                    }
                }
            } else {
                SettingsView(
                    photoSource: photoSource,
                    onConnected: { isConnected = true }
                )
                .frame(minWidth: 500, minHeight: 500)
                .onAppear {
                    if let window = NSApplication.shared.windows.first {
                        let size = NSSize(width: 580, height: 680)
                        window.setContentSize(size)
                        window.center()
                    }
                    if !hasSeenOnboarding {
                        showOnboarding = true
                    }
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(hasSeenOnboarding: $hasSeenOnboarding)
                }
                .onChange(of: hasSeenOnboarding) { _, newValue in
                    if newValue { showOnboarding = false }
                }
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(faceManager)
        }
    }
}
