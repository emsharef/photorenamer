import SwiftUI

enum BatchPhase {
    case idle
    case scanning
    case faceReview
    case generating
    case review
}

struct BatchPhotoItem: Identifiable {
    let id: Int
    let image: PiwigoImage
    var displayData: Data?
    var hiResData: Data?
    var detectedFaces: [DetectedFace] = []
    var identifiedNames: [String] = []
    var suggestedName: String = ""
    var isSelected: Bool = true
    var photoDate: Date?
}

struct PersonReferencePhoto: Identifiable {
    let id = UUID()
    let name: String
    let imageData: Data
    let sourcePhotoID: Int
}

struct BatchRenameView: View {
    let album: PiwigoAlbum
    @ObservedObject var piwigo: PiwigoClient
    let claudeAPIKey: String
    @ObservedObject var faceManager: FaceManager
    var onDone: () -> Void

    @State private var phase: BatchPhase = .idle
    @State private var items: [BatchPhotoItem] = []
    @State private var references: [PersonReferencePhoto] = []
    @State private var progress: Double = 0
    @State private var progressMessage: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Batch Rename: \(album.name)")
                    .font(.headline)
                Spacer()
                if phase != .idle {
                    Text(progressMessage)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Button("Close") { onDone() }
            }
            .padding()

            Divider()

            switch phase {
            case .idle:
                idleView
            case .scanning:
                scanningView
            case .faceReview:
                faceReviewView
            case .generating:
                generatingView
            case .review:
                reviewView
            }
        }
    }

    // MARK: - Phase Views

    private var idleView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("This will scan all photos in \"\(album.name)\", detect faces, generate AI names, and let you review before applying.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .foregroundStyle(.secondary)
            Button("Start Scanning") {
                startScanning()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: progress)
                .frame(maxWidth: 400)
            Text(progressMessage)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var faceReviewView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Review detected faces")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(uniqueIdentifiedNames.count) people found")
                    .font(.callout)
                Button("Continue to Naming") {
                    buildReferencesAndGenerate()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            // Show reference photos that will be used
            if !references.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(references) { ref in
                            VStack {
                                if let nsImage = NSImage(data: ref.imageData) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                Text(ref.name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Scrollable grid of photos with face results
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 16) {
                    ForEach($items) { $item in
                        BatchFaceCard(
                            item: $item,
                            faceManager: faceManager,
                            albumPath: album.fullPath
                        )
                    }
                }
                .padding()
            }
        }
    }

    private var generatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: progress)
                .frame(maxWidth: 400)
            Text(progressMessage)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var reviewView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(items.filter(\.isSelected).count) of \(items.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let err = errorMessage {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Button("Apply Selected") {
                    applyRenames()
                }
                .buttonStyle(.borderedProminent)
                .disabled(items.filter(\.isSelected).allSatisfy { $0.suggestedName.isEmpty })
            }
            .padding(.horizontal)

            // Table of renames
            List {
                ForEach($items) { $item in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $item.isSelected)
                            .labelsHidden()

                        if let data = item.displayData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.image.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            TextField("New title", text: $item.suggestedName)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }

                        if !item.identifiedNames.isEmpty {
                            Text(item.identifiedNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Unique names across all items

    private var uniqueIdentifiedNames: [String] {
        let all = items.flatMap(\.identifiedNames)
        return Array(Set(all)).sorted()
    }

    // MARK: - Phase 1: Scan

    private func startScanning() {
        phase = .scanning
        progress = 0

        Task {
            do {
                // Fetch all images
                progressMessage = "Fetching photo list..."
                let images = try await piwigo.fetchImages(albumID: album.id, perPage: 500)

                var batchItems: [BatchPhotoItem] = []
                for img in images {
                    batchItems.append(BatchPhotoItem(id: img.id, image: img))
                }

                let total = Double(batchItems.count)

                for i in batchItems.indices {
                    let img = batchItems[i].image
                    await MainActor.run {
                        progress = Double(i) / total
                        progressMessage = "Scanning \(i + 1)/\(Int(total)): \(img.file)"
                    }

                    // Download image
                    if let url = img.derivatives?.largestURL ?? img.derivatives?.displayURL {
                        if let data = try? await piwigo.downloadImage(url: url) {
                            batchItems[i].hiResData = data
                        }
                    }
                    if let url = img.derivatives?.displayURL {
                        if let data = try? await piwigo.downloadImage(url: url) {
                            batchItems[i].displayData = data
                        }
                    }

                    // Compute photo date
                    let photoDate = FaceManager.extractPhotoDate(
                        imageData: batchItems[i].hiResData ?? batchItems[i].displayData,
                        piwigoDateString: img.dateCreation,
                        albumPath: album.fullPath
                    )
                    batchItems[i].photoDate = photoDate

                    // Detect faces
                    if let data = batchItems[i].hiResData ?? batchItems[i].displayData {
                        if let faces = try? await faceManager.detectFaces(in: data, photoDate: photoDate) {
                            batchItems[i].detectedFaces = faces
                            batchItems[i].identifiedNames = faces.compactMap(\.matchedName)
                        }
                    }
                }

                await MainActor.run {
                    items = batchItems
                    progress = 1.0
                    buildInitialReferences()
                    phase = .faceReview
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .idle
                }
            }
        }
    }

    // MARK: - Build references

    private func buildInitialReferences() {
        // For each unique person, pick the photo where their face crop is largest
        var refsByName: [String: PersonReferencePhoto] = [:]

        for item in items {
            for face in item.detectedFaces {
                guard let name = face.matchedName else { continue }
                let faceArea = face.boundingBox.width * face.boundingBox.height

                if let existing = refsByName[name] {
                    // Check if this crop is larger (better reference)
                    if let existingItem = items.first(where: { $0.id == existing.sourcePhotoID }),
                       let existingFace = existingItem.detectedFaces.first(where: { $0.matchedName == name }) {
                        let existingArea = existingFace.boundingBox.width * existingFace.boundingBox.height
                        if faceArea > existingArea, let data = item.displayData {
                            refsByName[name] = PersonReferencePhoto(
                                name: name,
                                imageData: data,
                                sourcePhotoID: item.id
                            )
                        }
                    }
                } else if let data = item.displayData {
                    refsByName[name] = PersonReferencePhoto(
                        name: name,
                        imageData: data,
                        sourcePhotoID: item.id
                    )
                }
            }
        }

        references = refsByName.values.sorted { $0.name < $1.name }
    }

    private func buildReferencesAndGenerate() {
        buildInitialReferences()
        startGenerating()
    }

    // MARK: - Phase 3: Generate names

    private func startGenerating() {
        phase = .generating
        progress = 0

        Task {
            let claude = ClaudeClient(apiKey: claudeAPIKey)
            let total = Double(items.count)
            let refs = references.map {
                ClaudeClient.PersonReference(name: $0.name, imageData: $0.imageData)
            }

            for i in items.indices {
                await MainActor.run {
                    progress = Double(i) / total
                    progressMessage = "Naming \(i + 1)/\(Int(total))..."
                }

                guard let data = items[i].displayData else { continue }

                let names = items[i].identifiedNames
                let photoDate = items[i].photoDate

                do {
                    // Get description without date prefix — we'll add date + sequence ourselves
                    let title = try await claude.describeImageWithReferences(
                        imageData: data,
                        peopleNames: names,
                        references: refs,
                        albumPath: album.fullPath,
                        photoDate: nil  // Don't let Claude client add the date
                    )
                    // Build prefix: YYYYMMDD NNN
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyyMMdd"
                    let dateStr = photoDate.map { dateFormatter.string(from: $0) } ?? "00000000"
                    let seq = String(format: "%03d", i + 1)

                    await MainActor.run {
                        items[i].suggestedName = "\(dateStr) \(seq) \(title)"
                    }
                } catch {
                    await MainActor.run {
                        items[i].suggestedName = "[Error: \(error.localizedDescription)]"
                    }
                }
            }

            await MainActor.run {
                progress = 1.0
                phase = .review
            }
        }
    }

    // MARK: - Phase 4: Apply

    private func applyRenames() {
        let selected = items.filter { $0.isSelected && !$0.suggestedName.isEmpty }
        guard !selected.isEmpty else { return }

        phase = .generating
        progress = 0
        progressMessage = "Applying renames..."

        Task {
            let total = Double(selected.count)
            var failed = 0

            for (i, item) in selected.enumerated() {
                await MainActor.run {
                    progress = Double(i) / total
                    progressMessage = "Renaming \(i + 1)/\(Int(total))..."
                }

                do {
                    try await piwigo.renameImage(imageID: item.id, newName: item.suggestedName)
                } catch {
                    failed += 1
                }
            }

            await MainActor.run {
                progress = 1.0
                if failed > 0 {
                    errorMessage = "\(selected.count - failed) renamed, \(failed) failed"
                } else {
                    progressMessage = "Done! \(selected.count) photos renamed."
                }
                onDone()
            }
        }
    }
}

// MARK: - Face card for batch review

struct BatchFaceCard: View {
    @Binding var item: BatchPhotoItem
    @ObservedObject var faceManager: FaceManager
    let albumPath: String

    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail
            if let data = item.displayData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(6)
            }

            Text(item.image.displayName)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)

            // Detected faces - interactive
            if item.detectedFaces.isEmpty {
                Text("No faces")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(item.detectedFaces.enumerated()), id: \.element.id) { idx, face in
                        BatchFaceChip(
                            face: face,
                            faceManager: faceManager,
                            onLabeled: { name in
                                labelFace(at: idx, name: name)
                            }
                        )
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private func labelFace(at index: Int, name: String) {
        let face = item.detectedFaces[index]
        faceManager.labelFace(
            name: name,
            featurePrint: face.featurePrint,
            cropImage: face.cropImage,
            photoDate: item.photoDate
        )
        item.detectedFaces[index].matchedName = name
        item.detectedFaces[index].isAmbiguous = false
        item.identifiedNames = item.detectedFaces.compactMap(\.matchedName)
    }
}

struct BatchFaceChip: View {
    let face: DetectedFace
    @ObservedObject var faceManager: FaceManager
    var onLabeled: (String) -> Void

    @State private var isLabeling = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: face.cropImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(face.matchedName != nil ? Color.green : Color.orange, lineWidth: 2)
                )
                .onTapGesture {
                    if face.matchedName == nil {
                        isLabeling = true
                    }
                }

            if let name = face.matchedName {
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if isLabeling {
                VStack(spacing: 2) {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 70)
                        .onSubmit { submitLabel() }

                    if !faceManager.knownNames.isEmpty {
                        Menu("Pick") {
                            ForEach(faceManager.knownNames, id: \.self) { name in
                                Button(name) {
                                    newName = name
                                    submitLabel()
                                }
                            }
                        }
                        .font(.system(size: 9))
                    }
                }
            } else {
                Text("?")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func submitLabel() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onLabeled(name)
        isLabeling = false
        newName = ""
    }
}
