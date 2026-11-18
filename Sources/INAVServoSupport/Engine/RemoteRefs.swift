import Foundation

/// A branch or tag of a remote git repository (from `git ls-remote`).
struct RemoteRef: Identifiable, Hashable {
    enum Kind: String { case branch, tag }
    let name: String
    let kind: Kind
    var id: String { kind.rawValue + "/" + name }
}

enum RemoteRefs {
    /// Parses `git ls-remote --heads --tags` output. Peeled tag lines (`^{}`) are skipped.
    static func parse(_ text: String) -> [RemoteRef] {
        var seen = Set<String>()
        var refs: [RemoteRef] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let ref = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if ref.hasSuffix("^{}") { continue }
            let item: RemoteRef
            if ref.hasPrefix("refs/heads/") {
                item = RemoteRef(name: String(ref.dropFirst("refs/heads/".count)), kind: .branch)
            } else if ref.hasPrefix("refs/tags/") {
                item = RemoteRef(name: String(ref.dropFirst("refs/tags/".count)), kind: .tag)
            } else { continue }
            if seen.insert(item.id).inserted { refs.append(item) }
        }
        return sort(refs)
    }

    /// master / main first, then version, release and maintenance branches / tags newest first
    /// (`maintenance-11.x`, `release/9.1`, `9.0.1`), then the rest alphabetically.
    static func sort(_ refs: [RemoteRef]) -> [RemoteRef] {
        func rank(_ r: RemoteRef) -> Int {
            if r.name == "master" || r.name == "main" { return 0 }
            let n = r.name.lowercased()
            guard n.range(of: #"^(v?\d|release[-/_]?\d|release/|maintenance[-/_])"#, options: .regularExpression) != nil
            else { return 2 }
            return (versionKey(r.name).first ?? 0) > 999 ? 2 : 1   // date-style tags (v20240613.18) go last
        }
        return refs.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if ra == 1 {   // version-like: newest first (11.x > 10.x > 9.1 > 8.0.1)
                let va = versionKey(a.name), vb = versionKey(b.name)
                if va != vb { return va.lexicographicallyPrecedes(vb) == false }
                return a.name.compare(b.name, options: [.numeric, .caseInsensitive]) == .orderedDescending
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Sort key of a version-like name: the first dotted number group, then a pre-release rank so a
    /// release sorts above its RCs. "maintenance-8.x.x" → [8, 1_000_000], "9.0.1-RC2" → [9, 0, 1, 2].
    static func versionKey(_ name: String) -> [Int] {
        guard let r = name.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
        var key = name[r].split(separator: ".").compactMap { Int($0) }
        let rest = name[r.upperBound...].lowercased()
        if rest.range(of: #"(rc|alpha|beta|pre)"#, options: .regularExpression) != nil {
            key.append(Int(rest.filter(\.isNumber)) ?? 0)
        } else {
            key.append(1_000_000)
        }
        return key
    }

    /// Loads branches and tags of `url` in the background; `completion` runs on the main queue
    /// with the refs, or with an error message.
    static func load(url: String, completion: @escaping (Result<[RemoteRef], RemoteRefsError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["ls-remote", "--heads", "--tags", url]
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let result: Result<[RemoteRef], RemoteRefsError>
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    result = .success(parse(String(data: data, encoding: .utf8) ?? ""))
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    result = .failure(RemoteRefsError(message: msg.isEmpty ? "git ls-remote failed (status \(p.terminationStatus))" : msg))
                }
            } catch {
                result = .failure(RemoteRefsError(message: "Could not start git: \(error.localizedDescription)"))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

struct RemoteRefsError: Error { let message: String }
