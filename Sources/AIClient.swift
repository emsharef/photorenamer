import Foundation

// MARK: - AI Provider

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case openai
    case gemini
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .kimi: return "Kimi"
        }
    }

    var keychainAccount: String {
        switch self {
        case .claude: return "claude-api-key"
        case .openai: return "openai-api-key"
        case .gemini: return "gemini-api-key"
        case .kimi: return "kimi-api-key"
        }
    }

    var placeholder: String {
        switch self {
        case .claude: return "sk-ant-..."
        case .openai: return "sk-..."
        case .gemini: return "AI..."
        case .kimi: return "sk-..."
        }
    }
}

// MARK: - AI Client

class AIClient {
    private let provider: AIProvider
    private let apiKey: String

    init(provider: AIProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Content abstraction

    private enum ContentItem {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    // MARK: - Public API

    func describeImage(
        imageData: Data,
        mimeType: String = "image/jpeg",
        peopleNames: [String] = [],
        albumPath: String? = nil,
        photoDate: Date? = nil,
        photoLocation: String? = nil
    ) async throws -> String {
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

        if let date = photoDate {
            contextLines.append("Photo date: \(date.formatted(date: .long, time: .omitted))")
        }

        let contextBlock = contextLines.isEmpty
            ? ""
            : "\n\nAdditional context:\n" + contextLines.joined(separator: "\n")

        let prompt = """
        Generate a short, descriptive title for this photo (no file extension, no date prefix, no sequence number). \
        Use normal capitalization and spaces. Be specific about the subject, location, \
        activity, or scene. \
        If people's names are provided, include them naturally. \
        If the album path gives useful context (location, event, trip), incorporate it naturally. \
        If GPS coordinates are provided, use them to identify the location and include it naturally \
        (use the place name, not the coordinates). \
        Do NOT include a date prefix or number — those will be added automatically. \
        Examples: "Sarah and John on a boat", "Kids playing in the backyard", \
        "Golden Gate Bridge on a foggy morning". Just return the title, nothing else.\(contextBlock)
        """

        let content: [ContentItem] = [
            .image(data: imageData, mimeType: mimeType),
            .text(prompt)
        ]

        return try await sendRequest(content: content, timeout: 30)
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

        if let date = photoDate {
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
        Generate a short, descriptive title for the LAST photo below (no file extension, no date prefix, no sequence number). \
        Use normal capitalization and spaces. Be specific about the subject, location, \
        activity, or scene. \
        If people are identified (via face recognition or reference photos), include their names naturally. \
        If the album path gives useful context (location, event, trip), incorporate it naturally. \
        If GPS coordinates are provided, use them to identify the location and include it naturally \
        (use the place name, not the coordinates). \
        Do NOT include a date prefix or number — those will be added automatically. \
        Examples: "Sarah and John on a boat", "Kids playing in the backyard", \
        "Golden Gate Bridge on a foggy morning". Just return the title, nothing else.\(referenceBlock)\(contextBlock)
        """

        // Build content array: reference photos first, then the main photo, then prompt
        var content: [ContentItem] = []

        for ref in references {
            content.append(.text("Reference photo of \(ref.name):"))
            content.append(.image(data: ref.imageData, mimeType: "image/jpeg"))
        }

        if !references.isEmpty {
            content.append(.text("Now here is the photo to name:"))
        }

        content.append(.image(data: imageData, mimeType: mimeType))
        content.append(.text(prompt))

        return try await sendRequest(content: content, timeout: 60)
    }

    // MARK: - Provider dispatch

    private func sendRequest(content: [ContentItem], timeout: TimeInterval) async throws -> String {
        switch provider {
        case .claude:
            return try await sendClaude(content: content, timeout: timeout)
        case .openai:
            return try await sendOpenAI(content: content, timeout: timeout)
        case .gemini:
            return try await sendGemini(content: content, timeout: timeout)
        case .kimi:
            return try await sendOpenAIChatCompletions(
                content: content, timeout: timeout,
                endpoint: "https://api.moonshot.ai/v1/chat/completions",
                model: "kimi-k2.5"
            )
        }
    }

    // MARK: - Claude (Anthropic)

    private func sendClaude(content: [ContentItem], timeout: TimeInterval) async throws -> String {
        var messageContent: [[String: Any]] = []

        for item in content {
            switch item {
            case .text(let text):
                messageContent.append([
                    "type": "text",
                    "text": text
                ])
            case .image(let data, let mimeType):
                messageContent.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": data.base64EncodedString()
                    ]
                ])
            }
        }

        let payload: [String: Any] = [
            "model": "claude-sonnet-4-5-20250929",
            "max_tokens": 200,
            "messages": [[
                "role": "user",
                "content": messageContent
            ]]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.requestFailed("No HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let respContent = json?["content"] as? [[String: Any]],
              let text = respContent.first?["text"] as? String else {
            throw AIClientError.parseFailed
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI (Responses API)

    private func sendOpenAI(content: [ContentItem], timeout: TimeInterval) async throws -> String {
        var inputContent: [[String: Any]] = []

        for item in content {
            switch item {
            case .text(let text):
                inputContent.append([
                    "type": "input_text",
                    "text": text
                ])
            case .image(let data, let mimeType):
                let b64 = data.base64EncodedString()
                inputContent.append([
                    "type": "input_image",
                    "image_url": "data:\(mimeType);base64,\(b64)"
                ])
            }
        }

        let payload: [String: Any] = [
            "model": "gpt-5-nano",
            "max_output_tokens": 500,
            "reasoning": ["effort": "minimal"],
            "input": [[
                "role": "user",
                "content": inputContent
            ]]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.requestFailed("No HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Try top-level output_text first
        if let text = json?["output_text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Walk the output array to find the message with output_text content
        if let output = json?["output"] as? [[String: Any]] {
            for item in output {
                if let contentArr = item["content"] as? [[String: Any]] {
                    for part in contentArr {
                        if part["type"] as? String == "output_text",
                           let text = part["text"] as? String {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
        }

        throw AIClientError.parseFailed
    }

    // MARK: - OpenAI Chat Completions compatible (Kimi)

    private func sendOpenAIChatCompletions(
        content: [ContentItem],
        timeout: TimeInterval,
        endpoint: String,
        model: String
    ) async throws -> String {
        var messageContent: [[String: Any]] = []

        for item in content {
            switch item {
            case .text(let text):
                messageContent.append([
                    "type": "text",
                    "text": text
                ])
            case .image(let data, let mimeType):
                let b64 = data.base64EncodedString()
                messageContent.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(mimeType);base64,\(b64)"
                    ]
                ])
            }
        }

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            "thinking": ["type": "disabled"],
            "messages": [[
                "role": "user",
                "content": messageContent
            ]]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.requestFailed("No HTTP response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIClientError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIClientError.parseFailed
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Google Gemini

    private static let geminiModelChain = [
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-3-flash-preview",
    ]

    private func sendGemini(content: [ContentItem], timeout: TimeInterval) async throws -> String {
        var parts: [[String: Any]] = []

        for item in content {
            switch item {
            case .text(let text):
                parts.append(["text": text])
            case .image(let data, let mimeType):
                parts.append([
                    "inlineData": [
                        "mimeType": mimeType,
                        "data": data.base64EncodedString()
                    ]
                ])
            }
        }

        let payload: [String: Any] = [
            "contents": [[
                "parts": parts
            ]],
            "generationConfig": [
                "maxOutputTokens": 2048,
                "thinkingConfig": ["thinkingBudget": 0]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        var lastError: Error?

        for model in Self.geminiModelChain {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
            var request = URLRequest(url: URL(string: urlString)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            request.timeoutInterval = timeout

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = AIClientError.requestFailed("No HTTP response")
                continue
            }

            if httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = AIClientError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
                continue
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let candidates = json?["candidates"] as? [[String: Any]],
               let first = candidates.first {
                // Check for content blocks — fall back to next model
                if let finishReason = first["finishReason"] as? String,
                   finishReason != "STOP" && first["content"] == nil {
                    lastError = AIClientError.requestFailed("Gemini \(model) blocked: \(finishReason)")
                    continue
                }

                if let candidateContent = first["content"] as? [String: Any],
                   let candidateParts = candidateContent["parts"] as? [[String: Any]] {
                    // Skip thinking parts (marked with "thought": true) and find the actual text
                    for part in candidateParts.reversed() {
                        if part["thought"] as? Bool == true { continue }
                        if let text = part["text"] as? String, !text.isEmpty {
                            return text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }

            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "empty"
            lastError = AIClientError.requestFailed("Failed to parse Gemini \(model) response: \(bodyPreview)")
        }

        throw lastError ?? AIClientError.parseFailed
    }
}

// MARK: - Error

enum AIClientError: LocalizedError {
    case requestFailed(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return "AI API error: \(msg)"
        case .parseFailed: return "Failed to parse AI response"
        }
    }
}
