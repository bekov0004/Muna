import Foundation

/// Removes tracking parameters from a copied link, as linux/src/utils/cleanUrl.js does.
/// A link is only changed when it is the whole text.
public enum LinkCleaner {
    /// Parameters that only say where a link was shared from or who clicked it.
    static let tracking: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
        "_hsenc", "_hsmi", "vero_id", "ref_src", "ref_url", "spm", "share_id", "si",
    ]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        if tracking.contains(lower) { return true }
        // utm_[a-z0-9_]+
        guard lower.hasPrefix("utm_"), lower.count > 4 else { return false }
        return lower.dropFirst(4).unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    /// The cleaned link, or nil when the text is not a link or has nothing to remove.
    public static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.hasPrefix("https://") ? 8 : trimmed.hasPrefix("http://") ? 7 : 0
        guard scheme > 0, trimmed.count > scheme,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        var withoutFragment = Substring(trimmed)
        var fragment = Substring("")
        if let hash = trimmed.firstIndex(of: "#") {
            withoutFragment = trimmed[..<hash]
            fragment = trimmed[hash...]
        }
        guard let question = withoutFragment.firstIndex(of: "?") else { return nil }
        let base = withoutFragment[..<question]
        let parameters = withoutFragment[withoutFragment.index(after: question)...]
            .split(separator: "&", omittingEmptySubsequences: true)
        let kept = parameters.filter { parameter in
            let name = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return !isTracking(String(name))
        }
        guard kept.count != parameters.count else { return nil }
        return base + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
    }
}
