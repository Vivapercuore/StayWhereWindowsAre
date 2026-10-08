import CoreGraphics
import Foundation

/// Pairs saved window records with live windows of the same app.
///
/// Within one login session a window keeps its CGWindowID, so identity wins. Across app restarts and reboots ids
/// change, and the pairing falls back to title similarity, size and stacking order.
enum WindowMatcher {
    struct Pair: Equatable, Sendable {
        var savedIndex: Int
        var liveIndex: Int
        var score: Double
        var isIdentity: Bool
    }

    static let defaultMinimumScore = 0.45

    static func match(
        saved: [WindowRecord],
        live: [LiveWindowDescriptor],
        sessionID: String,
        displays: [DisplayInfo],
        minimumScore: Double = defaultMinimumScore
    ) -> [Pair] {
        guard !saved.isEmpty, !live.isEmpty else { return [] }
        var candidates: [Pair] = []
        let orderSpan = Double(max(saved.count, live.count, 1))
        let liveIdentities = Set(live.map { "\($0.pid):\($0.windowID)" })
        for (si, record) in saved.enumerated() {
            let isAlive = record.sessionID == sessionID && liveIdentities.contains("\(record.pid):\(record.windowID)")
            for (li, window) in live.enumerated() {
                if isAlive {
                    // The saved window still exists under its own id; it can only pair with itself.
                    if record.windowID == window.windowID && record.pid == window.pid {
                        candidates.append(Pair(savedIndex: si, liveIndex: li, score: 2, isIdentity: true))
                    }
                    continue
                }
                let score = similarity(record: record, window: window, orderSpan: orderSpan, displays: displays)
                if score >= minimumScore {
                    candidates.append(Pair(savedIndex: si, liveIndex: li, score: score, isIdentity: false))
                }
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDistance = abs(saved[lhs.savedIndex].order - live[lhs.liveIndex].order)
            let rhsDistance = abs(saved[rhs.savedIndex].order - live[rhs.liveIndex].order)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return (lhs.savedIndex, lhs.liveIndex) < (rhs.savedIndex, rhs.liveIndex)
        }
        var usedSaved = Set<Int>(), usedLive = Set<Int>()
        var result: [Pair] = []
        for pair in candidates where !usedSaved.contains(pair.savedIndex) && !usedLive.contains(pair.liveIndex) {
            usedSaved.insert(pair.savedIndex)
            usedLive.insert(pair.liveIndex)
            result.append(pair)
        }
        return result.sorted { $0.savedIndex < $1.savedIndex }
    }

    static func similarity(record: WindowRecord, window: LiveWindowDescriptor, orderSpan: Double, displays: [DisplayInfo] = []) -> Double {
        let titleScore: Double
        let a = normalizeTitle(record.title), b = normalizeTitle(window.title)
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): titleScore = 0.5
        case (true, false), (false, true): titleScore = 0.2
        default: titleScore = a == b ? 1 : textSimilarity(a, b)
        }
        let sizeScore = sizeSimilarity(record.frame.size, window.frame.size)
        let orderScore = 1 - min(1, Double(abs(record.order - window.order)) / orderSpan)
        let subroleMatches = record.subrole == window.subrole
        // 同显示器？窗口要在不同的显示器上，那它们大概率不是同一个窗口
        let displayMatch = !displays.isEmpty && record.displayUUID != nil
            && FrameResolver.display(containing: window.frame, in: displays)?.uuid == record.displayUUID
        let displayScore = displays.isEmpty || record.displayUUID == nil ? 0 : (displayMatch ? 0.1 : -0.3)
        var score = 0.55 * titleScore + 0.20 * sizeScore + 0.05 * orderScore + 0.1 * displayScore
            + (subroleMatches ? 0.05 : 0)
        if !subroleMatches { score *= 0.5 }
        return max(0, score)
    }

    static func sizeSimilarity(_ a: CGSize, _ b: CGSize) -> Double {
        let dw = abs(a.width - b.width) / max(a.width, b.width, 1)
        let dh = abs(a.height - b.height) / max(a.height, b.height, 1)
        return max(0, 1 - Double(dw + dh))
    }

    private static let counterPrefix = try! NSRegularExpression(pattern: #"^\s*[\(\[]\d+[\)\]]\s*"#)
    private static let editedSuffix = try! NSRegularExpression(pattern: #"\s*[—–-]\s*(edited|已编辑|已修改)\s*$"#, options: [.caseInsensitive])

    /// Strips noise that changes while a window keeps its identity: unread counters, "edited" markers, bullets.
    static func normalizeTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for regex in [counterPrefix, editedSuffix] {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "•", with: " ").replacingOccurrences(of: "●", with: " ")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.lowercased()
    }

    /// Best of edit-distance ratio and token overlap, in 0...1.
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        max(levenshteinRatio(a, b), tokenOverlap(a, b))
    }

    static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a.prefix(160)), y = Array(b.prefix(160))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    private static func tokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        var word = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.isIdeographic {
                if !word.isEmpty { result.insert(word); word = "" }
                result.insert(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                result.insert(word)
                word = ""
            }
        }
        if !word.isEmpty { result.insert(word) }
        return result
    }
}
