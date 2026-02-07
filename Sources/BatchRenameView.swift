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
    var photoLocation: String?
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
    @State private var userNotes: String = ""

    // Batch pagination
    @State private var allImages: [PiwigoImage] = []
    @State private var currentBatchIndex: Int = 0
    @State private var totalRenamed: Int = 0
    private let batchSize = 50

    private var totalBatches: Int {
        guard !allImages.isEmpty else { return 0 }
        return (allImages.count + batchSize - 1) / batchSize
    }

    private var currentBatchImages: [PiwigoImage] {
        let start = currentBatchIndex * batchSize
        let end = min(start + batchSize, allImages.count)
        guard start < allImages.count else { return [] }
        return Array(allImages[start..<end])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Batch Rename: \(album.name)")
                    .font(.headline)
                if totalBatches > 1 {
                    Text("(batch \(currentBatchIndex + 1) of \(totalBatches))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
            Text("This will scan photos in \"\(album.name)\" in batches of \(batchSize), detect faces, generate AI names, and let you review before applying each batch.")
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

            // Additional context for the naming model
            HStack(spacing: 8) {
                Text("Notes:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Additional context for naming (e.g., event, occasion, location details)", text: $userNotes)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
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
                Button(currentBatchIndex + 1 < totalBatches ? "Apply & Next Batch" : "Apply Selected") {
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
                // Fetch full image list on first batch
                if allImages.isEmpty {
                    progressMessage = "Fetching photo list..."
                    allImages = try await piwigo.fetchImages(albumID: album.id, perPage: 500)
                }

                let batchImages = currentBatchImages
                let batchOffset = currentBatchIndex * batchSize
                let totalAll = allImages.count
                let albumPath = album.fullPath
                let piwigoRef = piwigo
                let faceManagerRef = faceManager
                let maxConcurrentScan = 10

                let scanInputs = batchImages.enumerated().map { ScanInput(index: $0.offset, image: $0.element) }

                // Results collected here
                var batchItems: [BatchPhotoItem] = batchImages.map {
                    BatchPhotoItem(id: $0.id, image: $0)
                }
                var completed = 0
                let total = Double(batchItems.count)

                await withTaskGroup(of: (Int, Data?, Data?, Date?, String?, [DetectedFace]).self) { group in
                    var nextIdx = 0

                    // Seed initial concurrent tasks
                    for _ in 0..<min(maxConcurrentScan, scanInputs.count) {
                        let input = scanInputs[nextIdx]
                        nextIdx += 1
                        group.addTask {
                            await Self.scanOnePhoto(
                                input: input, piwigoRef: piwigoRef,
                                faceManagerRef: faceManagerRef, albumPath: albumPath
                            )
                        }
                    }

                    for await (index, hiResData, displayData, photoDate, photoLocation, faces) in group {
                        batchItems[index].hiResData = hiResData
                        batchItems[index].displayData = displayData
                        batchItems[index].photoDate = photoDate
                        batchItems[index].photoLocation = photoLocation
                        batchItems[index].detectedFaces = faces
                        batchItems[index].identifiedNames = faces.compactMap(\.matchedName)

                        completed += 1
                        let globalDone = batchOffset + completed
                        await MainActor.run {
                            progress = Double(completed) / total
                            progressMessage = "Scanned \(globalDone)/\(totalAll)..."
                        }

                        if nextIdx < scanInputs.count {
                            let input = scanInputs[nextIdx]
                            nextIdx += 1
                            group.addTask {
                                await Self.scanOnePhoto(
                                    input: input, piwigoRef: piwigoRef,
                                    faceManagerRef: faceManagerRef, albumPath: albumPath
                                )
                            }
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
        progressMessage = "Naming 0/\(items.count)..."

        Task {
            let claude = ClaudeClient(apiKey: claudeAPIKey)
            let total = items.count
            let refs = references.map {
                ClaudeClient.PersonReference(name: $0.name, imageData: $0.imageData)
            }
            let batchOffset = currentBatchIndex * batchSize
            let maxConcurrent = 20

            // Snapshot item data before entering task group
            let inputs: [ItemInput] = items.indices.compactMap { i in
                guard let data = items[i].displayData else { return nil }
                let notes = userNotes.trimmingCharacters(in: .whitespaces)
                return ItemInput(index: i, data: data, names: items[i].identifiedNames, photoDate: items[i].photoDate, photoLocation: items[i].photoLocation, userNotes: notes.isEmpty ? nil : notes)
            }

            var completed = 0

            await withTaskGroup(of: (Int, String).self) { group in
                var nextInputIdx = 0

                // Seed initial concurrent tasks
                for _ in 0..<min(maxConcurrent, inputs.count) {
                    let input = inputs[nextInputIdx]
                    let albumPath = album.fullPath
                    let renamedSoFar = totalRenamed
                    nextInputIdx += 1

                    group.addTask {
                        await Self.generateName(
                            claude: claude, input: input, refs: refs,
                            albumPath: albumPath, renamedSoFar: renamedSoFar
                        )
                    }
                }

                // As each completes, update UI and add the next
                for await (index, result) in group {
                    completed += 1
                    let globalDone = batchOffset + completed
                    await MainActor.run {
                        items[index].suggestedName = result
                        progress = Double(completed) / Double(total)
                        progressMessage = "Named \(globalDone)/\(allImages.count)..."
                    }

                    if nextInputIdx < inputs.count {
                        let input = inputs[nextInputIdx]
                        let albumPath = album.fullPath
                        let renamedSoFar = totalRenamed
                        nextInputIdx += 1

                        group.addTask {
                            await Self.generateName(
                                claude: claude, input: input, refs: refs,
                                albumPath: albumPath, renamedSoFar: renamedSoFar
                            )
                        }
                    }
                }
            }

            await MainActor.run {
                progress = 1.0
                phase = .review
            }
        }
    }

    private struct ScanInput {
        let index: Int
        let image: PiwigoImage
    }

    /// Download, extract date, and detect faces for a single photo.
    private static func scanOnePhoto(
        input: ScanInput,
        piwigoRef: PiwigoClient,
        faceManagerRef: FaceManager,
        albumPath: String
    ) async -> (Int, Data?, Data?, Date?, String?, [DetectedFace]) {
        let img = input.image
        var hiResData: Data?
        var displayData: Data?

        // Download hi-res
        if let url = img.derivatives?.largestURL ?? img.derivatives?.displayURL {
            hiResData = try? await piwigoRef.downloadImage(url: url)
        }
        // Download display
        if let url = img.derivatives?.displayURL {
            displayData = try? await piwigoRef.downloadImage(url: url)
        }

        let exifData = hiResData ?? displayData

        // Compute photo date
        let photoDate = FaceManager.extractPhotoDate(
            imageData: exifData,
            piwigoDateString: img.dateCreation,
            albumPath: albumPath
        )

        // Extract GPS location
        let photoLocation = FaceManager.extractPhotoLocation(imageData: exifData)

        // Detect faces
        var faces: [DetectedFace] = []
        if let data = exifData {
            faces = (try? await faceManagerRef.detectFaces(in: data, photoDate: photoDate)) ?? []
        }

        return (input.index, hiResData, displayData, photoDate, photoLocation, faces)
    }

    private struct ItemInput: Sendable {
        let index: Int
        let data: Data
        let names: [String]
        let photoDate: Date?
        let photoLocation: String?
        let userNotes: String?
    }

    /// Generate a name for a single item with retries. Static so it can run in TaskGroup.
    private static func generateName(
        claude: ClaudeClient,
        input: ItemInput,
        refs: [ClaudeClient.PersonReference],
        albumPath: String,
        renamedSoFar: Int
    ) async -> (Int, String) {
        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                let title = try await claude.describeImageWithReferences(
                    imageData: input.data,
                    peopleNames: input.names,
                    references: refs,
                    albumPath: albumPath,
                    photoDate: nil,
                    photoLocation: input.photoLocation,
                    userNotes: input.userNotes
                )
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd"
                let dateStr = input.photoDate.map { dateFormatter.string(from: $0) } ?? "00000000"
                let seq = String(format: "%03d", renamedSoFar + input.index + 1)
                return (input.index, "\(dateStr) \(seq) \(title)")
            } catch {
                lastError = error
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }

        return (input.index, "[Error: \(lastError?.localizedDescription ?? "Unknown error")]")
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

            let renamed = selected.count - failed

            await MainActor.run {
                totalRenamed += renamed
                progress = 1.0

                if failed > 0 {
                    errorMessage = "\(renamed) renamed, \(failed) failed"
                }

                // Advance to next batch or finish
                let nextBatch = currentBatchIndex + 1
                if nextBatch < totalBatches {
                    currentBatchIndex = nextBatch
                    items = []
                    references = []
                    errorMessage = nil
                    progressMessage = "Batch \(currentBatchIndex) done. Starting next batch..."
                    startScanning()
                } else {
                    progressMessage = "Done! \(totalRenamed) photos renamed across \(totalBatches) batch\(totalBatches == 1 ? "" : "es")."
                    onDone()
                }
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
                .popover(isPresented: $isLabeling) {
                    VStack(spacing: 8) {
                        Text("Label Face")
                            .font(.headline)

                        TextField("Enter name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { submitLabel() }

                        if !faceManager.knownNames.isEmpty {
                            Divider()
                            Text("Known people:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(faceManager.knownNames, id: \.self) { name in
                                        Button {
                                            newName = name
                                            submitLabel()
                                        } label: {
                                            Text(name)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 8)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                        }

                        HStack {
                            Button("Cancel") {
                                isLabeling = false
                                newName = ""
                            }
                            Button("Save") { submitLabel() }
                                .buttonStyle(.borderedProminent)
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding()
                    .frame(minWidth: 200)
                }

            if let name = face.matchedName {
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .lineLimit(1)
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
