import Foundation

/// Turns a raw session title (usually the first user message, verbatim) into
/// something that reads like a task on the board: one line, noisy tokens
/// compacted, capped in length. Task titles written by the user are never
/// cleaned — this is only for titles the app made up from transcripts.
public enum TitleCleaner {
    private static let maxLength = 60

    public static func taskLabel(_ raw: String) -> String {
        guard
            var line = raw.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
        else { return "" }
        line = stripMarkers(line)
        // URLs shrink to their host, absolute paths to their last component:
        // enough to recognize the target without drowning the verb.
        line = replacing(#"https?://[^\s、。」）]+"#, in: line) { URL(string: $0)?.host ?? $0 }
        line = replacing(#"/(?:[\w.@+~%-]+/)+[\w.@+~%-]+"#, in: line) {
            String($0.split(separator: "/").last ?? Substring($0))
        }
        line = line.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if line.count > maxLength {
            line = String(line.prefix(maxLength)) + "…"
        }
        return line
    }

    /// Leading markdown / bullet markers say nothing about the work.
    private static func stripMarkers(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, "#>-*・ 　".contains(first) {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func replacing(
        _ pattern: String, in text: String, with transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
