import SwiftUI

struct AlbumBrowserView: View {
    @ObservedObject var photoSource: PhotoSource
    let aiAPIKey: String
    let aiProvider: AIProvider
    @ObservedObject var faceManager: FaceManager
    var onDisconnect: () -> Void

    @State private var selectedAlbum: PhotoAlbum?
    @State private var images: [PhotoItem] = []
    @State private var isLoading = false
    @State private var loadingCount: Int = 0
    @State private var selectedImage: PhotoItem?
    @State private var showKnownFaces = false
    @State private var showBatchRename = false

    // Multi-selection for batch rename
    @State private var selectedImageIDs: Set<Int> = []
    @State private var anchorIndex: Int?

    var body: some View {
        NavigationSplitView {
            List(photoSource.albumTree, children: \.children, selection: $selectedAlbum) { album in
                HStack {
                    Image(systemName: album.children != nil ? "folder" : "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(album.name)
                        if album.imageCount > 0 {
                            Text("\(album.imageCount) photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(album)
            }
            .navigationTitle("Albums")
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem {
                    Button {
                        showKnownFaces = true
                    } label: {
                        Label("Known Faces", systemImage: "person.crop.rectangle.stack")
                    }
                }
                ToolbarItem {
                    Button("Disconnect") {
                        onDisconnect()
                    }
                }
            }
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
        } content: {
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(loadingCount > 0 ? "Loading photos... \(loadingCount) found" : "Loading photos...")
                        .foregroundStyle(.secondary)
                }
            } else if images.isEmpty {
                Text("Select an album")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        if selectedImageIDs.count > 1 {
                            Text("\(selectedImageIDs.count) of \(images.count) selected")
                                .foregroundStyle(.secondary)
                            Button("Clear") {
                                selectedImageIDs.removeAll()
                                anchorIndex = nil
                            }
                            .font(.callout)
                        } else {
                            Text("\(images.count) photos")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        batchRenameButton
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                                PhotoThumbnail(
                                    image: image,
                                    photoSource: photoSource,
                                    isSelected: selectedImageIDs.contains(image.id),
                                    isDetailSelected: selectedImage?.id == image.id
                                )
                                .onTapGesture {
                                    handlePhotoTap(index: index, image: image)
                                }
                            }
                        }
                        .padding()
                    }

                    if selectedImageIDs.count > 1 {
                        HStack {
                            Text("Shift-click to select a range. Click to deselect.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }
                }
                .navigationTitle(selectedAlbum?.name ?? "Photos")
                .sheet(isPresented: $showBatchRename) {
                    batchRenameSheet
                }
            }
        } detail: {
            if let image = selectedImage {
                PhotoDetailView(
                    image: image,
                    photoSource: photoSource,
                    aiAPIKey: aiAPIKey,
                    aiProvider: aiProvider,
                    albumPath: selectedAlbum?.fullPath,
                    faceManager: faceManager
                )
            } else {
                Text("Select a photo to rename")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedAlbum) { _, newAlbum in
            if let album = newAlbum {
                loadImages(for: album)
            }
        }
    }

    private var batchRenameButton: some View {
        Button {
            showBatchRename = true
        } label: {
            if selectedImageIDs.count > 1 {
                Label("Batch Rename (\(selectedImageIDs.count))", systemImage: "rectangle.and.pencil.and.ellipsis")
            } else {
                Label("Batch Rename All", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(aiAPIKey.isEmpty)
    }

    @ViewBuilder
    private var batchRenameSheet: some View {
        if let album = selectedAlbum {
            let hasSelection = selectedImageIDs.count > 1
            let preselected: [PhotoItem]? = hasSelection
                ? images.filter { selectedImageIDs.contains($0.id) }
                : nil
            let seqOffset = hasSelection
                ? (images.firstIndex(where: { selectedImageIDs.contains($0.id) }) ?? 0)
                : 0
            BatchRenameView(
                album: album,
                photoSource: photoSource,
                aiAPIKey: aiAPIKey,
                aiProvider: aiProvider,
                faceManager: faceManager,
                preselectedImages: preselected,
                sequenceOffset: seqOffset,
                onDone: { showBatchRename = false }
            )
            .frame(minWidth: 900, minHeight: 700)
        }
    }

    private func handlePhotoTap(index: Int, image: PhotoItem) {
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)

        if shiftHeld, let anchor = anchorIndex {
            // Shift-click: select range from anchor to clicked index
            let lo = min(anchor, index)
            let hi = max(anchor, index)
            for i in lo...hi {
                selectedImageIDs.insert(images[i].id)
            }
        } else {
            // Regular click: set anchor, clear multi-selection, select for detail
            if selectedImageIDs.count > 1 {
                // If we had a multi-selection, clear it
                selectedImageIDs.removeAll()
            }
            anchorIndex = index
            selectedImageIDs = [image.id]
        }

        selectedImage = image
    }

    private func loadImages(for album: PhotoAlbum) {
        isLoading = true
        loadingCount = 0
        selectedImage = nil
        selectedImageIDs.removeAll()
        anchorIndex = nil
        Task {
            do {
                let fetched = try await photoSource.fetchAllImages(albumID: album.id) { count in
                    Task { @MainActor in
                        loadingCount = count
                    }
                }
                await MainActor.run {
                    images = fetched
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

struct PhotoThumbnail: View {
    let image: PhotoItem
    let photoSource: PhotoSource
    var isSelected: Bool = false
    var isDetailSelected: Bool = false
    @State private var thumbnailData: Data?

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                if let data = thumbnailData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 150, height: 150)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 150, height: 150)
                        .cornerRadius(8)
                        .overlay(ProgressView())
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.accentColor).padding(-1))
                        .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : (isDetailSelected ? Color.accentColor.opacity(0.5) : Color.clear),
                        lineWidth: isSelected ? 3 : 2
                    )
            )

            Text(image.displayName)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let url = image.thumbnailURL
        guard !url.isEmpty else { return }
        do {
            let data = try await photoSource.downloadImage(url: url, maxDimension: 300)
            await MainActor.run {
                self.thumbnailData = data
            }
        } catch {}
    }
}
