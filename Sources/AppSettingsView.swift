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

            BatchOptionsTab()
                .tabItem {
                    Label("Batch Options", systemImage: "rectangle.and.pencil.and.ellipsis")
                }

            FaceRecognitionTab()
                .tabItem {
                    Label("Face Recognition", systemImage: "person.crop.rectangle")
                }
        }
        .frame(width: 500, height: 450)
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
        ("{title_}", "Title, lowercase with underscores", "sarah_and_john_on_a_boat"),
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tokenDocs, id: \.token) { doc in
                            HStack(spacing: 8) {
                                Text(doc.token)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 100, alignment: .leading)
                                Text(doc.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(doc.example)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            if doc.token != tokenDocs.last?.token {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 140)
            } header: {
                Text("Available Tokens")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Batch Options Tab

private struct BatchOptionsTab: View {
    @AppStorage("batchSize") private var batchSize: Int = 50
    @AppStorage("yoloMode") private var yoloMode: Bool = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Batch Size")
                    Spacer()
                    TextField("", value: $batchSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: $batchSize, in: 10...500, step: 10)
                        .labelsHidden()
                }
                Text("Photos are processed in batches of this size. Smaller batches use less memory; larger batches require fewer rounds.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Batch Processing")
            }

            Section {
                Toggle("YOLO Mode", isOn: $yoloMode)
                Text("Skip face review and name review steps — scan, generate names, and apply them automatically without pausing for confirmation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Auto Mode")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Face Recognition Tab

private struct FaceRecognitionTab: View {
    @EnvironmentObject var faceManager: FaceManager
    @AppStorage("faceMatchThreshold") private var matchThreshold: Double = 1.0
    @AppStorage("faceDateRangeYears") private var dateRangeYears: Double = 10.0
    @State private var showKnownFaces = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(faceManager.knownFaces.count) samples, \(faceManager.knownNames.count) people")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage Known Faces...") {
                        showKnownFaces = true
                    }
                }
            } header: {
                Text("Known Faces Database")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Match Threshold")
                        Spacer()
                        Text(String(format: "%.1f", matchThreshold))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $matchThreshold, in: 0.5...2.0, step: 0.1)
                    HStack {
                        Text("Stricter")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("More lenient")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Date Range")
                        Spacer()
                        Text("\(Int(dateRangeYears)) years")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $dateRangeYears, in: 1...30, step: 1)
                    Text("Face samples older than this range (relative to the photo) are ignored during matching.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Button("Reset to Defaults") {
                        matchThreshold = 1.0
                        dateRangeYears = 10.0
                    }
                    .font(.callout)
                }
            } header: {
                Text("Recognition Thresholds")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showKnownFaces) {
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { showKnownFaces = false }
                        .padding()
                }
                KnownFacesView(faceManager: faceManager)
            }
            .frame(minWidth: 500, minHeight: 400)
        }
    }
}
