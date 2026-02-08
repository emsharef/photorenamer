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
    @State private var selectedImage: PhotoItem?
    @State private var showKnownFaces = false
    @State private var showBatchRename = false

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
                ProgressView("Loading photos...")
            } else if images.isEmpty {
                Text("Select an album")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(selectedAlbum?.imageCount ?? images.count) photos")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showBatchRename = true
                        } label: {
                            Label("Batch Rename", systemImage: "rectangle.and.pencil.and.ellipsis")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(aiAPIKey.isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                            ForEach(images) { image in
                                PhotoThumbnail(image: image, photoSource: photoSource)
                                    .onTapGesture {
                                        selectedImage = image
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedImage?.id == image.id ? Color.accentColor : Color.clear, lineWidth: 3)
                                    )
                            }
                        }
                        .padding()
                    }
                }
                .navigationTitle(selectedAlbum?.name ?? "Photos")
                .sheet(isPresented: $showBatchRename) {
                    if let album = selectedAlbum {
                        BatchRenameView(
                            album: album,
                            photoSource: photoSource,
                            aiAPIKey: aiAPIKey,
                            aiProvider: aiProvider,
                            faceManager: faceManager,
                            onDone: { showBatchRename = false }
                        )
                        .frame(minWidth: 900, minHeight: 700)
                    }
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

    private func loadImages(for album: PhotoAlbum) {
        isLoading = true
        selectedImage = nil
        Task {
            do {
                let fetched = try await photoSource.fetchImages(albumID: album.id)
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
    @State private var thumbnailData: Data?

    var body: some View {
        VStack {
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
