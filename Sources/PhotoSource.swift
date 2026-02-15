import Foundation
import SwiftUI

// MARK: - Source Type

enum SourceType: String, CaseIterable, Identifiable {
    case piwigo
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .piwigo: return "Piwigo"
        case .local: return "Local Photos"
        }
    }
}

// MARK: - PhotoAlbum

struct PhotoAlbum: Identifiable, Hashable {
    let id: Int
    let name: String
    let parentID: Int?
    let imageCount: Int
    var children: [PhotoAlbum]?
    var fullPath: String = ""

    static func == (lhs: PhotoAlbum, rhs: PhotoAlbum) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - PhotoItem

struct PhotoItem: Identifiable {
    let id: Int
    let filename: String
    let title: String?
    let thumbnailURL: String
    let imageURL: String
    let albumPath: String?
    let dateCreated: String?

    /// Title if set, otherwise filename
    var displayName: String {
        if let title = title, !title.isEmpty, title != filename {
            return title
        }
        return filename
    }
}

// MARK: - PhotoSource

class PhotoSource: ObservableObject {
    @Published var sourceType: SourceType = .piwigo
    @Published var isConnected: Bool = false
    @Published var albumTree: [PhotoAlbum] = []
    @Published var allAlbums: [Int: PhotoAlbum] = [:]
    @Published var error: String?

    private(set) var piwigoClient: PiwigoClient?
    private(set) var localClient: LocalPhotoClient?
    private(set) var securityScopedURL: URL?

    init() {
        // Clients created on demand when connecting
    }

    // MARK: - Connect / Disconnect

    func connectPiwigo(serverURL: String, username: String, password: String) async throws {
        let client = PiwigoClient()
        try await client.login(serverURL: serverURL, username: username, password: password)
        try await client.fetchAlbums()

        let tree = client.albumTree.map { Self.convertAlbum($0) }
        var lookup: [Int: PhotoAlbum] = [:]
        Self.collectAlbums(tree, into: &lookup)

        await MainActor.run {
            self.piwigoClient = client
            self.localClient = nil
            self.sourceType = .piwigo
            self.albumTree = tree
            self.allAlbums = lookup
            self.isConnected = true
            self.error = nil
        }
    }

    func connectLocal(folderURL: URL, securityScoped: Bool = false) async throws {
        let client = LocalPhotoClient(folderURL: folderURL)
        try await client.scanFolder()

        let tree = client.albumTree
        var lookup: [Int: PhotoAlbum] = [:]
        Self.collectAlbums(tree, into: &lookup)

        await MainActor.run {
            // Release any previous security-scoped access
            self.securityScopedURL?.stopAccessingSecurityScopedResource()
            self.securityScopedURL = securityScoped ? folderURL : nil
            self.localClient = client
            self.piwigoClient = nil
            self.sourceType = .local
            self.albumTree = tree
            self.allAlbums = lookup
            self.isConnected = true
            self.error = nil
        }
    }

    func disconnect() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        piwigoClient = nil
        localClient = nil
        albumTree = []
        allAlbums = [:]
        isConnected = false
        error = nil
    }

    // MARK: - Fetch Images

    func fetchImages(albumID: Int) async throws -> [PhotoItem] {
        switch sourceType {
        case .piwigo:
            guard let client = piwigoClient else { throw PhotoSourceError.notConnected }
            let images = try await client.fetchImages(albumID: albumID)
            let albumPath = allAlbums[albumID]?.fullPath
            return images.map { Self.convertImage($0, albumPath: albumPath) }

        case .local:
            guard let client = localClient else { throw PhotoSourceError.notConnected }
            return client.fetchImages(albumID: albumID)
        }
    }

    func fetchAllImages(albumID: Int, onProgress: ((Int) -> Void)? = nil) async throws -> [PhotoItem] {
        switch sourceType {
        case .piwigo:
            guard let client = piwigoClient else { throw PhotoSourceError.notConnected }
            let images = try await client.fetchAllImages(albumID: albumID, onProgress: onProgress)
            let albumPath = allAlbums[albumID]?.fullPath
            return images.map { Self.convertImage($0, albumPath: albumPath) }

        case .local:
            guard let client = localClient else { throw PhotoSourceError.notConnected }
            let items = client.fetchImages(albumID: albumID)
            onProgress?(items.count)
            return items
        }
    }

    // MARK: - Download Image

    /// Download image data, optionally resizing local files to fit within `maxDimension` pixels.
    /// Piwigo URLs already serve pre-sized derivatives so resizing is skipped for HTTP.
    nonisolated func downloadImage(url: String, maxDimension: Int? = nil) async throws -> Data {
        guard let imageURL = URL(string: url) else {
            throw PhotoSourceError.invalidURL
        }

        if imageURL.isFileURL {
            let data = try Data(contentsOf: imageURL)
            if let maxDim = maxDimension {
                return Self.resizeImageData(data, maxDimension: maxDim) ?? data
            }
            return data
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpCookieAcceptPolicy = .always
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config)
            var request = URLRequest(url: imageURL)
            request.timeoutInterval = 30
            let (data, _) = try await session.data(for: request)
            return data
        }
    }

    /// Resize image data so the longest side fits within `maxDimension` pixels.
    /// Returns nil if the image is already small enough or can't be processed.
    private nonisolated static func resizeImageData(_ data: Data, maxDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let longest = max(width, height)

        guard longest > maxDimension else { return nil } // already small enough

        let scale = CGFloat(maxDimension) / CGFloat(longest)
        let newWidth = Int(CGFloat(width) * scale)
        let newHeight = Int(CGFloat(height) * scale)

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = ctx.makeImage() else { return nil }

        // Encode as JPEG
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }

        // Preserve EXIF from original
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        CGImageDestinationAddImage(dest, resized, properties as CFDictionary?)

        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Rename

    func renameImage(id: Int, newTitle: String) async throws {
        switch sourceType {
        case .piwigo:
            guard let client = piwigoClient else { throw PhotoSourceError.notConnected }
            try await client.renameImage(imageID: id, newName: newTitle)

        case .local:
            guard let client = localClient else { throw PhotoSourceError.notConnected }
            try client.renameFile(imageID: id, newTitle: newTitle)
        }
    }

    // MARK: - Conversion helpers

    private static func convertAlbum(_ piwigo: PiwigoAlbum) -> PhotoAlbum {
        var album = PhotoAlbum(
            id: piwigo.id,
            name: piwigo.name,
            parentID: piwigo.parentID,
            imageCount: piwigo.totalImages ?? 0,
            children: piwigo.children?.map { convertAlbum($0) },
            fullPath: piwigo.fullPath
        )
        // Preserve fullPath
        album.fullPath = piwigo.fullPath
        return album
    }

    private static func convertImage(_ piwigo: PiwigoImage, albumPath: String?) -> PhotoItem {
        PhotoItem(
            id: piwigo.id,
            filename: piwigo.file,
            title: piwigo.name,
            thumbnailURL: piwigo.derivatives?.square?.url ?? piwigo.derivatives?.thumb?.url ?? "",
            imageURL: piwigo.derivatives?.largestURL ?? piwigo.derivatives?.displayURL ?? "",
            albumPath: albumPath,
            dateCreated: piwigo.dateCreation
        )
    }

    private static func collectAlbums(_ albums: [PhotoAlbum], into lookup: inout [Int: PhotoAlbum]) {
        for album in albums {
            lookup[album.id] = album
            if let children = album.children {
                collectAlbums(children, into: &lookup)
            }
        }
    }
}

// MARK: - PhotoSource Errors

enum PhotoSourceError: LocalizedError {
    case notConnected
    case invalidURL
    case renameFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to any photo source"
        case .invalidURL: return "Invalid URL"
        case .renameFailed(let msg): return "Rename failed: \(msg)"
        }
    }
}
