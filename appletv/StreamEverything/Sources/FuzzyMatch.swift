import Foundation

/// Approximate substring matching for search. A typo, a swapped pair, a dropped or
/// doubled letter should still find the title; spaces never matter because search
/// keys are letters and digits only.
enum FuzzyMatch {
    /// How many edits a query of this length may be off by and still match.
    static func allowance(for length: Int) -> Int {
        length >= 8 ? 2 : (length >= 4 ? 1 : 0)
    }

    /// Smallest edit distance between `pattern` and any substring of `text`
    /// (Sellers' algorithm), or nil when it exceeds `maxDistance`. ASCII bytes only,
    /// which is what search keys are.
    static func substringDistance(pattern: [UInt8], text: String, maxDistance: Int,
                                  previous: inout [Int], current: inout [Int]) -> Int? {
        let m = pattern.count
        guard m > 0 else { return nil }
        if previous.count < m + 1 { previous = Array(repeating: 0, count: m + 1); current = previous }
        for i in 0...m { previous[i] = i }
        // A swapped pair ("simpsnos") counts as one edit, not two: keep the column
        // before the previous one for the transposition case.
        var beforePrevious = previous
        var previousByte: UInt8 = 0
        var best = m
        for byte in text.utf8 {
            current[0] = 0
            for i in 1...m {
                let cost = pattern[i - 1] == byte ? 0 : 1
                var value = min(previous[i] + 1, current[i - 1] + 1, previous[i - 1] + cost)
                if i > 1, pattern[i - 1] == previousByte, pattern[i - 2] == byte {
                    value = min(value, beforePrevious[i - 2] + 1)
                }
                current[i] = value
            }
            if current[m] < best { best = current[m] }
            let finished = beforePrevious
            beforePrevious = previous
            previous = current
            current = finished
            previousByte = byte
        }
        return best <= maxDistance ? best : nil
    }
}
