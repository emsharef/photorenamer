import SwiftUI
import AppKit

// MARK: - Saved Connection Model

struct SavedConnection: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var serverURL: String
    var username: String
    var sourceType: String = SourceType.piwigo.rawValue
    var folderPath: String?

    var keychainPasswordAccount: String { "piwigo-\(id.uuidString)" }

    var resolvedSourceType: SourceType {
        SourceType(rawValue: sourceType) ?? .piwigo
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("piwigoURL") private var piwigoURL = ""
    @AppStorage("piwigoUsername") private var piwigoUsername = ""
    @AppStorage("savedConnectionsJSON") private var savedConnectionsJSON = "[]"
    @AppStorage("sourceType") private var sourceTypeRaw: String = SourceType.piwigo.rawValue

    @State private var piwigoPassword = ""
    @State private var isConnecting = false
    @State private var connectionStatus: String?
    @State private var connectionSuccess = false
    @State private var saveConnection = false
    @State private var connectionName = ""
    @State private var selectedConnectionID: UUID?
    @State private var showDeleteConfirmation: UUID?
    @State private var selectedFolderPath: String = ""

    @ObservedObject var photoSource: PhotoSource
    var onConnected: () -> Void

    private var currentSourceType: SourceType {
        SourceType(rawValue: sourceTypeRaw) ?? .piwigo
    }

    // MARK: Saved connections persistence

    private var savedConnections: [SavedConnection] {
        get {
            guard let data = savedConnectionsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
        }
    }

    private var filteredSavedConnections: [SavedConnection] {
        savedConnections.filter { $0.resolvedSourceType == currentSourceType }
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
                    sourceTypePicker
                    if !filteredSavedConnections.isEmpty {
                        savedConnectionsSection
                    }
                    if currentSourceType == .piwigo {
                        connectionFormSection
                    } else {
                        localFolderSection
                    }
                    connectSection
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
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
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var appIconImage: Image {
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/AppIcon.icns" },
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path,
            "AppIcon.icns",
        ].compactMap { $0 }

        for path in candidates {
            if let nsImage = NSImage(contentsOfFile: path) {
                return Image(nsImage: nsImage)
            }
        }

        return Image(nsImage: NSApp.applicationIconImage)
    }

    // MARK: Source Type Picker

    private var sourceTypePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Photo Source", systemImage: "photo.stack")
                .font(.headline)

            Picker("Source", selection: $sourceTypeRaw) {
                ForEach(SourceType.allCases) { source in
                    Text(source.displayName).tag(source.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sourceTypeRaw) { _, _ in
                selectedConnectionID = nil
                connectionStatus = nil
                autoSelectSavedConnection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Saved Connections

    private var savedConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved Connections", systemImage: "bookmark.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                ForEach(filteredSavedConnections) { conn in
                    savedConnectionRow(conn)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedConnectionRow(_ conn: SavedConnection) -> some View {
        let isSelected = selectedConnectionID == conn.id
        let isLocal = conn.resolvedSourceType == .local
        return HStack(spacing: 10) {
            Image(systemName: isLocal ? "folder" : "server.rack")
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .white : .primary)
                if isLocal {
                    Text(conn.folderPath ?? "")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                } else {
                    Text("\(conn.username)@\(conn.serverURL)")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
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
                Text("Remove \"\(conn.name)\"?")
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

    // MARK: Connection Form (Piwigo)

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

    // MARK: Local Folder Section

    private var localFolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Folder", systemImage: "folder")
                .font(.headline)

            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                if selectedFolderPath.isEmpty {
                    Text("No folder selected")
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectedFolderPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                Button("Choose Folder...") {
                    chooseFolder()
                }
            }

            HStack(spacing: 12) {
                Toggle(isOn: $saveConnection) {
                    Text("Save folder bookmark")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)

                if saveConnection {
                    TextField("Bookmark name", text: $connectionName, prompt: Text("My Photos"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
            .padding(.top, 4)
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
                    Text(isConnecting ? "Connecting..." : (currentSourceType == .local ? "Open Folder" : "Connect"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(connectDisabled)

            if let status = connectionStatus {
                Label(status, systemImage: connectionSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(connectionSuccess ? .green : .red)
                    .font(.callout)
            }
        }
    }

    private var connectDisabled: Bool {
        if isConnecting { return true }
        if currentSourceType == .piwigo {
            return piwigoURL.isEmpty || piwigoUsername.isEmpty || piwigoPassword.isEmpty
        } else {
            return selectedFolderPath.isEmpty
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing photos"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFolderPath = url.path
        }
    }

    private func connect() {
        isConnecting = true
        connectionStatus = nil

        // Save connection if requested
        if saveConnection {
            saveCurrentConnection()
        }

        if currentSourceType == .piwigo {
            connectPiwigo()
        } else {
            connectLocal()
        }
    }

    private func connectPiwigo() {
        Task {
            do {
                try await photoSource.connectPiwigo(
                    serverURL: piwigoURL,
                    username: piwigoUsername,
                    password: piwigoPassword
                )
                await MainActor.run {
                    connectionStatus = "Connected! Found \(photoSource.allAlbums.count) albums."
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

    private func connectLocal() {
        let resolvedURL = URL(fileURLWithPath: selectedFolderPath)

        Task {
            do {
                try await photoSource.connectLocal(folderURL: resolvedURL)
                await MainActor.run {
                    connectionStatus = "Loaded! Found \(photoSource.allAlbums.count) folders."
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
        if conn.resolvedSourceType == .local {
            selectedFolderPath = conn.folderPath ?? ""
            sourceTypeRaw = SourceType.local.rawValue
        } else {
            piwigoURL = conn.serverURL
            piwigoUsername = conn.username
            sourceTypeRaw = SourceType.piwigo.rawValue
            if let pw = KeychainHelper.load(account: conn.keychainPasswordAccount) {
                piwigoPassword = pw
            } else {
                piwigoPassword = ""
            }
        }
        saveConnection = false
        connectionName = conn.name
    }

    private func saveCurrentConnection() {
        var connections = savedConnections

        if let selectedID = selectedConnectionID,
           let idx = connections.firstIndex(where: { $0.id == selectedID }) {
            if currentSourceType == .local {
                connections[idx].folderPath = selectedFolderPath
                connections[idx].sourceType = SourceType.local.rawValue
            } else {
                connections[idx].serverURL = piwigoURL
                connections[idx].username = piwigoUsername
                KeychainHelper.save(account: connections[idx].keychainPasswordAccount, password: piwigoPassword)
            }
            if !connectionName.isEmpty {
                connections[idx].name = connectionName
            }
        } else {
            if currentSourceType == .local {
                let name = connectionName.isEmpty ? URL(fileURLWithPath: selectedFolderPath).lastPathComponent : connectionName
                let conn = SavedConnection(
                    name: name,
                    serverURL: "",
                    username: "",
                    sourceType: SourceType.local.rawValue,
                    folderPath: selectedFolderPath
                )
                connections.append(conn)
                selectedConnectionID = conn.id
            } else {
                let name = connectionName.isEmpty ? piwigoURL : connectionName
                let conn = SavedConnection(name: name, serverURL: piwigoURL, username: piwigoUsername)
                KeychainHelper.save(account: conn.keychainPasswordAccount, password: piwigoPassword)
                connections.append(conn)
                selectedConnectionID = conn.id
            }
        }

        writeSavedConnections(connections)
    }

    private func deleteConnection(_ conn: SavedConnection) {
        var connections = savedConnections
        connections.removeAll { $0.id == conn.id }
        if conn.resolvedSourceType == .piwigo {
            KeychainHelper.delete(account: conn.keychainPasswordAccount)
        }
        writeSavedConnections(connections)
        if selectedConnectionID == conn.id {
            selectedConnectionID = nil
        }
    }

    private func autoSelectSavedConnection() {
        let connections = filteredSavedConnections
        guard connections.count == 1, let conn = connections.first else { return }
        selectConnection(conn)
    }
}
