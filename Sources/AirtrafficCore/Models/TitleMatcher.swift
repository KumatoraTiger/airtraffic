import Foundation

/// Title normalization and fuzzy matching, used by the board assembler to
/// attach sessions to tasks and merge same-work sessions.
public enum TitleMatcher {
    /// Canonical form of a title: width- and case-folded, with whitespace,
    /// punctuation, and symbols removed. Two titles with the same key count
    /// as the same work.
    public static func key(_ title: String) -> String {
        String(
            title.precomposedStringWithCompatibilityMapping
                .lowercased()
                .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
    }

    /// True when two titles most likely describe the same task.
    ///
    /// Japanese has no word boundaries, so similarity is measured on character
    /// bigrams (Dice coefficient) rather than on tokens. Containment still
    /// counts, but only once the shorter title is long enough that a substring
    /// match means something — otherwise a generic "更新する" would swallow
    /// every unrelated title that happens to end the same way.
    public static func isSimilar(_ a: String, _ b: String, threshold: Double = 0.7) -> Bool {
        let ka = key(a)
        let kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        if min(ka.count, kb.count) >= 6, ka.contains(kb) || kb.contains(ka) { return true }
        return diceCoefficient(ka, kb) >= threshold
    }

    /// Bigram overlap as a multiset, scaled to 0...1.
    static func diceCoefficient(_ a: String, _ b: String) -> Double {
        let left = bigrams(a)
        let right = bigrams(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var remaining: [String: Int] = [:]
        for gram in left { remaining[gram, default: 0] += 1 }
        var overlap = 0
        for gram in right where (remaining[gram] ?? 0) > 0 {
            remaining[gram]! -= 1
            overlap += 1
        }
        return 2 * Double(overlap) / Double(left.count + right.count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 2 else { return chars.map(String.init) }
        return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
    }
}
