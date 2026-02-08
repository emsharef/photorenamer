import SwiftUI
import AppKit

// MARK: - Saved Connection Model

struct SavedConnection: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var serverURL: String
    var username: String

    var keychainPasswordAccount: String { "piwigo-\(id.uuidString)" }
}

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("piwigoURL") private var piwigoURL = ""
    @AppStorage("piwigoUsername") private var piwigoUsername = ""
    @AppStorage("savedConnectionsJSON") private var savedConnectionsJSON = "[]"
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.claude.rawValue

    @State private var piwigoPassword = ""
    @State private var aiAPIKey = ""
    @State private var isConnecting = false
    @State private var connectionStatus: String?
    @State private var connectionSuccess = false
    @State private var saveConnection = false
    @State private var connectionName = ""
    @State private var selectedConnectionID: UUID?
    @State private var showDeleteConfirmation: UUID?

    @ObservedObject var piwigo: PiwigoClient
    var onConnected: () -> Void

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claude
    }

    // MARK: Saved connections persistence

    private var savedConnections: [SavedConnection] {
        get {
            guard let data = savedConnectionsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
        }
    }

    private func writeSavedConnections(_ connections: [SavedConnection]) {
        if let data = try? JSONEncoder().encode(connections),
           let json = String(data: data, encoding: .utf8) {
            savedConnectionsJSON = json
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    if !savedConnections.isEmpty {
                        savedConnectionsSection
                    }
                    connectionFormSection
                    apiKeySection
                    connectSection
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadAIAPIKey()
            migrateAPIKeyFromUserDefaults()
            autoSelectSavedConnection()
        }
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(spacing: 4) {
            appIconImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
            Text("PhotoRenamer")
                .font(.title)
                .fontWeight(.bold)
            Text("Connect to your Piwigo server to get started")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var appIconImage: Image {
        // Try loading from the .icns file next to the executable or in the project
        let candidates = [
            // When running from .app bundle
            Bundle.main.resourcePath.map { "\($0)/AppIcon.icns" },
            // When running as raw executable during development
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path,
            // Fallback: project root relative paths
            "AppIcon.icns",
        ].compactMap { $0 }

        for path in candidates {
            if let nsImage = NSImage(contentsOfFile: path) {
                return Image(nsImage: nsImage)
            }
        }

        // Final fallback: use the running app's icon
        return Image(nsImage: NSApp.applicationIconImage)
    }

    // MARK: Saved Connections

    private var savedConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved Connections", systemImage: "bookmark.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                ForEach(savedConnections) { conn in
                    savedConnectionRow(conn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedConnectionRow(_ conn: SavedConnection) -> some View {
        let isSelected = selectedConnectionID == conn.id
        return HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("\(conn.username)@\(conn.serverURL)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showDeleteConfirmation = conn.id
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .buttonStyle(.plain)
            .help("Delete connection")
            .alert("Delete Connection?", isPresented: Binding(
                get: { showDeleteConfirmation == conn.id },
                set: { if !$0 { showDeleteConfirmation = nil } }
            )) {
                Button("Delete", role: .destructive) { deleteConnection(conn) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \"\(conn.name)\" and its saved password?")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectConnection(conn) }
    }

    // MARK: Connection Form

    private var connectionFormSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Piwigo Server", systemImage: "globe")
                .font(.headline)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("Server URL", text: $piwigoURL, prompt: Text("https://photos.example.com"))
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Image(systemName: "person")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("Username", text: $piwigoUsername)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    SecureField("Password", text: $piwigoPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Toggle(isOn: $saveConnection) {
                    Text("Save connection")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)

                if saveConnection {
                    TextField("Connection name", text: $connectionName, prompt: Text("My Server"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI Provider", systemImage: "key")
                .font(.headline)

            Picker("Provider", selection: $aiProviderRaw) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: aiProviderRaw) { _, _ in
                loadAIAPIKey()
            }

            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                SecureField("API Key", text: $aiAPIKey, prompt: Text(aiProvider.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: aiAPIKey) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        KeychainHelper.save(account: aiProvider.keychainAccount, password: trimmed)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Connect Button

    private var connectSection: some View {
        VStack(spacing: 10) {
            Button(action: connect) {
                HStack(spacing: 8) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isConnecting ? "Connecting..." : "Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(piwigoURL.isEmpty || piwigoUsername.isEmpty || piwigoPassword.isEmpty || isConnecting)

            if let status = connectionStatus {
                Label(status, systemImage: connectionSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(connectionSuccess ? .green : .red)
                    .font(.callout)
            }
        }
    }

    // MARK: Actions

    private func connect() {
        isConnecting = true
        connectionStatus = nil

        // Save API key to keychain
        if !aiAPIKey.isEmpty {
            KeychainHelper.save(account: aiProvider.keychainAccount, password: aiAPIKey)
        }

        // Save connection if requested
        if saveConnection {
            saveCurrentConnection()
        }

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

    private func selectConnection(_ conn: SavedConnection) {
        selectedConnectionID = conn.id
        piwigoURL = conn.serverURL
        piwigoUsername = conn.username
        if let pw = KeychainHelper.load(account: conn.keychainPasswordAccount) {
            piwigoPassword = pw
        } else {
            piwigoPassword = ""
        }
        // Pre-fill save checkbox off since it's already saved
        saveConnection = false
        connectionName = conn.name
    }

    private func saveCurrentConnection() {
        var connections = savedConnections

        // If we selected an existing connection, update it
        if let selectedID = selectedConnectionID,
           let idx = connections.firstIndex(where: { $0.id == selectedID }) {
            connections[idx].serverURL = piwigoURL
            connections[idx].username = piwigoUsername
            if !connectionName.isEmpty {
                connections[idx].name = connectionName
            }
            KeychainHelper.save(account: connections[idx].keychainPasswordAccount, password: piwigoPassword)
        } else {
            // Create new
            let name = connectionName.isEmpty ? piwigoURL : connectionName
            let conn = SavedConnection(name: name, serverURL: piwigoURL, username: piwigoUsername)
            KeychainHelper.save(account: conn.keychainPasswordAccount, password: piwigoPassword)
            connections.append(conn)
            selectedConnectionID = conn.id
        }

        writeSavedConnections(connections)
    }

    private func deleteConnection(_ conn: SavedConnection) {
        var connections = savedConnections
        connections.removeAll { $0.id == conn.id }
        KeychainHelper.delete(account: conn.keychainPasswordAccount)
        writeSavedConnections(connections)
        if selectedConnectionID == conn.id {
            selectedConnectionID = nil
        }
    }

    private func loadAIAPIKey() {
        if let key = KeychainHelper.load(account: aiProvider.keychainAccount) {
            aiAPIKey = key
        } else {
            aiAPIKey = ""
        }
    }

    private func migrateAPIKeyFromUserDefaults() {
        let legacyKey = UserDefaults.standard.string(forKey: "claudeAPIKey") ?? ""
        if !legacyKey.isEmpty && KeychainHelper.load(account: "claude-api-key") == nil {
            KeychainHelper.save(account: "claude-api-key", password: legacyKey)
            if aiProvider == .claude {
                aiAPIKey = legacyKey
            }
            UserDefaults.standard.removeObject(forKey: "claudeAPIKey")
        }
    }

    /// Pre-selects the saved connection if there's only one, filling in the fields
    /// but letting the user review and click Connect themselves.
    private func autoSelectSavedConnection() {
        let connections = savedConnections
        guard connections.count == 1, let conn = connections.first else { return }
        selectConnection(conn)
    }
}
