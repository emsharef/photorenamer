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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review detected faces")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(uniqueIdentifiedNames.count) people identified across \(items.count) photos")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    buildReferencesAndGenerate()
                } label: {
                    Label("Continue to Naming", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reference photos")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(references) { ref in
                                VStack(spacing: 4) {
                                    if let nsImage = NSImage(data: ref.imageData) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 56, height: 56)
                                            .clipShape(Circle())
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                                            )
                                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    }
                                    Text(ref.name)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            // List of photos with face results (List uses NSTableView — clicks always work)
            List {
                ForEach($items) { $item in
                    BatchFaceRow(
                        item: $item,
                        faceManager: faceManager,
                        albumPath: album.fullPath
                    )
                }
            }
            .listStyle(.plain)
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

        // Capture everything needed before detaching from MainActor
        let piwigoRef = piwigo
        let faceManagerRef = faceManager
        let albumID = album.id
        let albumPath = album.fullPath
        let needsFetch = allImages.isEmpty
        let batchIdx = currentBatchIndex
        let batchSz = batchSize

        Task.detached {
            do {
                // Fetch full image list on first batch
                var fetchedImages: [PiwigoImage] = []
                if needsFetch {
                    await MainActor.run {
                        self.progressMessage = "Fetching photo list..."
                    }
                    fetchedImages = try await piwigoRef.fetchAllImages(albumID: albumID) { count in
                        Task { @MainActor in
                            self.progressMessage = "Fetching photo list... \(count) found"
                        }
                    }
                    await MainActor.run {
                        self.allImages = fetchedImages
                        self.progressMessage = "Fetching photo list... \(fetchedImages.count) photos"
                    }
                }

                let (batchImages, batchOffset, totalAll): ([PiwigoImage], Int, Int) = await MainActor.run {
                    let start = batchIdx * batchSz
                    let end = min(start + batchSz, self.allImages.count)
                    let slice = start < self.allImages.count ? Array(self.allImages[start..<end]) : []
                    return (slice, batchIdx * batchSz, self.allImages.count)
                }

                await MainActor.run {
                    self.progressMessage = "Scanning 0/\(totalAll)..."
                }

                let maxConcurrentScan = 10
                let scanInputs = batchImages.enumerated().map { ScanInput(index: $0.offset, image: $0.element) }

                var batchItems: [BatchPhotoItem] = batchImages.map {
                    BatchPhotoItem(id: $0.id, image: $0)
                }
                var completed = 0
                let total = Double(batchItems.count)

                await withTaskGroup(of: (Int, Data?, Data?, Date?, String?, [DetectedFace]).self) { group in
                    var nextIdx = 0

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
                            self.progress = Double(completed) / total
                            self.progressMessage = "Scanned \(globalDone)/\(totalAll)..."
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

                let finalItems = batchItems
                await MainActor.run {
                    self.items = finalItems
                    self.progress = 1.0
                    self.buildInitialReferences()
                    self.phase = .faceReview
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.phase = .idle
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

        // Capture everything needed before detaching from MainActor
        let apiKey = claudeAPIKey
        let refs = references.map {
            ClaudeClient.PersonReference(name: $0.name, imageData: $0.imageData)
        }
        let batchOffset = currentBatchIndex * batchSize
        let albumPath = album.fullPath
        let renamedSoFar = totalRenamed
        let totalImages = allImages.count
        let notes = userNotes.trimmingCharacters(in: .whitespaces)

        let inputs: [ItemInput] = items.indices.compactMap { i in
            guard let data = items[i].displayData else { return nil }
            return ItemInput(index: i, data: data, names: items[i].identifiedNames, photoDate: items[i].photoDate, photoLocation: items[i].photoLocation, userNotes: notes.isEmpty ? nil : notes)
        }

        Task.detached {
            let claude = ClaudeClient(apiKey: apiKey)
            let total = inputs.count
            let maxConcurrent = 10
            var completed = 0

            var results: [(Int, String)] = []

            await withTaskGroup(of: (Int, String).self) { group in
                var nextInputIdx = 0

                for _ in 0..<min(maxConcurrent, inputs.count) {
                    let input = inputs[nextInputIdx]
                    nextInputIdx += 1

                    group.addTask {
                        await Self.generateName(
                            claude: claude, input: input, refs: refs,
                            albumPath: albumPath, renamedSoFar: renamedSoFar
                        )
                    }
                }

                for await (index, result) in group {
                    results.append((index, result))
                    completed += 1
                    let globalDone = batchOffset + completed
                    await MainActor.run {
                        self.items[index].suggestedName = result
                        self.progress = Double(completed) / Double(total)
                        self.progressMessage = "Named \(globalDone)/\(totalImages)..."
                    }

                    if nextInputIdx < inputs.count {
                        let input = inputs[nextInputIdx]
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
                self.progress = 1.0
                self.phase = .review
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
        let maxRetries = 5
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

        let piwigoRef = piwigo
        let renameItems = selected.map { (id: $0.id, name: $0.suggestedName) }

        Task.detached {
            let total = Double(renameItems.count)
            var failed = 0

            for (i, item) in renameItems.enumerated() {
                await MainActor.run {
                    self.progress = Double(i) / total
                    self.progressMessage = "Renaming \(i + 1)/\(Int(total))..."
                }

                do {
                    try await piwigoRef.renameImage(imageID: item.id, newName: item.name)
                } catch {
                    failed += 1
                }
            }

            let renamed = renameItems.count - failed

            await MainActor.run {
                self.totalRenamed += renamed
                self.progress = 1.0

                if failed > 0 {
                    self.errorMessage = "\(renamed) renamed, \(failed) failed"
                }

                // Advance to next batch or finish
                let nextBatch = self.currentBatchIndex + 1
                if nextBatch < self.totalBatches {
                    self.currentBatchIndex = nextBatch
                    self.items = []
                    self.references = []
                    self.errorMessage = nil
                    self.progressMessage = "Batch \(self.currentBatchIndex) done. Starting next batch..."
                    self.startScanning()
                } else {
                    self.progressMessage = "Done! \(self.totalRenamed) photos renamed across \(self.totalBatches) batch\(self.totalBatches == 1 ? "" : "es")."
                    self.onDone()
                }
            }
        }
    }
}

// MARK: - Face card for batch review

struct BatchFaceRow: View {
    @Binding var item: BatchPhotoItem
    @ObservedObject var faceManager: FaceManager
    let albumPath: String

    private var allIdentified: Bool {
        !item.detectedFaces.isEmpty && item.detectedFaces.allSatisfy { $0.matchedName != nil }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail with status indicator
            ZStack(alignment: .bottomTrailing) {
                if let data = item.displayData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 90, height: 90)
                        .clipped()
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                }

                // Status badge
                if allIdentified {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                        .background(Circle().fill(.white).padding(2))
                        .offset(x: 4, y: 4)
                } else if item.detectedFaces.contains(where: { $0.matchedName == nil }) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.white).padding(2))
                        .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.image.displayName)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.detectedFaces.isEmpty {
                    Label("No faces detected", systemImage: "person.slash")
                        .font(.caption)
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

            Spacer()
        }
        .padding(.vertical, 6)
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

    @State private var showNewName = false
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

            if let name = face.matchedName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Menu {
                    ForEach(faceManager.knownNames, id: \.self) { name in
                        Button(name) { onLabeled(name) }
                    }
                    if !faceManager.knownNames.isEmpty {
                        Divider()
                    }
                    Button("New name...") { showNewName = true }
                } label: {
                    Text("Label")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
        .popover(isPresented: $showNewName) {
            VStack(spacing: 8) {
                Text("New Name")
                    .font(.headline)
                TextField("Enter name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { submitNewName() }
                HStack {
                    Button("Cancel") {
                        showNewName = false
                        newName = ""
                    }
                    Button("Save") { submitNewName() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func submitNewName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onLabeled(name)
        showNewName = false
        newName = ""
    }
}
