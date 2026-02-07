import Foundation

struct PiwigoAlbum: Identifiable {
    let id: Int
    let name: String
    let parentID: Int?
    let totalImages: Int?
    var children: [PiwigoAlbum]?

    /// Full path from root, e.g. "Vacations / Summer 2024 / Beach"
    var fullPath: String = ""
}

struct PiwigoImage: Identifiable, Codable {
    let id: Int
    let file: String
    let name: String?
    let pageURL: String?
    let dateCreation: String?
    let derivatives: PiwigoDerivatives?

    /// Title if set, otherwise filename
    var displayName: String {
        if let name = name, !name.isEmpty, name != file {
            return name
        }
        return file
    }

    enum CodingKeys: String, CodingKey {
        case id
        case file
        case name
        case pageURL = "page_url"
        case dateCreation = "date_creation"
        case derivatives
    }
}

struct PiwigoDerivatives: Codable {
    let square: PiwigoDerivative?
    let thumb: PiwigoDerivative?
    let medium: PiwigoDerivative?
    let large: PiwigoDerivative?
    let xlarge: PiwigoDerivative?
    let xxlarge: PiwigoDerivative?

    /// Largest available derivative URL (best for face detection)
    var largestURL: String? {
        xxlarge?.url ?? xlarge?.url ?? large?.url ?? medium?.url
    }

    /// Medium-sized URL (good for display)
    var displayURL: String? {
        medium?.url ?? large?.url ?? thumb?.url
    }
}

struct PiwigoDerivative: Codable {
    let url: String
}

class PiwigoClient: ObservableObject {
    @Published var isLoggedIn = false
    @Published var albumTree: [PiwigoAlbum] = []
    @Published var allAlbums: [Int: PiwigoAlbum] = [:]
    @Published var error: String?

    private var baseURL: String = ""
    private var session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    private func apiURL() -> URL {
        URL(string: "\(baseURL)/ws.php?format=json")!
    }

    func login(serverURL: String, username: String, password: String) async throws {
        baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var request = URLRequest(url: apiURL())
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "method=pwg.session.login&username=\(urlEncode(username))&password=\(urlEncode(password))"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let stat = json?["stat"] as? String, stat == "ok" {
            await MainActor.run {
                self.isLoggedIn = true
                self.error = nil
            }
        } else {
            let message = json?["message"] as? String ?? "Login failed"
            throw PiwigoError.loginFailed(message)
        }
    }

    func fetchAlbums() async throws {
        var request = URLRequest(url: apiURL())
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "method=pwg.categories.getList&recursive=true".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let result = json?["result"] as? [String: Any],
              let categoriesRaw = result["categories"] as? [[String: Any]] else {
            throw PiwigoError.parseFailed
        }

        // Parse flat list with parent IDs
        var flatAlbums: [PiwigoAlbum] = []
        for cat in categoriesRaw {
            guard let id = cat["id"] as? Int,
                  let name = cat["name"] as? String else { continue }
            let nbImages = (cat["nb_images"] as? Int) ?? (cat["nb_images"] as? String).flatMap { Int($0) }
            let parentID: Int? = {
                if let intVal = cat["id_uppercat"] as? Int { return intVal }
                if let strVal = cat["id_uppercat"] as? String { return Int(strVal) }
                return nil
            }()
            flatAlbums.append(PiwigoAlbum(
                id: id, name: name, parentID: parentID, totalImages: nbImages
            ))
        }

        // Build lookup
        var lookup: [Int: PiwigoAlbum] = [:]
        for album in flatAlbums {
            lookup[album.id] = album
        }

        // Compute full paths
        for album in flatAlbums {
            let path = buildFullPath(albumID: album.id, lookup: lookup)
            lookup[album.id]?.fullPath = path
        }

        // Figure out which albums are parents (have children)
        var parentIDs: Set<Int> = []
        for album in flatAlbums {
            if let pid = album.parentID {
                parentIDs.insert(pid)
            }
        }

        // Initialize children arrays for parent albums
        for id in parentIDs {
            lookup[id]?.children = []
        }

        // Nest children under parents
        var roots: [PiwigoAlbum] = []
        for album in flatAlbums {
            if let parentID = album.parentID, lookup[parentID] != nil {
                let child = lookup[album.id]!
                lookup[parentID]?.children?.append(child)
            } else {
                roots.append(album)
            }
        }

        // Re-resolve roots from lookup (to pick up children)
        roots = roots.map { resolveChildren(for: $0, lookup: lookup) }

        // Build final flat lookup with resolved children
        var finalLookup: [Int: PiwigoAlbum] = [:]
        func collectAll(_ albums: [PiwigoAlbum]) {
            for album in albums {
                finalLookup[album.id] = album
                if let children = album.children {
                    collectAll(children)
                }
            }
        }
        collectAll(roots)

        let treeCopy = roots
        let lookupCopy = finalLookup
        await MainActor.run {
            self.albumTree = treeCopy
            self.allAlbums = lookupCopy
        }
    }

    /// Recursively resolve an album's children from the lookup table
    private func resolveChildren(for album: PiwigoAlbum, lookup: [Int: PiwigoAlbum]) -> PiwigoAlbum {
        guard let resolved = lookup[album.id] else { return album }
        var result = resolved
        if let children = resolved.children {
            result.children = children.map { resolveChildren(for: $0, lookup: lookup) }
        }
        return result
    }

    private func buildFullPath(albumID: Int, lookup: [Int: PiwigoAlbum]) -> String {
        var parts: [String] = []
        var currentID: Int? = albumID
        while let id = currentID, let album = lookup[id] {
            parts.insert(album.name, at: 0)
            currentID = album.parentID
        }
        return parts.joined(separator: " / ")
    }

    func fetchImages(albumID: Int, page: Int = 0, perPage: Int = 50) async throws -> [PiwigoImage] {
        var request = URLRequest(url: apiURL())
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "method=pwg.categories.getImages&cat_id=\(albumID)&per_page=\(perPage)&page=\(page)"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let result = json?["result"] as? [String: Any],
              let imagesRaw = result["images"] as? [[String: Any]] else {
            throw PiwigoError.parseFailed
        }

        return imagesRaw.compactMap { img -> PiwigoImage? in
            guard let id = img["id"] as? Int,
                  let file = img["file"] as? String else { return nil }
            let name = img["name"] as? String
            let pageURL = img["page_url"] as? String
            let dateCreation = img["date_creation"] as? String

            var derivatives: PiwigoDerivatives?
            if let derivsRaw = img["derivatives"] as? [String: Any] {
                let square = (derivsRaw["square"] as? [String: Any])?["url"] as? String
                let thumb = (derivsRaw["thumb"] as? [String: Any])?["url"] as? String
                let medium = (derivsRaw["medium"] as? [String: Any])?["url"] as? String
                let large = (derivsRaw["large"] as? [String: Any])?["url"] as? String
                let xlarge = (derivsRaw["xlarge"] as? [String: Any])?["url"] as? String
                let xxlarge = (derivsRaw["xxlarge"] as? [String: Any])?["url"] as? String
                derivatives = PiwigoDerivatives(
                    square: square.map { PiwigoDerivative(url: $0) },
                    thumb: thumb.map { PiwigoDerivative(url: $0) },
                    medium: medium.map { PiwigoDerivative(url: $0) },
                    large: large.map { PiwigoDerivative(url: $0) },
                    xlarge: xlarge.map { PiwigoDerivative(url: $0) },
                    xxlarge: xxlarge.map { PiwigoDerivative(url: $0) }
                )
            }

            return PiwigoImage(id: id, file: file, name: name, pageURL: pageURL, dateCreation: dateCreation, derivatives: derivatives)
        }
    }

    func renameImage(imageID: Int, newName: String) async throws {
        var request = URLRequest(url: apiURL())
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "method=pwg.images.setInfo&image_id=\(imageID)&name=\(urlEncode(newName))&single_value_mode=replace"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let stat = json?["stat"] as? String, stat != "ok" {
            let message = json?["message"] as? String ?? "Rename failed"
            throw PiwigoError.renameFailed(message)
        }
    }

    func downloadImage(url: String) async throws -> Data {
        guard let imageURL = URL(string: url) else {
            throw PiwigoError.invalidURL
        }
        let request = URLRequest(url: imageURL)
        let (data, _) = try await session.data(for: request)
        return data
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}

enum PiwigoError: LocalizedError {
    case loginFailed(String)
    case parseFailed
    case renameFailed(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .loginFailed(let msg): return "Login failed: \(msg)"
        case .parseFailed: return "Failed to parse server response"
        case .renameFailed(let msg): return "Rename failed: \(msg)"
        case .invalidURL: return "Invalid URL"
        }
    }
}
