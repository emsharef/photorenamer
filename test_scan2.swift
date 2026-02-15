#!/usr/bin/env swift
import Foundation

// Simulate the app's actor isolation pattern
// PiwigoClient is @MainActor because of @Published properties

@MainActor
class FakePiwigoClient {
    private var session: URLSession
    var baseURL = ""

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func login(serverURL: String, username: String, password: String) async throws {
        baseURL = serverURL
        var req = URLRequest(url: URL(string: "\(baseURL)/ws.php?format=json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "method=pwg.session.login&username=\(username)&password=\(password)".data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        print("Login: \(json?["stat"] ?? "unknown")")
    }

    func fetchImageURLs(albumID: Int) async throws -> [(hiRes: String?, display: String?)] {
        var req = URLRequest(url: URL(string: "\(baseURL)/ws.php?format=json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "method=pwg.categories.getImages&cat_id=\(albumID)&per_page=50&page=0".data(using: .utf8)
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = ((json?["result"] as? [String: Any])?["images"] as? [[String: Any]]) ?? []

        return images.map { img in
            let derivs = img["derivatives"] as? [String: Any]
            let xxlarge = (derivs?["xxlarge"] as? [String: Any])?["url"] as? String
            let xlarge = (derivs?["xlarge"] as? [String: Any])?["url"] as? String
            let large = (derivs?["large"] as? [String: Any])?["url"] as? String
            let medium = (derivs?["medium"] as? [String: Any])?["url"] as? String
            return (hiRes: xxlarge ?? xlarge ?? large ?? medium, display: medium ?? large)
        }
    }

    // This is the key method - NOT nonisolated, so it requires @MainActor
    func downloadImage(url: String) async throws -> Data {
        guard let imageURL = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: imageURL)
        request.timeoutInterval = 30
        let (data, _) = try await session.data(for: request)
        return data
    }

    // Same but nonisolated
    nonisolated func downloadImageNonisolated(url: String) async throws -> Data {
        guard let imageURL = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: imageURL)
        request.timeoutInterval = 30
        let (data, _) = try await session.data(for: request)
        return data
    }
}

// Read credentials
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let credURL = appSupport.appendingPathComponent("PhoDoo/credentials.json")
let credData = try! Data(contentsOf: credURL)
let creds = try! JSONSerialization.jsonObject(with: credData) as! [String: String]
let password = creds.first(where: { $0.key.starts(with: "piwigo-") })!.value

let client = await FakePiwigoClient()
try await client.login(serverURL: "https://sharef.net/piwigo", username: "esharef", password: password)

let urls = try await client.fetchImageURLs(albumID: 2010) // "Within First Week of Birth" - 26 images
print("Got \(urls.count) image URLs")

// Test 1: Using @MainActor-isolated downloadImage from a static (non-isolated) function with TaskGroup
// This simulates exactly what the app does
print("\n=== Test 1: @MainActor downloadImage from static TaskGroup ===")
let start1 = Date()
var completed1 = 0

func runScanStatic(client: FakePiwigoClient, urls: [(hiRes: String?, display: String?)]) async {
    await withTaskGroup(of: (Int, Bool).self) { group in
        var nextIdx = 0
        let maxConcurrent = 10

        for _ in 0..<min(maxConcurrent, urls.count) {
            let i = nextIdx
            let item = urls[i]
            nextIdx += 1
            group.addTask {
                if let url = item.hiRes {
                    _ = try? await client.downloadImage(url: url)
                }
                return (i, true)
            }
        }

        for await (idx, _) in group {
            completed1 += 1
            let elapsed = Date().timeIntervalSince(start1)
            print("  Completed \(completed1)/\(urls.count) (image \(idx)) [\(String(format: "%.1f", elapsed))s]")

            if completed1 == 3 {
                print("  ... first 3 done, pattern established. Breaking early if stuck.")
            }
            if elapsed > 15 {
                print("  TIMEOUT: Taking too long, likely stuck!")
                group.cancelAll()
                break
            }

            if nextIdx < urls.count {
                let i = nextIdx
                let item = urls[i]
                nextIdx += 1
                group.addTask {
                    if let url = item.hiRes {
                        _ = try? await client.downloadImage(url: url)
                    }
                    return (i, true)
                }
            }
        }
    }
}

await runScanStatic(client: client, urls: urls)
let elapsed1 = Date().timeIntervalSince(start1)
print("Test 1 result: \(completed1)/\(urls.count) in \(String(format: "%.1f", elapsed1))s")

// Test 2: Same but with nonisolated download
print("\n=== Test 2: nonisolated downloadImage from static TaskGroup ===")
let start2 = Date()
var completed2 = 0

func runScanNonisolated(client: FakePiwigoClient, urls: [(hiRes: String?, display: String?)]) async {
    await withTaskGroup(of: (Int, Bool).self) { group in
        var nextIdx = 0
        let maxConcurrent = 10

        for _ in 0..<min(maxConcurrent, urls.count) {
            let i = nextIdx
            let item = urls[i]
            nextIdx += 1
            group.addTask {
                if let url = item.hiRes {
                    _ = try? await client.downloadImageNonisolated(url: url)
                }
                return (i, true)
            }
        }

        for await (idx, _) in group {
            completed2 += 1
            let elapsed = Date().timeIntervalSince(start2)
            print("  Completed \(completed2)/\(urls.count) (image \(idx)) [\(String(format: "%.1f", elapsed))s]")

            if nextIdx < urls.count {
                let i = nextIdx
                let item = urls[i]
                nextIdx += 1
                group.addTask {
                    if let url = item.hiRes {
                        _ = try? await client.downloadImageNonisolated(url: url)
                    }
                    return (i, true)
                }
            }
        }
    }
}

await runScanNonisolated(client: client, urls: urls)
let elapsed2 = Date().timeIntervalSince(start2)
print("Test 2 result: \(completed2)/\(urls.count) in \(String(format: "%.1f", elapsed2))s")
