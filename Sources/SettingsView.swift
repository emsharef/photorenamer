import SwiftUI

struct SettingsView: View {
    @AppStorage("piwigoURL") private var piwigoURL = ""
    @AppStorage("piwigoUsername") private var piwigoUsername = ""
    @AppStorage("claudeAPIKey") private var claudeAPIKey = ""

    @State private var piwigoPassword = ""
    @State private var isConnecting = false
    @State private var connectionStatus: String?
    @State private var connectionSuccess = false

    @ObservedObject var piwigo: PiwigoClient
    var onConnected: () -> Void

    var body: some View {
        Form {
            Section {
                Text("PhotoRenamer")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Connect to your Piwigo server to get started.")
                    .foregroundStyle(.secondary)
            }

            Section("Piwigo Server") {
                TextField("Server URL", text: $piwigoURL, prompt: Text("https://photos.example.com"))
                    .textFieldStyle(.roundedBorder)
                TextField("Username", text: $piwigoUsername)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $piwigoPassword)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Claude API") {
                SecureField("API Key", text: $claudeAPIKey, prompt: Text("sk-ant-..."))
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                Button(action: connect) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(piwigoURL.isEmpty || piwigoUsername.isEmpty || piwigoPassword.isEmpty || isConnecting)
                .buttonStyle(.borderedProminent)

                if let status = connectionStatus {
                    Text(status)
                        .foregroundStyle(connectionSuccess ? .green : .red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 420)
        .padding()
    }

    private func connect() {
        isConnecting = true
        connectionStatus = nil

        Task {
            do {
                try await piwigo.login(
                    serverURL: piwigoURL,
                    username: piwigoUsername,
                    password: piwigoPassword
                )
                try await piwigo.fetchAlbums()
                await MainActor.run {
                    connectionStatus = "Connected! Found \(piwigo.allAlbums.count) albums."
                    connectionSuccess = true
                    isConnecting = false
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    connectionStatus = error.localizedDescription
                    connectionSuccess = false
                    isConnecting = false
                }
            }
        }
    }
}
