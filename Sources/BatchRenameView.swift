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
    let image: PhotoItem
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
    let album: PhotoAlbum
    @ObservedObject var photoSource: PhotoSource
    let aiAPIKey: String
    let aiProvider: AIProvider
    @ObservedObject var faceManager: FaceManager
    var preselectedImages: [PhotoItem]? = nil
    var sequenceOffset: Int = 0
    var onDone: () -> Void

    @AppStorage("namingFormat") private var namingFormat: String = NamingFormat.defaultTemplate

    @State private var phase: BatchPhase = .idle
    @State private var items: [BatchPhotoItem] = []
    @State private var references: [PersonReferencePhoto] = []
    @State private var progress: Double = 0
    @State private var progressMessage: String = ""
    @State private var errorMessage: String?
    @State private var userNotes: String = ""
    @State private var retryNotes: String = ""
    @State private var isRetrying = false

    // Batch pagination
    @State private var allImages: [PhotoItem] = []
    @State private var currentBatchIndex: Int = 0
    @State private var totalRenamed: Int = 0
    private let batchSize = 50

    private var totalBatches: Int {
        guard !allImages.isEmpty else { return 0 }
        return (allImages.count + batchSize - 1) / batchSize
    }

    private var currentBatchImages: [PhotoItem] {
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
            if let preselected = preselectedImages {
                Text("This will scan \(preselected.count) selected photos in \"\(album.name)\", detect faces, generate AI names, and let you review before applying.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .foregroundStyle(.secondary)
            } else {
                Text("This will scan all photos in \"\(album.name)\" in batches of \(batchSize), detect faces, generate AI names, and let you review before applying each batch.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .foregroundStyle(.secondary)
            }
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
                if currentBatchIndex + 1 < totalBatches {
                    Button("Skip to Next Batch") {
                        skipToNextBatch()
                    }
                }
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
            // Retry bar
            HStack(spacing: 8) {
                TextField("Additional context for retry (e.g., 'this is a birthday party')", text: $retryNotes)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                Button {
                    retrySelected()
                } label: {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Retry Selected", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRetrying || items.filter(\.isSelected).isEmpty)
            }
            .padding(.horizontal)

            // Action bar
            HStack {
                Button(items.allSatisfy(\.isSelected) ? "Select None" : "Select All") {
                    let newValue = !items.allSatisfy(\.isSelected)
                    for i in items.indices { items[i].isSelected = newValue }
                }
                .font(.callout)

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
                .disabled(isRetrying || items.filter(\.isSelected).allSatisfy { $0.suggestedName.isEmpty })
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
                    if let preselected = preselectedImages {
                        allImages = preselected
                        progressMessage = "\(preselected.count) selected photos"
                    } else {
                        progressMessage = "Fetching photo list..."
                        let fetched = try await photoSource.fetchAllImages(albumID: album.id) { count in
                            Task { @MainActor in
                                self.progressMessage = "Fetching photo list... \(count) found"
                            }
                        }
                        allImages = fetched
                        progressMessage = "Fetching photo list... \(fetched.count) photos"
                    }
                }

                let batchImages = currentBatchImages
                let batchOffset = currentBatchIndex * batchSize
                let totalAll = allImages.count
                progressMessage = "Scanning 0/\(totalAll)..."

                let batchItems = await batchScanPhotos(
                    images: batchImages,
                    photoSourceRef: photoSource,
                    faceManagerRef: faceManager,
                    albumPath: album.fullPath,
                    batchOffset: batchOffset,
                    totalAll: totalAll
                ) { progressVal, message in
                    self.progress = progressVal
                    self.progressMessage = message
                }

                items = batchItems
                progress = 1.0
                buildInitialReferences()
                phase = .faceReview
            } catch {
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    // MARK: - Build references

    private func buildInitialReferences() {
        var refsByName: [String: PersonReferencePhoto] = [:]

        for item in items {
            for face in item.detectedFaces {
                guard let name = face.matchedName else { continue }
                let faceArea = face.boundingBox.width * face.boundingBox.height

                if let existing = refsByName[name] {
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

        let client = AIClient(provider: aiProvider, apiKey: aiAPIKey)
        let refs = references.map {
            AIClient.PersonReference(name: $0.name, imageData: $0.imageData)
        }
        let batchOffset = currentBatchIndex * batchSize
        let albumPath = album.fullPath
        let seqOffset = sequenceOffset
        let renamedSoFar = totalRenamed
        let totalImages = allImages.count
        let notes = userNotes.trimmingCharacters(in: .whitespaces)
        let format = namingFormat

        let inputs: [ItemInput] = items.indices.compactMap { i in
            guard let data = items[i].displayData else { return nil }
            let fname = items[i].image.filename
            let orig = fname.contains(".") ? String(fname[fname.startIndex..<fname.lastIndex(of: ".")!]) : fname
            return ItemInput(index: i, data: data, names: items[i].identifiedNames, photoDate: items[i].photoDate, photoLocation: items[i].photoLocation, userNotes: notes.isEmpty ? nil : notes, originalFilename: orig)
        }

        Task {
            let total = inputs.count
            let maxConcurrent = 10
            var completed = 0

            await withTaskGroup(of: (Int, String).self) { group in
                var nextInputIdx = 0

                for _ in 0..<min(maxConcurrent, inputs.count) {
                    let input = inputs[nextInputIdx]
                    nextInputIdx += 1

                    group.addTask {
                        await generatePhotoName(
                            client: client, input: input, refs: refs,
                            albumPath: albumPath, sequenceOffset: seqOffset,
                            renamedSoFar: renamedSoFar, namingFormat: format
                        )
                    }
                }

                for await (index, result) in group {
                    completed += 1
                    let globalDone = batchOffset + completed
                    items[index].suggestedName = result
                    progress = Double(completed) / Double(total)
                    progressMessage = "Named \(globalDone)/\(totalImages)..."

                    if nextInputIdx < inputs.count {
                        let input = inputs[nextInputIdx]
                        nextInputIdx += 1

                        group.addTask {
                            await generatePhotoName(
                                client: client, input: input, refs: refs,
                                albumPath: albumPath, sequenceOffset: seqOffset,
                                renamedSoFar: renamedSoFar, namingFormat: format
                            )
                        }
                    }
                }
            }

            progress = 1.0
            phase = .review
        }
    }

    // MARK: - Retry selected names

    private func retrySelected() {
        let selectedIndices = items.indices.filter { items[$0].isSelected }
        guard !selectedIndices.isEmpty else { return }

        isRetrying = true
        errorMessage = nil

        let refs = references.map {
            AIClient.PersonReference(name: $0.name, imageData: $0.imageData)
        }
        let albumPath = album.fullPath
        let seqOffset = sequenceOffset
        let renamedSoFar = totalRenamed
        let format = namingFormat
        let combinedNotes = [userNotes, retryNotes]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")

        let inputs: [ItemInput] = selectedIndices.compactMap { i in
            guard let data = items[i].displayData else { return nil }
            let fname = items[i].image.filename
            let orig = fname.contains(".") ? String(fname[fname.startIndex..<fname.lastIndex(of: ".")!]) : fname
            return ItemInput(
                index: i, data: data, names: items[i].identifiedNames,
                photoDate: items[i].photoDate, photoLocation: items[i].photoLocation,
                userNotes: combinedNotes.isEmpty ? nil : combinedNotes,
                originalFilename: orig
            )
        }

        Task {
            let client = AIClient(provider: aiProvider, apiKey: aiAPIKey)
            let total = inputs.count
            let maxConcurrent = 10
            var completed = 0

            await withTaskGroup(of: (Int, String).self) { group in
                var nextInputIdx = 0

                for _ in 0..<min(maxConcurrent, inputs.count) {
                    let input = inputs[nextInputIdx]
                    nextInputIdx += 1
                    group.addTask {
                        await generatePhotoName(
                            client: client, input: input, refs: refs,
                            albumPath: albumPath, sequenceOffset: seqOffset,
                            renamedSoFar: renamedSoFar, namingFormat: format
                        )
                    }
                }

                for await (index, result) in group {
                    completed += 1
                    items[index].suggestedName = result
                    progressMessage = "Retrying \(completed)/\(total)..."

                    if nextInputIdx < inputs.count {
                        let input = inputs[nextInputIdx]
                        nextInputIdx += 1
                        group.addTask {
                            await generatePhotoName(
                                client: client, input: input, refs: refs,
                                albumPath: albumPath, sequenceOffset: seqOffset,
                                renamedSoFar: renamedSoFar, namingFormat: format
                            )
                        }
                    }
                }
            }

            isRetrying = false
            progressMessage = "Retry complete — \(total) names regenerated"
        }
    }

    // MARK: - Skip batch

    private func skipToNextBatch() {
        currentBatchIndex += 1
        items = []
        references = []
        errorMessage = nil
        startScanning()
    }

    // MARK: - Phase 4: Apply

    private func applyRenames() {
        let selected = items.filter { $0.isSelected && !$0.suggestedName.isEmpty }
        guard !selected.isEmpty else { return }

        phase = .generating
        progress = 0
        progressMessage = "Applying renames..."

        let renameItems = selected.map { (id: $0.id, name: $0.suggestedName) }

        Task {
            let total = renameItems.count
            let maxConcurrent = 10
            var completed = 0
            var failed = 0

            await withTaskGroup(of: Bool.self) { group in
                var nextIdx = 0

                for _ in 0..<min(maxConcurrent, renameItems.count) {
                    let item = renameItems[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        do {
                            try await photoSource.renameImage(id: item.id, newTitle: item.name)
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                for await success in group {
                    completed += 1
                    if !success { failed += 1 }
                    progress = Double(completed) / Double(total)
                    progressMessage = "Renaming \(completed)/\(total)..."

                    if nextIdx < renameItems.count {
                        let item = renameItems[nextIdx]
                        nextIdx += 1
                        group.addTask {
                            do {
                                try await photoSource.renameImage(id: item.id, newTitle: item.name)
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                }
            }

            let renamed = total - failed
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

// MARK: - File-level scan/generate functions (outside View to avoid @MainActor inheritance)

private struct ScanInput {
    let index: Int
    let image: PhotoItem
}

private struct ItemInput: Sendable {
    let index: Int
    let data: Data
    let names: [String]
    let photoDate: Date?
    let photoLocation: String?
    let userNotes: String?
    let originalFilename: String
}

private func batchScanPhotos(
    images: [PhotoItem],
    photoSourceRef: PhotoSource,
    faceManagerRef: FaceManager,
    albumPath: String,
    batchOffset: Int,
    totalAll: Int,
    onProgress: @escaping @MainActor @Sendable (Double, String) -> Void
) async -> [BatchPhotoItem] {
    var batchItems = images.map { BatchPhotoItem(id: $0.id, image: $0) }
    var completed = 0
    let total = Double(batchItems.count)
    let maxConcurrentScan = 10
    let scanInputs = images.enumerated().map { ScanInput(index: $0.offset, image: $0.element) }

    await withTaskGroup(of: (Int, Data?, Data?, Date?, String?, [DetectedFace]).self) { group in
        var nextIdx = 0

        for _ in 0..<min(maxConcurrentScan, scanInputs.count) {
            let input = scanInputs[nextIdx]
            nextIdx += 1
            group.addTask {
                let result = await scanOnePhoto(
                    input: input, photoSourceRef: photoSourceRef,
                    faceManagerRef: faceManagerRef, albumPath: albumPath
                )
                return result
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
            let progressVal = Double(completed) / total
            let message = "Scanned \(globalDone)/\(totalAll)..."
            await onProgress(progressVal, message)

            if nextIdx < scanInputs.count {
                let input = scanInputs[nextIdx]
                nextIdx += 1
                group.addTask {
                    await scanOnePhoto(
                        input: input, photoSourceRef: photoSourceRef,
                        faceManagerRef: faceManagerRef, albumPath: albumPath
                    )
                }
            }
        }
    }

    return batchItems
}

private func scanOnePhoto(
    input: ScanInput,
    photoSourceRef: PhotoSource,
    faceManagerRef: FaceManager,
    albumPath: String
) async -> (Int, Data?, Data?, Date?, String?, [DetectedFace]) {
    let img = input.image
    var hiResData: Data?
    var displayData: Data?

    // Download image data (resize local files to reasonable sizes)
    let imageURL = img.imageURL
    if !imageURL.isEmpty {
        hiResData = try? await photoSourceRef.downloadImage(url: imageURL, maxDimension: 1600)
    }

    // For Piwigo, thumbnail is a smaller version; for local, it's the same file
    let thumbURL = img.thumbnailURL
    if !thumbURL.isEmpty && thumbURL != imageURL {
        displayData = try? await photoSourceRef.downloadImage(url: thumbURL)
    } else {
        displayData = hiResData
    }

    let exifData = hiResData ?? displayData

    let photoDate = FaceManager.extractPhotoDate(
        imageData: exifData,
        piwigoDateString: img.dateCreated,
        albumPath: albumPath
    )

    let photoLocation = FaceManager.extractPhotoLocation(imageData: exifData)

    var faces: [DetectedFace] = []
    if let data = exifData {
        faces = (try? await faceManagerRef.detectFaces(in: data, photoDate: photoDate)) ?? []
    }

    return (input.index, hiResData, displayData, photoDate, photoLocation, faces)
}

private func generatePhotoName(
    client: AIClient,
    input: ItemInput,
    refs: [AIClient.PersonReference],
    albumPath: String,
    sequenceOffset: Int,
    renamedSoFar: Int,
    namingFormat: String
) async -> (Int, String) {
    let maxRetries = 5
    var lastError: Error?

    for attempt in 1...maxRetries {
        do {
            let rawTitle = try await client.describeImageWithReferences(
                imageData: input.data,
                peopleNames: input.names,
                references: refs,
                albumPath: albumPath,
                photoDate: nil,
                photoLocation: input.photoLocation,
                userNotes: input.userNotes
            )
            let seqNum = sequenceOffset + renamedSoFar + input.index + 1
            let albumName = albumPath.components(separatedBy: "/").last
            let formatted = NamingFormat.apply(
                template: namingFormat,
                date: input.photoDate,
                seq: seqNum,
                title: rawTitle,
                people: input.names,
                album: albumName,
                original: input.originalFilename,
                location: input.photoLocation
            )
            return (input.index, formatted)
        } catch {
            lastError = error
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    return (input.index, "[Error: \(lastError?.localizedDescription ?? "Unknown error")]")
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
                    if face.isAmbiguous && !face.ambiguousNames.isEmpty {
                        ForEach(face.ambiguousNames, id: \.self) { name in
                            Button("⭐ " + name) { onLabeled(name) }
                        }
                        Divider()
                    }
                    let suggested = Set(face.ambiguousNames)
                    ForEach(faceManager.knownNames.filter { !suggested.contains($0) }, id: \.self) { name in
                        Button(name) { onLabeled(name) }
                    }
                    if !faceManager.knownNames.isEmpty {
                        Divider()
                    }
                    Button("New name...") { showNewName = true }
                } label: {
                    Text(face.isAmbiguous ? "Uncertain" : "Label")
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
