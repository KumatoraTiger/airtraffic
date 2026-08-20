import Foundation

/// Picks the line a person actually typed out of a raw prompt.
///
/// Transcripts do not only hold what the user wrote: CLIs inject reminders,
/// caveats about slash commands, environment blocks and AGENTS.md dumps into
/// the same user turn, and orchestrators drive sessions with JSON payloads.
/// Taking the first line verbatim turns those into session titles, so every
/// adapter runs its candidate text through here first.
public enum PromptText {
    /// Tags that wrap machinery. Their whole block is skipped.
    private static let noiseTags: Set<String> = [
        "system-reminder",
        "local-command-caveat",
        "local-command-stdout",
        "command-name",
        "command-message",
        "command-args",
        "user_info",
        "environment_context",
        "instructions",
        "task-notification",
    ]

    /// Tags that only wrap the user's own text: the tags go, the text stays.
    private static let transparentTags: Set<String> = [
        "user_query",
        "user_message",
    ]

    /// Line openings that belong to injected context rather than to a request.
    private static let noisePrefixes: [String] = [
        "# agents.md instructions",
        "caveat:",
    ]

    /// The first line that reads like a human request, or "" when the text is
    /// machinery from end to end.
    public static func humanLine(_ raw: String) -> String {
        var openNoiseTag: String?
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let tag = openNoiseTag {
                if contains(closingTag: tag, in: line) { openNoiseTag = nil }
                continue
            }
            if line.hasPrefix("</") { continue }
            if line.hasPrefix("<") {
                guard let tag = tagName(line) else { continue }
                if transparentTags.contains(tag) {
                    let inner = strippingTags(line)
                    if !inner.isEmpty { return inner }
                    continue
                }
                // An unknown tag is machinery too: prompts start with prose.
                if !contains(closingTag: tag, in: line) { openNoiseTag = tag }
                continue
            }
            // Orchestrators poke agents with JSON payloads, not sentences.
            if line.hasPrefix("{") || line.hasPrefix("[") { continue }
            if isNoise(line) { continue }
            return line
        }
        return ""
    }

    /// Lowercased name of the tag a line opens with, nil when it opens none.
    private static func tagName(_ line: String) -> String? {
        var name = ""
        for character in line.dropFirst() {
            if character == ">" || character == "/" || character.isWhitespace { break }
            guard character.isLetter || character.isNumber || character == "-" || character == "_"
            else { return nil }
            name.append(character)
        }
        return name.isEmpty ? nil : name.lowercased()
    }

    private static func contains(closingTag tag: String, in line: String) -> Bool {
        line.range(of: "</\(tag)>", options: .caseInsensitive) != nil
    }

    private static func strippingTags(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isNoise(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return noisePrefixes.contains { lowered.hasPrefix($0) }
    }
}
