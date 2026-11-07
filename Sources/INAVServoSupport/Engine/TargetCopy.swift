import Foundation

/// Creates a patched copy of a target as a new target (e.g. MATEKF405 -> MATEKF405_SERVO), so the original
/// stays untouched and a `git pull` never conflicts with the servo changes.
///
/// inav's CMake defines every target name as a macro (`target_compile_definitions(... ${name})`) and boards with
/// several variants test those macros (`#ifdef MATEKF405OSD`). The copy therefore renames every variant and adds a
/// small block to target.h that defines the original variant macro again when the renamed variant is built.
enum TargetCopy {
    enum CopyError: LocalizedError {
        case invalidName(String)
        case exists(String)
        var errorDescription: String? {
            switch self {
            case .invalidName(let n): return "'\(n)' is not a valid target name (use A–Z, 0–9 and _, 3–40 characters)."
            case .exists(let n): return "A target folder named \(n) already exists."
            }
        }
    }

    static func isValidName(_ name: String) -> Bool {
        name.firstMatch("^[A-Z][A-Z0-9_]{2,39}$") != nil
    }

    static func defaultName(for target: TargetInfo) -> String { target.name + "_SERVO" }

    /// Original variant name -> name in the copy.
    static func variantMap(target: TargetInfo, newName: String) -> [(old: String, new: String)] {
        let variants = target.variants.isEmpty ? [target.name] : target.variants
        // MATEKF405 -> MATEKF405_SERVO turns the variant MATEKF405OSD into MATEKF405OSD_SERVO;
        // a free name (MYWING) turns it into MYWING_OSD.
        let suffix = newName.hasPrefix(target.name) ? String(newName.dropFirst(target.name.count)) : nil
        return variants.map { v -> (old: String, new: String) in
            if v == target.name { return (old: v, new: newName) }
            if let sfx = suffix, !sfx.isEmpty { return (old: v, new: v + sfx) }
            if v.hasPrefix(target.name) { return (old: v, new: newName + "_" + String(v.dropFirst(target.name.count))) }
            return (old: v, new: newName + "_" + v)
        }
    }

    static func cmake(_ original: String, map: [(old: String, new: String)]) -> String {
        var lines = original.sourceLines
        for i in lines.indices {
            for (old, new) in map {
                let pattern = #"(target_\w+\s*\(\s*)"# + NSRegularExpression.escapedPattern(for: old) + #"\b"#
                if let r = lines[i].range(of: pattern, options: .regularExpression) {
                    let matched = String(lines[i][r])
                    let replaced = matched.replacingOccurrences(of: old, with: new)
                    lines[i].replaceSubrange(r, with: replaced)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func preamble(target: TargetInfo, map: [(old: String, new: String)]) -> String {
        var lines = ["",
                     "// Copy of target \(target.name) with servo outputs on UART/LED pads – created by \(Patcher.tag).",
                     "// The original variant macros are defined again so all #ifdef blocks keep working."]
        for (old, new) in map {
            lines.append("#if defined(\(new)) && !defined(\(old))")
            lines.append("#define \(old)")
            lines.append("#endif")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func insertPreamble(_ preamble: String, into header: String) -> String {
        var lines = header.sourceLines
        if let i = lines.firstIndex(where: { $0.trimmed.hasPrefix("#pragma once") }) {
            lines.insert(preamble, at: i + 1)
        } else {
            lines.insert(preamble, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// All files of the new target folder: name -> content.
    static func files(target: TargetInfo, plan: PatchPlan, newName: String) -> [(name: String, content: String)] {
        let map = variantMap(target: target, newName: newName)
        var result = [(name: String, content: String)]()
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: target.directory.path)) ?? []).sorted()
        for name in names where !name.hasSuffix(".servo-backup") && !name.hasPrefix(".") {
            let url = target.directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            switch name {
            case "target.c":
                result.append((name, plan.newC))
            case "target.h":
                result.append((name, insertPreamble(preamble(target: target, map: map), into: plan.newH)))
            case "config.c":
                result.append((name, plan.newConfig ?? target.configText ?? ""))
            case "CMakeLists.txt":
                let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                result.append((name, cmake(original, map: map)))
            default:
                if let text = try? String(contentsOf: url, encoding: .utf8) { result.append((name, text)) }
            }
        }
        return result
    }

    @discardableResult
    static func create(root: URL, target: TargetInfo, plan: PatchPlan, newName: String) throws -> URL {
        guard isValidName(newName) else { throw CopyError.invalidName(newName) }
        let dir = TargetParser.targetsDirectory(root).appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: dir.path) { throw CopyError.exists(newName) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for (name, content) in files(target: target, plan: plan, newName: newName) {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }
}

/// Unified diff (git compatible) for exporting the changes as a .patch file.
/// Verified with `git apply` (changes at start/middle/end, new files, files without trailing newline).
enum UnifiedDiff {
    private enum Op { case same(String), del(String), add(String) }

    /// Marks a last line that has no trailing newline, so "c" and "c\n" compare as different lines.
    private static let noNewline = "\u{1}"

    private static func split(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") {
            lines.removeLast()
        } else {
            lines[lines.count - 1] += noNewline
        }
        return lines
    }

    private static func emit(_ prefix: String, _ line: String) -> String {
        if line.hasSuffix(noNewline) {
            return prefix + String(line.dropLast()) + "\n\\ No newline at end of file\n"
        }
        return prefix + line + "\n"
    }

    private static func ops(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out = [Op]()
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j]) { out.append(.add(b[j])); j += 1 }
            else { out.append(.del(a[i])); i += 1 }
        }
        return out
    }

    /// Diff of one file; `old == nil` creates the file. Returns "" when nothing changed.
    static func file(path: String, old: String?, new: String, context: Int = 3) -> String {
        let a = Self.split(old)
        let b = Self.split(new)
        if old != nil && a == b { return "" }
        let o = Self.ops(a, b)
        var oldPos = [Int](), newPos = [Int]()
        var oi = 0, ni = 0
        for op in o {
            oldPos.append(oi); newPos.append(ni)
            switch op {
            case .same: oi += 1; ni += 1
            case .del: oi += 1
            case .add: ni += 1
            }
        }
        let changed = o.indices.filter { k -> Bool in
            if case .same = o[k] { return false }
            return true
        }
        var text = "diff --git a/\(path) b/\(path)\n"
        if old == nil { text += "new file mode 100644\n" }
        text += "--- " + (old == nil ? "/dev/null" : "a/\(path)") + "\n"
        text += "+++ b/\(path)\n"
        guard let first = changed.first else { return old == nil ? text : "" }

        var hunks = [(Int, Int)]()
        var start = max(0, first - context), end = min(o.count - 1, first + context)
        for c in changed.dropFirst() {
            if c - context <= end + 1 {
                end = min(o.count - 1, c + context)
            } else {
                hunks.append((start, end))
                start = max(0, c - context)
                end = min(o.count - 1, c + context)
            }
        }
        hunks.append((start, end))

        for (s, e) in hunks {
            var oldCount = 0, newCount = 0
            var body = ""
            for k in s...e {
                switch o[k] {
                case .same(let l): oldCount += 1; newCount += 1; body += Self.emit(" ", l)
                case .del(let l): oldCount += 1; body += Self.emit("-", l)
                case .add(let l): newCount += 1; body += Self.emit("+", l)
                }
            }
            let oldStart = oldCount == 0 ? oldPos[s] : oldPos[s] + 1
            let newStart = newCount == 0 ? newPos[s] : newPos[s] + 1
            text += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + body
        }
        return text
    }
}
