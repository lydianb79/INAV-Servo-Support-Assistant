import Foundation

struct DefineEntry: Hashable {
    let line: Int      // 0-based line index in target.h
    let value: String
}

/// One DEF_TIM(...) line of target.c.
struct TimerEntry: Identifiable, Hashable {
    let line: Int          // 0-based line index in target.c
    let args: [String]     // tim, ch, pin, usage, flags, dma
    let comment: String
    let active: Bool       // false when the line is commented out

    var id: Int { line }
    var timer: String { args[0] }
    var channel: String { args[1] }
    var pin: String { args[2] }
    var usage: String { args[3] }
    var timerChannel: TimerChannel { TimerChannel(timer: timer, channel: channel) }

    func has(_ flag: String) -> Bool {
        if usage.contains("TIM_USE_OUTPUT_AUTO") && (flag == "TIM_USE_MOTOR" || flag == "TIM_USE_SERVO") {
            return true
        }
        return usage.range(of: flag + "\\b", options: .regularExpression) != nil
    }

    var isOutput: Bool { has("TIM_USE_MOTOR") || has("TIM_USE_SERVO") }
    var isMotorOnly: Bool { has("TIM_USE_MOTOR") && !has("TIM_USE_SERVO") }
    var isServoOnly: Bool { has("TIM_USE_SERVO") && !has("TIM_USE_MOTOR") }
    var isAuto: Bool { has("TIM_USE_MOTOR") && has("TIM_USE_SERVO") }

    var roleDescription: String {
        if isAuto { return "Motor/Servo (auto)" }
        if isMotorOnly { return "Motor" }
        if isServoOnly { return "Servo" }
        if has("TIM_USE_LED") { return "LED strip" }
        if has("TIM_USE_BEEPER") { return "Beeper" }
        if has("TIM_USE_PPM") { return "PPM input" }
        if has("TIM_USE_PWM") { return "PWM input" }
        if has("TIM_USE_PINIO") { return "PINIO" }
        return "Timer (ANY)"
    }
}

struct TargetSummary: Identifiable, Hashable {
    let name: String
    let mcuFunction: String?
    let variants: [String]
    var id: String { name }
    var mcu: MCUInfo? { mcuFunction.flatMap { MCUInfo.all[$0] } }
    var mcuLabel: String { mcu?.displayName ?? (mcuFunction ?? "unknown") }
    var isSupported: Bool { mcu != nil }
}

enum TargetParserError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let s): return "Cannot read \(s)" }
    }
}

struct TargetInfo {
    let name: String
    let directory: URL
    let mcuFunction: String?
    let variants: [String]
    let hText: String
    let cText: String
    let defines: [String: [DefineEntry]]
    let timers: [TimerEntry]

    var mcu: MCUInfo? { mcuFunction.flatMap { MCUInfo.all[$0] } }
    var activeTimers: [TimerEntry] { timers.filter { $0.active } }
    var hURL: URL { directory.appendingPathComponent("target.h") }
    var cURL: URL { directory.appendingPathComponent("target.c") }

    func firstValue(_ name: String) -> String? { defines[name]?.first?.value }
    func values(_ name: String) -> [String] { defines[name]?.map { $0.value } ?? [] }
}

enum TargetParser {
    static func targetsDirectory(_ root: URL) -> URL {
        return root.appendingPathComponent("src/main/target")
    }

    static func isINAVRoot(_ root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: targetsDirectory(root).path)
            && fm.fileExists(atPath: root.appendingPathComponent("src/main/drivers/timer_def.h").path)
    }

    static func parseCMake(_ text: String) -> (String?, [String]) {
        let matches = text.regexMatches(#"target_(\w+)\s*\(\s*(\w+)"#)
        return (matches.first?[1], matches.map { $0[2] })
    }

    /// Lists all directories in src/main/target that contain target.c/target.h/CMakeLists.txt.
    static func listTargets(root: URL) -> [TargetSummary] {
        let fm = FileManager.default
        let dir = targetsDirectory(root)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var result = [TargetSummary]()
        for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let d = dir.appendingPathComponent(name)
            let files = ["target.c", "target.h", "CMakeLists.txt"]
            guard files.allSatisfy({ fm.fileExists(atPath: d.appendingPathComponent($0).path) }) else { continue }
            let cmake = (try? String(contentsOf: d.appendingPathComponent("CMakeLists.txt"), encoding: .utf8)) ?? ""
            let (fn, variants) = parseCMake(cmake)
            result.append(TargetSummary(name: name, mcuFunction: fn, variants: variants))
        }
        return result
    }

    static func parse(root: URL, name: String) throws -> TargetInfo {
        let d = targetsDirectory(root).appendingPathComponent(name)
        func read(_ f: String) throws -> String {
            guard let s = try? String(contentsOf: d.appendingPathComponent(f), encoding: .utf8) else {
                throw TargetParserError.unreadable("\(name)/\(f)")
            }
            return s
        }
        let cmake = try read("CMakeLists.txt")
        let h = try read("target.h")
        let c = try read("target.c")
        let (fn, variants) = parseCMake(cmake)
        return TargetInfo(name: name, directory: d, mcuFunction: fn, variants: variants,
                          hText: h, cText: c, defines: parseDefines(h), timers: parseTimers(c))
    }

    static func parseDefines(_ text: String) -> [String: [DefineEntry]] {
        var defines = [String: [DefineEntry]]()
        for (i, line) in stripBlockComments(text).sourceLines.enumerated() {
            let code = line.codePart
            guard let m = code.firstMatch(#"^\s*#\s*define\s+(\w+)(?:\s+(.*?))?\s*$"#) else { continue }
            defines[m[1], default: []].append(DefineEntry(line: i, value: m[2].trimmed))
        }
        return defines
    }

    static func parseTimers(_ text: String) -> [TimerEntry] {
        var entries = [TimerEntry]()
        let original = text.sourceLines
        let stripped = stripBlockComments(text).sourceLines
        for (i, line) in stripped.enumerated() {
            var active = true
            var m = line.codePart.firstMatch(#"DEF_TIM\s*\(([^)]*)\)"#)
            if m == nil {
                // commented out line (// DEF_TIM(...) or inside /* */)
                let source = i < original.count ? original[i] : line
                m = source.firstMatch(#"DEF_TIM\s*\(([^)]*)\)"#)
                active = false
            }
            guard let match = m else { continue }
            let args = match[1].split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmed }
            guard args.count >= 6 else { continue }
            let full = i < original.count ? original[i] : line
            var comment = ""
            if let callRange = full.range(of: match[0]) {
                let tail = String(full[callRange.upperBound...])
                comment = tail.lineComment
            }
            entries.append(TimerEntry(line: i, args: args, comment: comment, active: active))
        }
        return entries
    }
}
