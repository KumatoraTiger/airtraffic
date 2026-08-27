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

    /// A title prepared for comparison: its key plus the bigrams the Dice
    /// coefficient needs, encoded as sorted integers.
    ///
    /// This is the expensive half of a comparison, and the board compares
    /// every session against every task, so a caller in that position builds
    /// one of these per title and reuses it across the whole pass.
    public struct Fingerprint: Sendable {
        public let key: String
        /// Character count of the key, for the containment rule's floor.
        let length: Int
        /// Bigrams as sorted scalar pairs. Sorted so overlap is a linear merge
        /// with no dictionary and no string allocation per comparison.
        let grams: [UInt64]

        init(_ title: String) {
            let key = TitleMatcher.key(title)
            self.key = key
            length = key.count
            let scalars = Array(key.unicodeScalars)
            if scalars.count < 2 {
                grams = scalars.map { UInt64($0.value) << 32 }
            } else {
                grams = (0..<(scalars.count - 1))
                    .map { UInt64(scalars[$0].value) << 32 | UInt64(scalars[$0 + 1].value) }
                    .sorted()
            }
        }
    }

    public static func fingerprint(_ title: String) -> Fingerprint { Fingerprint(title) }

    /// True when two titles most likely describe the same task.
    ///
    /// Japanese has no word boundaries, so similarity is measured on character
    /// bigrams (Dice coefficient) rather than on tokens. Containment still
    /// counts, but only once the shorter title is long enough that a substring
    /// match means something — otherwise a generic "更新する" would swallow
    /// every unrelated title that happens to end the same way.
    public static func isSimilar(_ a: String, _ b: String, threshold: Double = 0.7) -> Bool {
        isSimilar(Fingerprint(a), Fingerprint(b), threshold: threshold)
    }

    /// The same test on prepared titles.
    public static func isSimilar(
        _ a: Fingerprint, _ b: Fingerprint, threshold: Double = 0.7
    ) -> Bool {
        guard !a.key.isEmpty, !b.key.isEmpty else { return false }
        if a.key == b.key { return true }
        let la = a.grams.count
        let lb = b.grams.count
        // Bigram overlap can never exceed the shorter title's bigram count, so
        // the coefficient is capped by the length ratio alone. Titles too far
        // apart in length are ruled out before any comparison at all.
        let shortest = min(a.length, b.length)
        if 2 * Double(min(la, lb)) / Double(la + lb) < threshold {
            return shortest >= 6 && contains(a.key, b.key)
        }
        if shortest >= 6, contains(a.key, b.key) { return true }
        return dice(a.grams, b.grams) >= threshold
    }

    private static func contains(_ a: String, _ b: String) -> Bool {
        a.contains(b) || b.contains(a)
    }

    /// Bigram overlap as a multiset, scaled to 0...1.
    static func dice(_ left: [UInt64], _ right: [UInt64]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var i = 0
        var j = 0
        var overlap = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                overlap += 1
                i += 1
                j += 1
            } else if left[i] < right[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return 2 * Double(overlap) / Double(left.count + right.count)
    }
}
