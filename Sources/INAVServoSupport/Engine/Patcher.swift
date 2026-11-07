import Foundation

/// One pad the user decided to turn into a servo output.
struct ServoChoice: Hashable {
    let pin: PinAnalysis
    let option: TimerOption
    let mode: UartMode
}

struct PatchPlan {
    let target: TargetInfo
    let newC: String
    let newH: String
    let changes: [String]
    let warnings: [Issue]
    var cChanged: Bool { newC != target.cText }
    var hChanged: Bool { newH != target.hText }
    var hasChanges: Bool { cChanged || hChanged }
}

enum PatchError: LocalizedError {
    case noTimerArray
    case nothingSelected
    case blocked(String)
    var errorDescription: String? {
        switch self {
        case .noTimerArray: return "Could not find the timerHardware[] array in target.c."
        case .nothingSelected: return "No pads selected."
        case .blocked(let s): return s
        }
    }
}

enum Patcher {
    static let tag = "INAV Servo Support Helper"

    static func makePlan(target: TargetInfo, choices: [ServoChoice]) throws -> PatchPlan {
        guard !choices.isEmpty else { throw PatchError.nothingSelected }
        if let bad = choices.first(where: { !$0.option.isUsable }) {
            throw PatchError.blocked("\(bad.pin.pin) → \(bad.option.channel.id) has blocking issues.")
        }
        var changes = [String]()
        var warnings = [Issue]()

        // ---------------- target.c ----------------
        var cLines = target.cText.sourceLines
        var newEntries = [String]()
        var addedOutputs = 0

        let ordered = choices.sorted { ($0.pin.group.sortKey, $0.pin.role, $0.pin.pin) < ($1.pin.group.sortKey, $1.pin.role, $1.pin.pin) }
        for choice in ordered {
            let label = choice.pin.label
            let isLED = choice.pin.group.isLED
            let dedicatedLED = isLED && choice.mode == .dedicated
            switch choice.option.kind {
            case .alreadyServo:
                changes.append("\(choice.pin.pin) (\(label)) already has a servo-capable DEF_TIM – unchanged.")
            case .upgradeExisting(let line):
                guard line < cLines.count else { continue }
                let wasOutput = target.timers.first { $0.line == line }?.isOutput ?? false
                cLines[line] = upgradeLine(cLines[line], label: label, removing: dedicatedLED ? ["TIM_USE_LED"] : [])
                if !wasOutput { addedOutputs += 1 }
                changes.append("target.c line \(line + 1): \(dedicatedLED ? "replaced TIM_USE_LED by" : "added") TIM_USE_SERVO on \(choice.option.channel.id) / \(choice.pin.pin) (\(label)).")
            case .newEntry:
                let tc = choice.option.channel
                let usage = (isLED && choice.mode == .shared) ? "TIM_USE_LED | TIM_USE_SERVO" : "TIM_USE_SERVO"
                let call = "DEF_TIM(\(tc.timer), \(tc.channel), \(choice.pin.pin),"
                let entry = "    " + call.padded(to: 26) + " \(usage), 0, 0), // \(label) -> servo (\(tag))"
                newEntries.append(entry)
                addedOutputs += 1
                changes.append("target.c: new DEF_TIM(\(tc.timer), \(tc.channel), \(choice.pin.pin), \(usage)) for \(label).")
            case .unusable:
                continue
            }
        }

        if !newEntries.isEmpty {
            guard let closing = findTimerArrayClose(cLines) else { throw PatchError.noTimerArray }
            ensureTrailingComma(&cLines, before: closing)
            var block = ["", "    // Servo outputs on UART / LED pads – added by \(tag)"]
            block.append(contentsOf: newEntries)
            // Avoid a double blank line when the array already ends with one.
            if closing > 0, cLines[closing - 1].trimmed.isEmpty { block.removeFirst() }
            cLines.insert(contentsOf: block, at: closing)
        }

        // ---------------- target.h ----------------
        var hLines = target.hText.sourceLines
        let disabledNote = "    // disabled: pad used as servo output (\(tag))"

        // Dedicated UARTs
        let dedicated = Set(choices.filter { $0.mode == .dedicated }.compactMap { $0.pin.group.uartNumber })
        for n in dedicated.sorted() {
            var disabled = 0
            for i in hLines.indices {
                let code = hLines[i].codePart
                if code.firstMatch(#"^\s*#\s*define\s+(USE_UART\#(n)\b|UART\#(n)_\w+)"#) != nil {
                    hLines[i] = "// " + hLines[i] + disabledNote
                    disabled += 1
                }
            }
            if disabled > 0 {
                changes.append("target.h: disabled UART\(n) (\(disabled) define line\(disabled == 1 ? "" : "s") commented out).")
            }
            if target.firstValue("SERIALRX_UART") == "SERIAL_PORT_USART\(n)" {
                warnings.append(Issue(severity: .warning, text: "SERIALRX_UART points to the disabled UART\(n). Change the default receiver port in target.h or in the configurator."))
            }
            for k in Analyzer.softSerialDefines {
                for v in target.values(k) where choices.contains(where: { $0.pin.group == .uart(n) && $0.pin.pin == v }) {
                    warnings.append(Issue(severity: .warning, text: "\(k) uses \(v), which is now a servo pad."))
                }
            }
        }

        if !dedicated.isEmpty {
            var adjusted = false
            for i in hLines.indices {
                let code = hLines[i].codePart
                if let m = code.firstMatch(#"^(\s*#\s*define\s+SERIAL_PORT_COUNT\s+)([0-9]+)(.*)$"#), let v = Int(m[2]) {
                    let newValue = max(1, v - dedicated.count)
                    hLines[i] = m[1] + String(newValue) + m[3] + "  // was \(v) (\(tag))"
                    changes.append("target.h line \(i + 1): SERIAL_PORT_COUNT \(v) → \(newValue).")
                    adjusted = true
                }
            }
            if !adjusted {
                warnings.append(Issue(severity: .warning, text: "SERIAL_PORT_COUNT was not found as a plain number – adjust it manually."))
            }
        }

        // Dedicated LED pad: switch off the LED strip driver
        let ledChoices = choices.filter { $0.pin.group.isLED && !$0.option.isAlreadyServo }
        if ledChoices.contains(where: { $0.mode == .dedicated }) {
            var disabled = 0
            var featureRemoved = false
            for i in hLines.indices {
                let code = hLines[i].codePart
                if code.firstMatch(#"^\s*#\s*define\s+(USE_LED_STRIP\b|WS2811_\w+|LED_STRIP_TIMER\b)"#) != nil {
                    hLines[i] = "// " + hLines[i] + disabledNote
                    disabled += 1
                } else if code.firstMatch(#"^\s*#\s*define\s+DEFAULT_FEATURES\b"#) != nil, code.contains("FEATURE_LED_STRIP") {
                    var l = hLines[i]
                    let rules: [(String, String)] = [(#"\s*\|\s*FEATURE_LED_STRIP\b"#, ""),
                                                     (#"\bFEATURE_LED_STRIP\s*\|\s*"#, ""),
                                                     (#"\bFEATURE_LED_STRIP\b"#, "0")]
                    for (pattern, replacement) in rules {
                        if let r = l.range(of: pattern, options: .regularExpression) {
                            l.replaceSubrange(r, with: replacement)
                            break
                        }
                    }
                    hLines[i] = l + "  // FEATURE_LED_STRIP removed (\(tag))"
                    featureRemoved = true
                    changes.append("target.h line \(i + 1): removed FEATURE_LED_STRIP from DEFAULT_FEATURES.")
                }
            }
            if !featureRemoved, target.hText.contains("FEATURE_LED_STRIP") {
                warnings.append(Issue(severity: .warning, text: "FEATURE_LED_STRIP is still referenced in target.h (multi-line DEFAULT_FEATURES?) – remove it manually."))
            }
            if disabled > 0 {
                changes.append("target.h: disabled the LED strip driver (\(disabled) define line\(disabled == 1 ? "" : "s") commented out).")
            }
        } else if !ledChoices.isEmpty, target.values("DEFAULT_FEATURES").joined().contains("FEATURE_LED_STRIP") {
            warnings.append(Issue(severity: .warning, text: "FEATURE_LED_STRIP is enabled by default – disable LED_STRIP in the configurator, otherwise the LED pad stays an LED output."))
        }

        if addedOutputs > 0 {
            var found = false
            for i in hLines.indices {
                let code = hLines[i].codePart
                if let m = code.firstMatch(#"^(\s*#\s*define\s+MAX_PWM_OUTPUT_PORTS\s+)([0-9]+)(.*)$"#), let v = Int(m[2]) {
                    let newValue = v + addedOutputs
                    hLines[i] = m[1] + String(newValue) + m[3] + "  // was \(v) (\(tag))"
                    changes.append("target.h line \(i + 1): MAX_PWM_OUTPUT_PORTS \(v) → \(newValue).")
                    found = true
                }
            }
            if !found {
                changes.append("target.h: MAX_PWM_OUTPUT_PORTS not defined – inav default applies.")
            }
        }

        let newC = cLines.joined(separator: "\n")
        let newH = hLines.joined(separator: "\n")
        return PatchPlan(target: target, newC: newC, newH: newH, changes: changes, warnings: warnings)
    }

    /// Adds TIM_USE_SERVO to the usage argument of the DEF_TIM call on `line`
    /// and drops the flags listed in `removing` (e.g. TIM_USE_LED for a dedicated LED pad).
    static func upgradeLine(_ line: String, label: String, removing: [String] = []) -> String {
        let ns = line as NSString
        guard let range = line.firstMatchRange(#"DEF_TIM\s*\(([^)]*)\)"#) else { return line }
        let call = ns.substring(with: range)
        guard let open = call.firstIndex(of: "("), let close = call.lastIndex(of: ")") else { return line }
        let inner = String(call[call.index(after: open)..<close])
        var args = inner.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        guard args.count >= 4 else { return line }
        var flags = args[3].split(separator: "|").map { String($0).trimmed }
            .filter { !$0.isEmpty && $0 != "TIM_USE_ANY" && $0 != "0" && !removing.contains($0) }
        if !flags.contains("TIM_USE_SERVO") && !flags.contains("TIM_USE_OUTPUT_AUTO") { flags.append("TIM_USE_SERVO") }
        // keep the original leading whitespace of the argument
        let leading = String(args[3].prefix { $0 == " " || $0 == "\t" })
        args[3] = leading + flags.joined(separator: " | ")
        let newCall = String(call[...open]) + args.joined(separator: ",") + ")"
        var result = ns.replacingCharacters(in: range, with: newCall)
        if result.contains("//") {
            result += " | \(label) servo (\(tag))"
        } else {
            result += " // \(label) servo (\(tag))"
        }
        return result
    }

    /// Index of the line that closes `timerHardware[] = { ... };`.
    static func findTimerArrayClose(_ lines: [String]) -> Int? {
        let stripped = stripBlockComments(lines.joined(separator: "\n")).sourceLines
        guard let start = stripped.firstIndex(where: { $0.contains("timerHardware") && $0.contains("[") && $0.contains("=") }) else {
            return nil
        }
        var depth = 0
        var opened = false
        for i in start..<stripped.count {
            for ch in stripped[i].codePart {
                if ch == "{" { depth += 1; opened = true }
                if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { return i }
        }
        return nil
    }

    /// Makes sure the last active DEF_TIM line before `index` ends with a comma.
    static func ensureTrailingComma(_ lines: inout [String], before index: Int) {
        var i = index - 1
        while i >= 0 {
            let code = lines[i].codePart
            if code.trimmed.isEmpty || code.trimmed.hasPrefix("#") { i -= 1; continue }
            if let r = code.range(of: #"DEF_TIM\s*\([^)]*\)"#, options: .regularExpression) {
                let after = String(code[r.upperBound...]).trimmed
                if !after.hasPrefix(",") {
                    let offset = code.distance(from: code.startIndex, to: r.upperBound)
                    var l = lines[i]
                    l.insert(",", at: l.index(l.startIndex, offsetBy: offset))
                    lines[i] = l
                }
            }
            return
        }
    }
}

// MARK: - Line diff

struct DiffLine: Identifiable, Hashable {
    enum Kind { case same, added, removed, gap }
    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum LineDiff {
    /// LCS based line diff, collapsed to hunks with `context` lines around changes.
    static func diff(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let a = old.sourceLines, b = new.sourceLines
        let n = a.count, m = b.count
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var raw = [(DiffLine.Kind, String, Int?, Int?)]()
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && a[i] == b[j] {
                raw.append((.same, a[i], i + 1, j + 1)); i += 1; j += 1
            } else if j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                raw.append((.added, b[j], nil, j + 1)); j += 1
            } else {
                raw.append((.removed, a[i], i + 1, nil)); i += 1
            }
        }
        var keep = [Bool](repeating: false, count: raw.count)
        for (k, r) in raw.enumerated() where r.0 != .same {
            for x in max(0, k - context)...min(raw.count - 1, k + context) { keep[x] = true }
        }
        var out = [DiffLine]()
        var skipping = false
        for (k, r) in raw.enumerated() {
            if keep[k] {
                skipping = false
                out.append(DiffLine(id: out.count, kind: r.0, text: r.1, oldNumber: r.2, newNumber: r.3))
            } else if !skipping {
                skipping = true
                out.append(DiffLine(id: out.count, kind: .gap, text: "…", oldNumber: nil, newNumber: nil))
            }
        }
        return out
    }
}
