#!/usr/bin/env swift
import Foundation

// Read credentials
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let credURL = appSupport.appendingPathComponent("PhoDoo/credentials.json")
let credData = try! Data(contentsOf: credURL)
let creds = try! JSONSerialization.jsonObject(with: credData) as! [String: String]

let serverURL = "https://sharef.net/piwigo"
let username = "esharef"
// Try both piwigo accounts
let password = creds.first(where: { $0.key.starts(with: "piwigo-") })!.value

let config = URLSessionConfiguration.default
config.httpCookieStorage = HTTPCookieStorage.shared
config.httpCookieAcceptPolicy = .always
config.timeoutIntervalForResource = 60
let session = URLSession(configuration: config)

func apiURL() -> URL {
    URL(string: "\(serverURL)/ws.php?format=json")!
}

// Step 1: Login
print("Logging in...")
var loginReq = URLRequest(url: apiURL())
loginReq.httpMethod = "POST"
loginReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
loginReq.httpBody = "method=pwg.session.login&username=\(username)&password=\(password)".data(using: .utf8)

let (loginData, _) = try await session.data(for: loginReq)
let loginJson = try JSONSerialization.jsonObject(with: loginData) as? [String: Any]
print("Login: \(loginJson?["stat"] ?? "unknown")")

// Step 2: Fetch albums to find one with images
print("Fetching albums...")
var albumReq = URLRequest(url: apiURL())
albumReq.httpMethod = "POST"
albumReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
albumReq.httpBody = "method=pwg.categories.getList&recursive=true".data(using: .utf8)

let (albumData, _) = try await session.data(for: albumReq)
let albumJson = try JSONSerialization.jsonObject(with: albumData) as? [String: Any]
let categories = (albumJson?["result"] as? [String: Any])?["categories"] as? [[String: Any]] ?? []

// Find first album with ~26 images or any album with images
var targetAlbumID: Int?
var targetAlbumName: String?
for cat in categories {
    let nbImages = cat["nb_images"] as? Int ?? 0
    let name = cat["name"] as? String ?? "?"
    let id = cat["id"] as? Int ?? 0
    if nbImages > 0 {
        print("  Album \(id): \(name) (\(nbImages) images)")
        if nbImages >= 20 && targetAlbumID == nil {
            targetAlbumID = id
            targetAlbumName = name
        }
    }
}

guard let albumID = targetAlbumID else {
    print("No album with >= 20 images found")
    exit(1)
}
print("\nUsing album: \(targetAlbumName!) (id=\(albumID))")

// Step 3: Fetch images
print("Fetching image list...")
var imgReq = URLRequest(url: apiURL())
imgReq.httpMethod = "POST"
imgReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
imgReq.httpBody = "method=pwg.categories.getImages&cat_id=\(albumID)&per_page=50&page=0".data(using: .utf8)

let (imgData, _) = try await session.data(for: imgReq)
let imgJson = try JSONSerialization.jsonObject(with: imgData) as? [String: Any]
let images = ((imgJson?["result"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []
print("Found \(images.count) images")

// Collect download URLs (largestURL logic)
var downloadURLs: [(index: Int, hiRes: String?, display: String?)] = []
for (i, img) in images.prefix(26).enumerated() {
    let derivs = img["derivatives"] as? [String: Any]
    let xxlarge = (derivs?["xxlarge"] as? [String: Any])?["url"] as? String
    let xlarge = (derivs?["xlarge"] as? [String: Any])?["url"] as? String
    let large = (derivs?["large"] as? [String: Any])?["url"] as? String
    let medium = (derivs?["medium"] as? [String: Any])?["url"] as? String
    let hiRes = xxlarge ?? xlarge ?? large ?? medium
    let display = medium ?? large
    downloadURLs.append((index: i, hiRes: hiRes, display: display))
}

// Step 4: Download concurrently - exactly like the app's scanOnePhoto
print("\nStarting concurrent downloads (max 10)...")
let startTime = Date()
var completed = 0
let total = downloadURLs.count
let maxConcurrent = 10

await withTaskGroup(of: (Int, Bool, Bool).self) { group in
    var nextIdx = 0

    for _ in 0..<min(maxConcurrent, downloadURLs.count) {
        let item = downloadURLs[nextIdx]
        nextIdx += 1
        group.addTask {
            let idx = item.index
            var gotHiRes = false
            var gotDisplay = false

            if let url = item.hiRes, let u = URL(string: url) {
                var req = URLRequest(url: u)
                req.timeoutInterval = 30
                let taskStart = Date()
                do {
                    let (data, _) = try await session.data(for: req)
                    gotHiRes = true
                    let elapsed = Date().timeIntervalSince(taskStart)
                    print("  [\(idx)] hiRes: \(data.count) bytes in \(String(format: "%.1f", elapsed))s")
                } catch {
                    let elapsed = Date().timeIntervalSince(taskStart)
                    print("  [\(idx)] hiRes FAILED after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
                }
            }

            if let url = item.display, let u = URL(string: url) {
                var req = URLRequest(url: u)
                req.timeoutInterval = 30
                let taskStart = Date()
                do {
                    let (data, _) = try await session.data(for: req)
                    gotDisplay = true
                    let elapsed = Date().timeIntervalSince(taskStart)
                    print("  [\(idx)] display: \(data.count) bytes in \(String(format: "%.1f", elapsed))s")
                } catch {
                    let elapsed = Date().timeIntervalSince(taskStart)
                    print("  [\(idx)] display FAILED after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
                }
            }

            return (idx, gotHiRes, gotDisplay)
        }
    }

    for await (idx, gotHiRes, gotDisplay) in group {
        completed += 1
        let elapsed = Date().timeIntervalSince(startTime)
        print("Completed \(completed)/\(total) (image \(idx)) hiRes=\(gotHiRes) display=\(gotDisplay) [total: \(String(format: "%.1f", elapsed))s]")

        if nextIdx < downloadURLs.count {
            let item = downloadURLs[nextIdx]
            nextIdx += 1
            group.addTask {
                let idx = item.index
                var gotHiRes = false
                var gotDisplay = false

                if let url = item.hiRes, let u = URL(string: url) {
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 30
                    do {
                        let (data, _) = try await session.data(for: req)
                        gotHiRes = true
                        print("  [\(idx)] hiRes: \(data.count) bytes")
                    } catch {
                        print("  [\(idx)] hiRes FAILED: \(error.localizedDescription)")
                    }
                }

                if let url = item.display, let u = URL(string: url) {
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 30
                    do {
                        let (data, _) = try await session.data(for: req)
                        gotDisplay = true
                        print("  [\(idx)] display: \(data.count) bytes")
                    } catch {
                        print("  [\(idx)] display FAILED: \(error.localizedDescription)")
                    }
                }

                return (idx, gotHiRes, gotDisplay)
            }
        }
    }
}

let totalElapsed = Date().timeIntervalSince(startTime)
print("\nDone! \(completed)/\(total) in \(String(format: "%.1f", totalElapsed))s")
