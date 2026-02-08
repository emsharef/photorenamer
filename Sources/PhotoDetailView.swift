import SwiftUI

struct PhotoDetailView: View {
    let image: PiwigoImage
    let piwigo: PiwigoClient
    let aiAPIKey: String
    let aiProvider: AIProvider
    let albumPath: String?
    @ObservedObject var faceManager: FaceManager

    @State private var imageData: Data?
    @State private var hiResData: Data?
    @State private var suggestedName: String = ""
    @State private var isAnalyzing = false
    @State private var isRenaming = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var detectedFaces: [DetectedFace] = []
    @State private var isDetectingFaces = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Photo preview
                if let data = imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 400)
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 300)
                        .cornerRadius(8)
                        .overlay(ProgressView())
                }

                // Face detection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Faces")
                            .font(.headline)
                        Spacer()
                        Button(action: detectFaces) {
                            if isDetectingFaces {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Detect Faces", systemImage: "person.crop.rectangle")
                            }
                        }
                        .disabled(isDetectingFaces || imageData == nil)
                    }

                    FaceLabelView(
                        detectedFaces: detectedFaces,
                        photoDate: photoDate,
                        faceManager: faceManager,
                        onFacesUpdated: { updated in
                            detectedFaces = updated
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Current info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Title")
                        .font(.headline)
                    Text(image.displayName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("File: \(image.file)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // AI suggestion
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("New Title")
                            .font(.headline)
                        Spacer()
                        Button(action: analyze) {
                            if isAnalyzing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Analyze", systemImage: "sparkles")
                            }
                        }
                        .disabled(isAnalyzing || aiAPIKey.isEmpty)
                    }

                    TextField("Suggested name will appear here", text: $suggestedName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    if aiAPIKey.isEmpty {
                        Text("Set your AI API key in settings to enable AI analysis.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Apply button
                HStack {
                    Button(action: applyRename) {
                        if isRenaming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Apply Rename", systemImage: "checkmark.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(suggestedName.isEmpty || isRenaming)

                    if let msg = statusMessage {
                        Text(msg)
                            .foregroundStyle(isError ? .red : .green)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .task(id: image.id) {
            await loadImage()
        }
    }

    private var photoDate: Date? {
        FaceManager.extractPhotoDate(
            imageData: hiResData ?? imageData,
            piwigoDateString: image.dateCreation,
            albumPath: albumPath
        )
    }

    private var photoLocation: String? {
        FaceManager.extractPhotoLocation(imageData: hiResData ?? imageData)
    }

    private func loadImage() async {
        imageData = nil
        hiResData = nil
        suggestedName = ""
        statusMessage = nil
        detectedFaces = []

        // Load display image (medium)
        if let url = image.derivatives?.displayURL {
            if let data = try? await piwigo.downloadImage(url: url) {
                await MainActor.run { self.imageData = data }
            }
        }

        // Load hi-res image for face detection in background
        if let url = image.derivatives?.largestURL,
           url != image.derivatives?.displayURL {
            if let data = try? await piwigo.downloadImage(url: url) {
                await MainActor.run { self.hiResData = data }
            }
        }
    }

    private func detectFaces() {
        guard let data = hiResData ?? imageData else { return }
        isDetectingFaces = true

        Task {
            do {
                let faces = try await faceManager.detectFaces(in: data, photoDate: photoDate)
                await MainActor.run {
                    detectedFaces = faces
                    isDetectingFaces = false
                }
            } catch {
                await MainActor.run {
                    isDetectingFaces = false
                }
            }
        }
    }

    /// Names of people identified in the current photo's detected faces
    private var identifiedPeople: [String] {
        let names = detectedFaces.compactMap(\.matchedName)
        return Array(Set(names)).sorted()
    }

    private func analyze() {
        guard let data = imageData else { return }
        isAnalyzing = true
        statusMessage = nil

        Task {
            let client = AIClient(provider: aiProvider, apiKey: aiAPIKey)
            let maxRetries = 5
            var lastError: Error?

            for attempt in 1...maxRetries {
                do {
                    let name = try await client.describeImage(
                        imageData: data,
                        peopleNames: identifiedPeople,
                        albumPath: albumPath,
                        photoDate: photoDate,
                        photoLocation: photoLocation
                    )
                    await MainActor.run {
                        suggestedName = name
                        isAnalyzing = false
                    }
                    return
                } catch {
                    lastError = error
                    if attempt < maxRetries {
                        await MainActor.run {
                            statusMessage = "Retry \(attempt)/\(maxRetries)..."
                            isError = false
                        }
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    }
                }
            }

            await MainActor.run {
                statusMessage = lastError?.localizedDescription ?? "Unknown error"
                isError = true
                isAnalyzing = false
            }
        }
    }

    private func applyRename() {
        isRenaming = true
        statusMessage = nil

        Task {
            do {
                try await piwigo.renameImage(imageID: image.id, newName: suggestedName)
                await MainActor.run {
                    statusMessage = "Renamed successfully!"
                    isError = false
                    isRenaming = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isError = true
                    isRenaming = false
                }
            }
        }
    }
}
