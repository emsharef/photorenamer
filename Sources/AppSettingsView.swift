import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            AIProviderTab()
                .tabItem {
                    Label("AI Provider", systemImage: "brain")
                }

            NamingFormatTab()
                .tabItem {
                    Label("Naming Format", systemImage: "textformat")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - AI Provider Tab

private struct AIProviderTab: View {
    @AppStorage("aiProvider") private var aiProviderRaw: String = AIProvider.claude.rawValue
    @State private var aiAPIKey = ""

    private var aiProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .claude
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $aiProviderRaw) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: aiProviderRaw) { _, _ in
                    loadAPIKey()
                }

                SecureField("API Key", text: $aiAPIKey, prompt: Text(aiProvider.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: aiAPIKey) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        KeychainHelper.save(account: aiProvider.keychainAccount, password: trimmed)
                    }
            } header: {
                Text("AI Provider")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadAPIKey()
            migrateAPIKeyFromUserDefaults()
        }
    }

    private func loadAPIKey() {
        aiAPIKey = KeychainHelper.load(account: aiProvider.keychainAccount) ?? ""
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
}

// MARK: - Naming Format Tab

private struct NamingFormatTab: View {
    @AppStorage("namingFormat") private var namingFormat: String = NamingFormat.defaultTemplate

    private let tokenDocs: [(token: String, description: String, example: String)] = [
        ("{title}", "AI-generated description", "Sarah and John on a boat"),
        ("{date}", "Photo date as YYYYMMDD", "20251112"),
        ("{date:FORMAT}", "Photo date with custom format", "{date:yyyy-MM-dd} → 2025-11-12"),
        ("{seq}", "Sequence number, 3 digits", "001"),
        ("{seq:N}", "Sequence number, N digits", "{seq:4} → 0001"),
        ("{people}", "Identified people names", "Sarah and John"),
        ("{album}", "Album or folder name", "Vacation 2025"),
        ("{original}", "Original filename (no extension)", "IMG_4523"),
        ("{location}", "Location from EXIF GPS data", "Lake Tahoe"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("Format", text: $namingFormat)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                HStack(spacing: 4) {
                    Text("Preview:")
                        .foregroundStyle(.secondary)
                    Text(NamingFormat.preview(template: namingFormat))
                        .font(.system(.body, design: .monospaced))
                }
                .font(.callout)

                Button("Reset to Default") {
                    namingFormat = NamingFormat.defaultTemplate
                }
                .font(.callout)
            } header: {
                Text("Format Template")
            } footer: {
                Text("Tokens that have no value for a photo (e.g. no date, no faces) are removed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Token")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("Description")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("Example")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                        .gridCellColumns(3)

                    ForEach(tokenDocs, id: \.token) { doc in
                        GridRow {
                            Text(doc.token)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(doc.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(doc.example)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Available Tokens")
            }
        }
        .formStyle(.grouped)
    }
}
