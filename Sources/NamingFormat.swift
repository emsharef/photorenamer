import Foundation

/// Applies a naming template to produce a final filename.
///
/// Template tokens:
///   {date}           — date formatted as yyyyMMdd (default)
///   {date:FORMAT}    — date with custom DateFormatter format (e.g. {date:yyyy-MM-dd})
///   {seq}            — sequence number, zero-padded to 3 digits (default)
///   {seq:N}          — sequence number, zero-padded to N digits
///   {title}          — AI-generated description
///   {people}         — identified people names, joined naturally
///   {album}          — album or folder name
///   {original}       — original filename without extension
///   {location}       — photo location from EXIF GPS
///
/// If a token's value is unavailable (e.g. no date, no seq), the token and
/// surrounding whitespace are collapsed so there are no double spaces.
enum NamingFormat {
    static let defaultTemplate = "{date} {seq} {title}"

    /// Apply the naming template.
    static func apply(
        template: String,
        date: Date?,
        seq: Int?,
        title: String,
        people: [String] = [],
        album: String? = nil,
        original: String? = nil,
        location: String? = nil
    ) -> String {
        var result = template

        // Replace {date} or {date:FORMAT}
        result = replaceDateToken(in: result, date: date)

        // Replace {seq} or {seq:N}
        result = replaceSeqToken(in: result, seq: seq)

        // Replace {title}
        result = result.replacingOccurrences(of: "{title}", with: title)

        // Replace {people}
        result = result.replacingOccurrences(of: "{people}", with: joinPeople(people))

        // Replace {album}
        result = result.replacingOccurrences(of: "{album}", with: album ?? "")

        // Replace {original}
        result = result.replacingOccurrences(of: "{original}", with: original ?? "")

        // Replace {location}
        result = result.replacingOccurrences(of: "{location}", with: location ?? "")

        // Collapse multiple spaces into one and trim
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespaces)

        // Clean up leading/trailing separators (dash, underscore) from removed tokens
        let separators = CharacterSet(charactersIn: "-_ ")
        result = result.trimmingCharacters(in: separators)

        return result
    }

    /// Preview the format with sample values for the settings UI.
    static func preview(template: String) -> String {
        var components = DateComponents()
        components.year = 2025
        components.month = 11
        components.day = 12
        let sampleDate = Calendar.current.date(from: components)

        return apply(
            template: template,
            date: sampleDate,
            seq: 1,
            title: "Sarah and John on a boat",
            people: ["Sarah", "John"],
            album: "Vacation 2025",
            original: "IMG_4523",
            location: "Lake Tahoe"
        )
    }

    /// Join people names naturally: "Sarah", "Sarah and John", "Sarah, John, and Mike"
    private static func joinPeople(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
    }

    // MARK: - Private

    private static func replaceDateToken(in template: String, date: Date?) -> String {
        // Match {date:FORMAT} or {date}
        guard let regex = try? NSRegularExpression(pattern: #"\{date(?::([^}]+))?\}"#) else {
            return template
        }

        let nsTemplate = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))

        guard let match = matches.first else { return template }

        guard let date = date else {
            // No date available — remove the token
            return nsTemplate.replacingCharacters(in: match.range, with: "")
        }

        // Extract custom format or use default
        let format: String
        if match.range(at: 1).location != NSNotFound {
            format = nsTemplate.substring(with: match.range(at: 1))
        } else {
            format = "yyyyMMdd"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = format
        let dateStr = formatter.string(from: date)

        return nsTemplate.replacingCharacters(in: match.range, with: dateStr)
    }

    private static func replaceSeqToken(in template: String, seq: Int?) -> String {
        // Match {seq:N} or {seq}
        guard let regex = try? NSRegularExpression(pattern: #"\{seq(?::(\d+))?\}"#) else {
            return template
        }

        let nsTemplate = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length))

        guard let match = matches.first else { return template }

        guard let seq = seq else {
            // No sequence — remove the token
            return nsTemplate.replacingCharacters(in: match.range, with: "")
        }

        // Extract digit count or default to 3
        let digits: Int
        if match.range(at: 1).location != NSNotFound {
            digits = Int(nsTemplate.substring(with: match.range(at: 1))) ?? 3
        } else {
            digits = 3
        }

        let seqStr = String(format: "%0\(digits)d", seq)
        return nsTemplate.replacingCharacters(in: match.range, with: seqStr)
    }
}
