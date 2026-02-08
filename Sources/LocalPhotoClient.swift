import Foundation
import ImageIO
import UniformTypeIdentifiers

class LocalPhotoClient {
    let folderURL: URL
    private(set) var albumTree: [PhotoAlbum] = []
    private var imagesByAlbum: [Int: [PhotoItem]] = [:]
    private var imagePathByID: [Int: URL] = [:]

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "tif"]

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    // MARK: - Folder Scanning

    func scanFolder() async throws {
        let fm = FileManager.default

        // Map relative path to album ID via stable hash
        var albumsByPath: [String: PhotoAlbum] = [:]
        var imagesByAlbumID: [Int: [PhotoItem]] = [:]
        var pathByID: [Int: URL] = [:]

        // Root album
        let rootID = stableHash("")
        let rootImages = scanImages(in: folderURL, albumID: rootID, albumPath: folderURL.lastPathComponent)
        for img in rootImages {
            if let url = URL(string: img.imageURL) {
                pathByID[img.id] = url
            }
        }
        imagesByAlbumID[rootID] = rootImages

        let rootAlbum = PhotoAlbum(
            id: rootID,
            name: folderURL.lastPathComponent,
            parentID: nil,
            imageCount: rootImages.count,
            children: [],
            fullPath: folderURL.lastPathComponent
        )

        albumsByPath[""] = rootAlbum

        // Enumerate subfolders
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PhotoSourceError.renameFailed("Cannot enumerate folder")
        }

        var subfolderPaths: [String] = []
        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            let relativePath = url.path.replacingOccurrences(of: folderURL.path + "/", with: "")
            subfolderPaths.append(relativePath)
        }

        // Sort so parents come before children
        subfolderPaths.sort()

        for relativePath in subfolderPaths {
            let fullURL = folderURL.appendingPathComponent(relativePath)
            let albumID = stableHash(relativePath)
            let albumName = fullURL.lastPathComponent
            let fullPath = folderURL.lastPathComponent + " / " + relativePath.replacingOccurrences(of: "/", with: " / ")

            // Determine parent
            let parentRelative = (relativePath as NSString).deletingLastPathComponent
            let parentID: Int
            if parentRelative.isEmpty || parentRelative == "." {
                parentID = rootID
            } else {
                parentID = stableHash(parentRelative)
            }

            let images = scanImages(in: fullURL, albumID: albumID, albumPath: fullPath)
            for img in images {
                if let url = URL(string: img.imageURL) {
                    pathByID[img.id] = url
                }
            }
            imagesByAlbumID[albumID] = images

            let album = PhotoAlbum(
                id: albumID,
                name: albumName,
                parentID: parentID,
                imageCount: images.count,
                children: [],
                fullPath: fullPath
            )
            albumsByPath[relativePath] = album
        }

        // Build tree: attach children to parents
        for (relativePath, album) in albumsByPath where !relativePath.isEmpty {
            let parentRelative = (relativePath as NSString).deletingLastPathComponent
            let parentKey = (parentRelative.isEmpty || parentRelative == ".") ? "" : parentRelative
            albumsByPath[parentKey]?.children?.append(album)
        }

        // Sort children alphabetically
        for key in albumsByPath.keys {
            albumsByPath[key]?.children?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        // Resolve tree from root
        let resolvedRoot = resolveChildren(for: albumsByPath[""]!, allAlbums: albumsByPath)
        let tree = [resolvedRoot]

        await MainActor.run {
            self.albumTree = tree
            self.imagesByAlbum = imagesByAlbumID
            self.imagePathByID = pathByID
        }
    }

    private func resolveChildren(for album: PhotoAlbum, allAlbums: [String: PhotoAlbum]) -> PhotoAlbum {
        var result = album
        if let children = result.children {
            result.children = children.map { child in
                // Find the child's relative path key
                let childKey = allAlbums.first(where: { $0.value.id == child.id })?.key ?? ""
                let resolved = allAlbums[childKey] ?? child
                return resolveChildren(for: resolved, allAlbums: allAlbums)
            }
        }
        return result
    }

    // MARK: - Fetch Images

    func fetchImages(albumID: Int) -> [PhotoItem] {
        imagesByAlbum[albumID] ?? []
    }

    // MARK: - Rename

    func renameFile(imageID: Int, newTitle: String) throws {
        guard let fileURL = imagePathByID[imageID] else {
            throw PhotoSourceError.renameFailed("File not found for image ID \(imageID)")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            throw PhotoSourceError.renameFailed("File does not exist: \(fileURL.path)")
        }

        let directory = fileURL.deletingLastPathComponent()
        let ext = fileURL.pathExtension

        // Sanitize filename
        let sanitized = sanitizeFilename(newTitle)
        var newFilename = sanitized + "." + ext
        var targetURL = directory.appendingPathComponent(newFilename)

        // Handle collisions
        if fm.fileExists(atPath: targetURL.path) && targetURL != fileURL {
            var counter = 2
            while fm.fileExists(atPath: targetURL.path) && targetURL != fileURL {
                newFilename = "\(sanitized)_\(counter).\(ext)"
                targetURL = directory.appendingPathComponent(newFilename)
                counter += 1
            }
        }

        // Rename file
        if targetURL != fileURL {
            try fm.moveItem(at: fileURL, to: targetURL)
        }

        // Update IPTC title
        try updateIPTCTitle(at: targetURL, title: newTitle)

        // Update internal state
        imagePathByID[imageID] = targetURL

        // Update the PhotoItem in imagesByAlbum
        for albumID in imagesByAlbum.keys {
            if let idx = imagesByAlbum[albumID]?.firstIndex(where: { $0.id == imageID }) {
                let old = imagesByAlbum[albumID]![idx]
                let fileURLString = targetURL.absoluteString
                imagesByAlbum[albumID]![idx] = PhotoItem(
                    id: imageID,
                    filename: targetURL.lastPathComponent,
                    title: newTitle,
                    thumbnailURL: fileURLString,
                    imageURL: fileURLString,
                    albumPath: old.albumPath,
                    dateCreated: old.dateCreated
                )
            }
        }
    }

    // MARK: - Private Helpers

    private func scanImages(in directoryURL: URL, albumID: Int, albumPath: String) -> [PhotoItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [PhotoItem] = []
        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { continue }

            let imageID = stableHash(url.path)
            let fileURLString = url.absoluteString
            let dateCreated = extractDateCreated(from: url)

            let item = PhotoItem(
                id: imageID,
                filename: url.lastPathComponent,
                title: nil,
                thumbnailURL: fileURLString,
                imageURL: fileURLString,
                albumPath: albumPath,
                dateCreated: dateCreated
            )
            items.append(item)
        }

        // Sort by filename
        items.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        return items
    }

    private func extractDateCreated(from fileURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        else { return nil }

        // Convert EXIF format "yyyy:MM:dd HH:mm:ss" to "yyyy-MM-dd HH:mm:ss"
        return dateString.replacingOccurrences(of: ":", with: "-", options: [], range: dateString.startIndex..<dateString.index(dateString.startIndex, offsetBy: min(10, dateString.count)))
    }

    private func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?*\"<>|")
        var sanitized = name.components(separatedBy: unsafe).joined(separator: "-")
        // Trim whitespace and dots from start/end
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if sanitized.isEmpty {
            sanitized = "untitled"
        }
        return sanitized
    }

    private func updateIPTCTitle(at fileURL: URL, title: String) throws {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return
        }

        let type = CGImageSourceGetType(source)
        guard let uti = type else { return }

        // Read existing properties
        let existingProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // Build updated IPTC dictionary
        var iptc = existingProperties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        iptc[kCGImagePropertyIPTCObjectName as String] = title

        // Build updated properties
        var updatedProperties = existingProperties
        updatedProperties[kCGImagePropertyIPTCDictionary as String] = iptc

        // Write to a temporary file then replace
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString).\(fileURL.pathExtension)")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, uti, 1, nil
        ) else { return }

        CGImageDestinationAddImageFromSource(destination, source, 0, updatedProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Replace original with updated file
        let fm = FileManager.default
        try fm.removeItem(at: fileURL)
        try fm.moveItem(at: tempURL, to: fileURL)
    }

    /// Produce a stable, positive Int hash from a string path
    private func stableHash(_ path: String) -> Int {
        var hasher = Hasher()
        hasher.combine(path)
        let hash = hasher.finalize()
        return abs(hash)
    }
}
