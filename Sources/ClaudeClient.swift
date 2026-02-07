import Foundation

class ClaudeClient {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func describeImage(
        imageData: Data,
        mimeType: String = "image/jpeg",
        peopleNames: [String] = [],
        albumPath: String? = nil,
        photoDate: Date? = nil,
        photoLocation: String? = nil
    ) async throws -> String {
        let b64 = imageData.base64EncodedString()

        var contextLines: [String] = []
        if !peopleNames.isEmpty {
            let names = peopleNames.joined(separator: ", ")
            contextLines.append("People identified in this photo: \(names)")
        }
        if let album = albumPath, !album.isEmpty {
            contextLines.append("Album location: \(album)")
        }
        if let location = photoLocation, !location.isEmpty {
            contextLines.append("GPS coordinates: \(location)")
        }

        var datePrefix = ""
        if let date = photoDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            datePrefix = formatter.string(from: date) + " "
            contextLines.append("Photo date: \(date.formatted(date: .long, time: .omitted))")
        }

        let contextBlock = contextLines.isEmpty
            ? ""
            : "\n\nAdditional context:\n" + contextLines.joined(separator: "\n")

        let prompt = """
        Generate a short, descriptive title for this photo (no file extension, no date prefix). \
        Use normal capitalization and spaces. Be specific about the subject, location, \
        activity, or scene. \
        If people's names are provided, include them naturally. \
        If the album path gives useful context (location, event, trip), incorporate it naturally. \
        If GPS coordinates are provided, use them to identify the location and include it naturally \
        (use the place name, not the coordinates). \
        Do NOT include a date prefix — that will be added automatically. \
        Examples: "Sarah and John on a boat", "Kids playing in the backyard", \
        "Golden Gate Bridge on a foggy morning". Just return the title, nothing else.\(contextBlock)
        """

        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5-20250929",
            "max_tokens": 200,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mimeType,
                            "data": b64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": prompt
                    ]
                ]
            ]]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.requestFailed("No HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw ClaudeError.parseFailed
        }

        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return datePrefix + title
    }

    struct PersonReference {
        let name: String
        let imageData: Data
    }

    func describeImageWithReferences(
        imageData: Data,
        mimeType: String = "image/jpeg",
        peopleNames: [String] = [],
        references: [PersonReference] = [],
        albumPath: String? = nil,
        photoDate: Date? = nil,
        photoLocation: String? = nil,
        userNotes: String? = nil
    ) async throws -> String {
        let b64 = imageData.base64EncodedString()

        var contextLines: [String] = []
        if !peopleNames.isEmpty {
            let names = peopleNames.joined(separator: ", ")
            contextLines.append("People identified in this photo via face recognition: \(names)")
        }
        if let album = albumPath, !album.isEmpty {
            contextLines.append("Album location: \(album)")
        }
        if let location = photoLocation, !location.isEmpty {
            contextLines.append("GPS coordinates: \(location)")
        }
        if let notes = userNotes, !notes.isEmpty {
            contextLines.append("User notes: \(notes)")
        }

        var datePrefix = ""
        if let date = photoDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            datePrefix = formatter.string(from: date) + " "
            contextLines.append("Photo date: \(date.formatted(date: .long, time: .omitted))")
        }

        let contextBlock = contextLines.isEmpty
            ? ""
            : "\n\nAdditional context:\n" + contextLines.joined(separator: "\n")

        var referenceBlock = ""
        if !references.isEmpty {
            let names = references.map(\.name).joined(separator: ", ")
            referenceBlock = """
            \n\nI'm providing reference photos of people who may appear in this album: \(names). \
            Use these to identify people in the main photo even if their face is not clearly visible — \
            you can match by clothing, hair, body shape, accessories, etc. \
            Only include a person's name if you are reasonably confident they appear in the photo.
            """
        }

        let prompt = """
        Generate a short, descriptive title for the LAST photo below (no file extension, no date prefix). \
        Use normal capitalization and spaces. Be specific about the subject, location, \
        activity, or scene. \
        If people are identified (via face recognition or reference photos), include their names naturally. \
        If the album path gives useful context (location, event, trip), incorporate it naturally. \
        If GPS coordinates are provided, use them to identify the location and include it naturally \
        (use the place name, not the coordinates). \
        Do NOT include a date prefix — that will be added automatically. \
        Examples: "Sarah and John on a boat", "Kids playing in the backyard", \
        "Golden Gate Bridge on a foggy morning". Just return the title, nothing else.\(referenceBlock)\(contextBlock)
        """

        // Build content array: reference photos first, then the main photo, then prompt
        var content: [[String: Any]] = []

        for ref in references {
            let refB64 = ref.imageData.base64EncodedString()
            content.append([
                "type": "text",
                "text": "Reference photo of \(ref.name):"
            ])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": refB64
                ]
            ])
        }

        if !references.isEmpty {
            content.append([
                "type": "text",
                "text": "Now here is the photo to name:"
            ])
        }

        content.append([
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mimeType,
                "data": b64
            ]
        ])

        content.append([
            "type": "text",
            "text": prompt
        ])

        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5-20250929",
            "max_tokens": 200,
            "messages": [[
                "role": "user",
                "content": content
            ]]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.requestFailed("No HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let respContent = json?["content"] as? [[String: Any]],
              let text = respContent.first?["text"] as? String else {
            throw ClaudeError.parseFailed
        }

        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return datePrefix + title
    }
}

enum ClaudeError: LocalizedError {
    case requestFailed(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "Claude API error: \(msg)"
        case .parseFailed: return "Failed to parse Claude response"
        }
    }
}
