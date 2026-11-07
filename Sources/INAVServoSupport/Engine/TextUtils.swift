import Foundation

extension String {
    /// All matches of `pattern`; each match is returned as [fullMatch, group1, group2, ...].
    /// Groups that did not participate are returned as "".
    func regexMatches(_ pattern: String, multiline: Bool = false) -> [[String]] {
        var options: NSRegularExpression.Options = []
        if multiline { options.insert(.anchorsMatchLines) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = self as NSString
        let results = re.matches(in: self, options: [], range: NSRange(location: 0, length: ns.length))
        return results.map { m in
            (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// First match (full + groups) or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        return regexMatches(pattern).first
    }

    /// NSRange of the first match of `pattern`.
    func firstMatchRange(_ pattern: String) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.range
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The part of a line before a `//` comment.
    var codePart: String {
        if let r = range(of: "//") { return String(self[..<r.lowerBound]) }
        return self
    }

    /// The text of a `//` comment on this line (without the slashes), or "".
    var lineComment: String {
        if let r = range(of: "//") { return String(self[r.upperBound...]).trimmed }
        return ""
    }

    /// Split a source text into lines, keeping empty trailing line semantics stable.
    var sourceLines: [String] {
        return components(separatedBy: "\n")
    }

    func padded(to width: Int) -> String {
        if count >= width { return self }
        return self + String(repeating: " ", count: width - count)
    }
}

/// Replaces every character inside /* ... */ comments with spaces (newlines are kept),
/// so line numbers and column positions stay identical to the original text.
func stripBlockComments(_ text: String) -> String {
    var out = [Character]()
    out.reserveCapacity(text.count)
    let chars = Array(text)
    var i = 0
    var inBlock = false
    while i < chars.count {
        let c = chars[i]
        if !inBlock, c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            inBlock = true
            out.append(" "); out.append(" ")
            i += 2
            continue
        }
        if inBlock, c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
            inBlock = false
            out.append(" "); out.append(" ")
            i += 2
            continue
        }
        if inBlock {
            out.append(c == "\n" ? "\n" : " ")
        } else {
            out.append(c)
        }
        i += 1
    }
    return String(out)
}

/// A GPIO pin name such as PA2 or PE14.
func isPinName(_ s: String) -> Bool {
    return s.firstMatch("^P[A-K][0-9]{1,2}$") != nil
}
