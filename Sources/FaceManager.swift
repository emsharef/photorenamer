import Foundation
import Vision
import AppKit
import ImageIO

struct KnownFace: Codable, Identifiable {
    let id: UUID
    let name: String
    let featurePrintData: Data
    let cropImageFile: String
    let dateAdded: Date
    /// Date the original photo was taken (from EXIF, Piwigo, or album name)
    let photoDate: Date?

    func loadFeaturePrint() -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: featurePrintData)
    }
}

struct DetectedFace: Identifiable {
    let id = UUID()
    let boundingBox: CGRect
    let cropImage: NSImage
    let featurePrint: VNFeaturePrintObservation
    var matchedName: String?
    var matchDistance: Float?
    var isAmbiguous: Bool = false
    var ambiguousNames: [String] = []
}

class FaceManager: ObservableObject {
    @Published var knownFaces: [KnownFace] = []

    private let storageDir: URL
    private let dbFile: URL
    private let cropsDir: URL

    /// Distance threshold for considering two faces a match (lower = stricter)
    let matchThreshold: Float = 1.0

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("PhotoRenamer", isDirectory: true)
        dbFile = storageDir.appendingPathComponent("known_faces.json")
        cropsDir = storageDir.appendingPathComponent("face_crops", isDirectory: true)

        try? FileManager.default.createDirectory(at: cropsDir, withIntermediateDirectories: true)
        loadDatabase()
    }

    // MARK: - Face Detection

    func detectFaces(in imageData: Data, photoDate: Date? = nil) async throws -> [DetectedFace] {
        // Run all synchronous Vision work on a GCD thread to avoid blocking
        // the Swift cooperative thread pool (which has limited threads and
        // deadlocks when all threads are occupied by blocking Vision calls).
        let knownFacesSnapshot = self.knownFaces
        let matchThresholdVal = self.matchThreshold

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.detectFacesSync(
                        imageData: imageData,
                        photoDate: photoDate,
                        knownFaces: knownFacesSnapshot,
                        matchThreshold: matchThresholdVal
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous face detection — safe to call from any thread.
    private static func detectFacesSync(
        imageData: Data,
        photoDate: Date?,
        knownFaces: [KnownFace],
        matchThreshold: Float
    ) throws -> [DetectedFace] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Detect face rectangles
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest])

        guard let observations = faceRequest.results else { return [] }

        var detected: [DetectedFace] = []

        for observation in observations {
            let box = observation.boundingBox
            let pixelRect = CGRect(
                x: box.origin.x * imageWidth,
                y: (1 - box.origin.y - box.height) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            )

            let padding: CGFloat = 0.3
            let paddedRect = pixelRect.insetBy(
                dx: -pixelRect.width * padding,
                dy: -pixelRect.height * padding
            ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

            guard let croppedCG = cgImage.cropping(to: paddedRect) else { continue }
            let cropImage = NSImage(cgImage: croppedCG, size: NSSize(width: paddedRect.width, height: paddedRect.height))

            // Generate feature print for the crop
            let fpRequest = VNGenerateImageFeaturePrintRequest()
            let fpHandler = VNImageRequestHandler(cgImage: croppedCG, options: [:])
            try fpHandler.perform([fpRequest])
            guard let featurePrint = fpRequest.results?.first else { continue }

            // Try to match against known faces
            var face = DetectedFace(
                boundingBox: box,
                cropImage: cropImage,
                featurePrint: featurePrint
            )

            if let match = findMatchStatic(for: featurePrint, photoDate: photoDate,
                                           knownFaces: knownFaces, matchThreshold: matchThreshold) {
                if match.isAmbiguous {
                    face.isAmbiguous = true
                    face.ambiguousNames = match.ambiguousNames
                    face.matchDistance = match.distance
                } else {
                    face.matchedName = match.name
                    face.matchDistance = match.distance
                }
            }

            detected.append(face)
        }

        return detected
    }

    private static func findMatchStatic(
        for featurePrint: VNFeaturePrintObservation,
        photoDate: Date?,
        knownFaces: [KnownFace],
        matchThreshold: Float
    ) -> MatchResult? {
        var bestPerPerson: [String: Float] = [:]
        let yearSeconds: TimeInterval = 365.25 * 24 * 3600
        let maxAge: TimeInterval = 10 * yearSeconds

        for known in knownFaces {
            if let targetDate = photoDate, let sampleDate = known.photoDate {
                let gap = abs(targetDate.timeIntervalSince(sampleDate))
                if gap > maxAge { continue }
            }
            guard let knownPrint = known.loadFeaturePrint() else { continue }
            var distance: Float = 0
            do {
                try knownPrint.computeDistance(&distance, to: featurePrint)
            } catch { continue }

            if distance < matchThreshold {
                if bestPerPerson[known.name] == nil || distance < bestPerPerson[known.name]! {
                    bestPerPerson[known.name] = distance
                }
            }
        }

        guard !bestPerPerson.isEmpty else { return nil }
        let sorted = bestPerPerson.sorted { $0.value < $1.value }
        let best = sorted[0]

        if sorted.count >= 2 {
            let secondBest = sorted[1]
            let margin = best.value * 0.1
            if secondBest.value - best.value < max(margin, 0.1) {
                return MatchResult(
                    name: best.key, distance: best.value,
                    isAmbiguous: true, ambiguousNames: sorted.prefix(3).map(\.key)
                )
            }
        }

        return MatchResult(
            name: best.key, distance: best.value,
            isAmbiguous: false, ambiguousNames: []
        )
    }

    // MARK: - Feature Print

    private func generateFeaturePrint(for cgImage: CGImage) throws -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results?.first
    }

    // MARK: - Matching

    struct MatchResult {
        let name: String
        let distance: Float
        let isAmbiguous: Bool
        let ambiguousNames: [String]
    }

    private func findMatch(for featurePrint: VNFeaturePrintObservation, photoDate: Date? = nil) -> MatchResult? {
        // Compute best distance per person
        var bestPerPerson: [String: Float] = [:]

        let yearSeconds: TimeInterval = 365.25 * 24 * 3600
        let maxAge: TimeInterval = 10 * yearSeconds

        for known in knownFaces {
            // Skip samples outside +-10 years if both dates are available
            if let targetDate = photoDate, let sampleDate = known.photoDate {
                let gap = abs(targetDate.timeIntervalSince(sampleDate))
                if gap > maxAge { continue }
            }

            guard let knownPrint = known.loadFeaturePrint() else { continue }
            var distance: Float = 0
            do {
                try knownPrint.computeDistance(&distance, to: featurePrint)
            } catch {
                continue
            }

            if distance < matchThreshold {
                if bestPerPerson[known.name] == nil || distance < bestPerPerson[known.name]! {
                    bestPerPerson[known.name] = distance
                }
            }
        }

        guard !bestPerPerson.isEmpty else { return nil }

        let sorted = bestPerPerson.sorted { $0.value < $1.value }
        let best = sorted[0]

        // Check for ambiguity: if second-best person is within 30% of best distance
        if sorted.count >= 2 {
            let secondBest = sorted[1]
            let margin = best.value * 0.1
            if secondBest.value - best.value < max(margin, 0.1) {
                return MatchResult(
                    name: best.key,
                    distance: best.value,
                    isAmbiguous: true,
                    ambiguousNames: sorted.prefix(3).map(\.key)
                )
            }
        }

        return MatchResult(
            name: best.key,
            distance: best.value,
            isAmbiguous: false,
            ambiguousNames: []
        )
    }

    // MARK: - Labeling

    func labelFace(name: String, featurePrint: VNFeaturePrintObservation, cropImage: NSImage, photoDate: Date? = nil) {
        guard let featurePrintData = try? NSKeyedArchiver.archivedData(
            withRootObject: featurePrint,
            requiringSecureCoding: true
        ) else { return }

        let cropFile = "\(UUID().uuidString).jpg"
        let cropURL = cropsDir.appendingPathComponent(cropFile)

        // Save crop image
        if let tiffData = cropImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpegData.write(to: cropURL)
        }

        let knownFace = KnownFace(
            id: UUID(),
            name: name,
            featurePrintData: featurePrintData,
            cropImageFile: cropFile,
            dateAdded: Date(),
            photoDate: photoDate
        )

        knownFaces.append(knownFace)
        saveDatabase()
    }

    func removeFace(id: UUID) {
        if let index = knownFaces.firstIndex(where: { $0.id == id }) {
            let face = knownFaces[index]
            let cropURL = cropsDir.appendingPathComponent(face.cropImageFile)
            try? FileManager.default.removeItem(at: cropURL)
            knownFaces.remove(at: index)
            saveDatabase()
        }
    }

    func renamePerson(oldName: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, oldName != trimmed else { return }
        for i in knownFaces.indices {
            if knownFaces[i].name == oldName {
                let old = knownFaces[i]
                knownFaces[i] = KnownFace(
                    id: old.id,
                    name: trimmed,
                    featurePrintData: old.featurePrintData,
                    cropImageFile: old.cropImageFile,
                    dateAdded: old.dateAdded,
                    photoDate: old.photoDate
                )
            }
        }
        saveDatabase()
    }

    func cropImageForKnownFace(_ face: KnownFace) -> NSImage? {
        let url = cropsDir.appendingPathComponent(face.cropImageFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    /// All unique names in the face database
    var knownNames: [String] {
        Array(Set(knownFaces.map(\.name))).sorted()
    }

    // MARK: - Persistence

    private func loadDatabase() {
        guard let data = try? Data(contentsOf: dbFile),
              let faces = try? JSONDecoder().decode([KnownFace].self, from: data) else {
            return
        }
        knownFaces = faces
    }

    private func saveDatabase() {
        guard let data = try? JSONEncoder().encode(knownFaces) else { return }
        try? data.write(to: dbFile)
    }

    // MARK: - Photo Date Extraction

    /// Extract the date a photo was taken, trying multiple sources
    static func extractPhotoDate(
        imageData: Data?,
        piwigoDateString: String?,
        albumPath: String?
    ) -> Date? {
        // 1. Try EXIF DateTimeOriginal
        if let data = imageData, let exifDate = exifDate(from: data) {
            return exifDate
        }

        // 2. Try to extract a year from the album path
        if let path = albumPath, let date = yearFromAlbumPath(path) {
            return date
        }

        // 3. Try Piwigo's date_creation field
        if let dateStr = piwigoDateString, let date = parsePiwigoDate(dateStr) {
            return date
        }

        return nil
    }

    private static func exifDate(from imageData: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }

    private static func parsePiwigoDate(_ dateStr: String) -> Date? {
        // Piwigo uses "YYYY-MM-DD HH:MM:SS" format
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: dateStr) { return date }

        // Also try ISO 8601
        let iso = ISO8601DateFormatter()
        return iso.date(from: dateStr)
    }

    /// Extract GPS coordinates from EXIF data, returned as "lat, lon" string
    static func extractPhotoLocation(imageData: Data?) -> String? {
        guard let imageData = imageData,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
              let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double,
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
        else { return nil }

        let signedLat = latRef == "S" ? -lat : lat
        let signedLon = lonRef == "W" ? -lon : lon
        return String(format: "%.5f, %.5f", signedLat, signedLon)
    }

    private static func yearFromAlbumPath(_ path: String) -> Date? {
        // Look for a 4-digit year (1900-2099) in the album path
        let pattern = #"\b(19\d{2}|20\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: path,
                range: NSRange(path.startIndex..., in: path)
              ),
              let range = Range(match.range(at: 1), in: path)
        else { return nil }

        let yearStr = String(path[range])
        guard let year = Int(yearStr) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = 6  // Mid-year as approximation
        components.day = 15
        return Calendar.current.date(from: components)
    }
}
