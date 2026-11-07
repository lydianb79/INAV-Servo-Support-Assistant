import Foundation

enum Severity: Int, Comparable, Hashable {
    case info = 0
    case warning = 1
    case blocker = 3
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct Issue: Hashable, Identifiable {
    let severity: Severity
    let text: String
    var id: String { "\(severity.rawValue)|\(text)" }
}

/// Where a pad comes from: a UART or the LED strip output.
enum PadKind: Hashable {
    case uart(Int)
    case led

    var id: String {
        switch self {
        case .uart(let n): return "UART\(n)"
        case .led: return "LED"
        }
    }
    var title: String {
        switch self {
        case .uart(let n): return "UART\(n)"
        case .led: return "LED strip pad"
        }
    }
    var uartNumber: Int? {
        if case .uart(let n) = self { return n }
        return nil
    }
    var isLED: Bool { self == .led }
    var sortKey: Int {
        switch self {
        case .uart(let n): return n
        case .led: return 100
        }
    }
}

enum OptionKind: Hashable {
    case alreadyServo(line: Int)      // pin already has a DEF_TIM with TIM_USE_SERVO
    case upgradeExisting(line: Int)   // pin has a DEF_TIM without servo flag -> add TIM_USE_SERVO
    case newEntry                     // add a new DEF_TIM line
    case unusable

    var label: String {
        switch self {
        case .alreadyServo: return "already servo-capable"
        case .upgradeExisting: return "add TIM_USE_SERVO to existing entry"
        case .newEntry: return "new DEF_TIM entry"
        case .unusable: return "not usable"
        }
    }
}

struct TimerOption: Identifiable, Hashable {
    let channel: TimerChannel
    let kind: OptionKind
    let detail: String
    var issues: [Issue]
    /// Motor outputs on the same timer that lose their motor role (converted to servo or disabled).
    var freesMotors: [TimerEntry] = []
    /// Motor outputs on the very same timer channel – they must be disabled (one channel = one pin).
    var disablesEntries: [TimerEntry] = []

    var id: String { channel.id }
    var takesMotors: Bool { !freesMotors.isEmpty || !disablesEntries.isEmpty }
    var affectedMotorLines: Set<Int> { Set((freesMotors + disablesEntries).map { $0.line }) }
    var isAlreadyServo: Bool {
        if case .alreadyServo = kind { return true }
        return false
    }
    var isUsable: Bool { kind != .unusable && !issues.contains { $0.severity == .blocker } }
    var score: Int {
        if kind == .unusable { return 100_000 }
        // options that keep all motors are always preferred
        return issues.reduce(0) { $0 + $1.severity.rawValue * 10 } + (takesMotors ? 50 + 5 * affectedMotorLines.count : 0)
    }
    var worstSeverity: Severity { issues.map { $0.severity }.max() ?? .info }
}

struct PinAnalysis: Identifiable, Hashable {
    let group: PadKind
    let role: String          // TX / RX / LED
    let pin: String
    let options: [TimerOption]
    let existing: TimerEntry?
    var notes: [Issue]

    var id: String { "\(group.id)-\(role)-\(pin)" }
    var label: String { group.isLED ? "LED pad \(pin)" : "\(group.id) \(role)" }
    var best: TimerOption? { options.first { $0.isUsable } }
    var isCandidate: Bool { best != nil }
    var isAlreadyServo: Bool {
        if case .alreadyServo = best?.kind { return true }
        return false
    }
}

enum UartMode: String, CaseIterable, Identifiable, Hashable {
    case shared = "Shared"
    case dedicated = "Dedicated"
    var id: String { rawValue }

    /// Segment title that says what the mode means.
    func title(for kind: PadKind) -> String {
        switch (self, kind) {
        case (.shared, .uart): return "Shared – UART or servo"
        case (.shared, .led): return "Shared – LED or servo"
        case (.dedicated, _): return "Dedicated – servo only"
        }
    }

    func explanation(for kind: PadKind) -> String {
        switch (self, kind) {
        case (.shared, .uart):
            return "UART stays defined. inav uses the pad as servo output only while the UART has no function assigned in the Ports tab."
        case (.dedicated, .uart):
            return "UART definition is commented out in target.h and SERIAL_PORT_COUNT is reduced; the pads become permanent servo outputs."
        case (.shared, .led):
            return "TIM_USE_SERVO is added next to TIM_USE_LED. The pad is a servo while the LED_STRIP feature is disabled, and an LED strip output when it is enabled."
        case (.dedicated, .led):
            return "TIM_USE_LED is replaced by TIM_USE_SERVO and USE_LED_STRIP / WS2811_* are commented out in target.h; the pad becomes a permanent servo output."
        }
    }
}

/// A set of pads that are switched together (one UART, or the LED strip output).
struct PadGroup: Identifiable, Hashable {
    let kind: PadKind
    var pins: [PinAnalysis]
    var notes: [Issue]
    let isDefaultReceiver: Bool

    var id: String { kind.id }
    var name: String { kind.title }
    /// inav's checkPwmTimerConflicts() does not test UART1, so a shared UART1 pad would be driven by both peripherals.
    var requiresDedicated: Bool { kind == .uart(1) }
    var isCandidate: Bool { pins.contains { $0.isCandidate } }
    var hasNewWork: Bool { pins.contains { $0.isCandidate && !$0.isAlreadyServo } }
}

struct TargetAnalysis {
    let target: TargetInfo
    let chip: ChipDatabase
    let groups: [PadGroup]
    let otherPinUsers: [String: [String]]
    let softSerialPins: Set<String>
    let padPins: [String: String]       // pin -> "UART2 TX" / "LED strip"
    let ledInDefaultFeatures: Bool
    let motorOutputs: [TimerEntry]       // active entries that can drive a motor (MOTOR or OUTPUT_AUTO)
    let minMotors: Int

    var uarts: [PadGroup] { groups.filter { !$0.kind.isLED } }
    var ledGroup: PadGroup? { groups.first { $0.kind.isLED } }
    var candidateCount: Int { groups.filter { $0.isCandidate }.count }
    var allPins: [PinAnalysis] { groups.flatMap { $0.pins } }
}

enum Analyzer {
    static let softSerialDefines = ["SOFTSERIAL_1_RX_PIN", "SOFTSERIAL_1_TX_PIN", "SOFTSERIAL_2_RX_PIN", "SOFTSERIAL_2_TX_PIN"]

    private struct Context {
        let target: TargetInfo
        let chip: ChipDatabase
        let active: [TimerEntry]
        let softPins: Set<String>
        let softTimers: Set<String>
        let otherUsers: [String: [String]]
        let adcPins: Set<String>
        let motorCount: Int
        let minMotors: Int
    }

    static func motorOutputs(_ target: TargetInfo) -> [TimerEntry] {
        target.activeTimers.filter { $0.has("TIM_USE_MOTOR") }
    }

    static func analyze(target: TargetInfo, chip: ChipDatabase, minMotors: Int = 2) -> TargetAnalysis {
        let active = target.activeTimers

        var softPins = Set<String>()
        for k in softSerialDefines { for v in target.values(k) where isPinName(v) { softPins.insert(v) } }
        let softTimers = Set(active.filter { softPins.contains($0.pin) }.map { $0.timer })

        var others = [String: [String]]()
        for (name, vals) in target.defines {
            if name.firstMatch(#"^UART[0-9]+_"#) != nil || name.hasPrefix("SOFTSERIAL_") || name == "WS2811_PIN" { continue }
            for v in vals where isPinName(v.value) {
                if !(others[v.value]?.contains(name) ?? false) { others[v.value, default: []].append(name) }
            }
        }
        let adcPins = Set(target.defines.filter { $0.key.hasPrefix("ADC_CHANNEL_") }
            .flatMap { $0.value.map { $0.value } }.filter { isPinName($0) })
        let rxUart = target.firstValue("SERIALRX_UART")
        let motors = motorOutputs(target)
        let ctx = Context(target: target, chip: chip, active: active, softPins: softPins, softTimers: softTimers,
                          otherUsers: others, adcPins: adcPins, motorCount: motors.count, minMotors: minMotors)

        var padPins = [String: String]()
        var groups = [PadGroup]()

        // ---- UARTs ----
        for n in 1...8 {
            guard target.defines["USE_UART\(n)"] != nil else { continue }
            var notes = [Issue]()
            let isDefaultRX = rxUart == "SERIAL_PORT_USART\(n)"
            if n == 1 {
                notes.append(Issue(severity: .warning, text: "inav's runtime pin-conflict check does not cover UART1 – only dedicated mode is safe."))
            }
            if isDefaultRX {
                notes.append(Issue(severity: .warning, text: "Default receiver port (SERIALRX_UART). Move the receiver to another UART before using these pads as servos."))
            }
            var pins = [PinAnalysis]()
            for role in ["TX", "RX"] {
                let values = target.values("UART\(n)_\(role)_PIN").filter { isPinName($0) }
                var distinct = [String]()
                for v in values where !distinct.contains(v) { distinct.append(v) }
                if distinct.count > 1 {
                    notes.append(Issue(severity: .info, text: "\(role) pin differs between board variants (\(distinct.joined(separator: ", "))) – each is analysed."))
                }
                for pin in distinct where !pins.contains(where: { $0.pin == pin }) {
                    padPins[pin] = "UART\(n) \(role)"
                    pins.append(analyzePin(group: .uart(n), role: role, pin: pin, ctx))
                }
            }
            if pins.isEmpty {
                notes.append(Issue(severity: .info, text: "No TX/RX pins defined (NONE)."))
            }
            groups.append(PadGroup(kind: .uart(n), pins: pins, notes: notes, isDefaultReceiver: isDefaultRX))
        }

        // ---- LED strip pad(s) ----
        var ledPins = [String]()
        for v in target.values("WS2811_PIN") where isPinName(v) && !ledPins.contains(v) { ledPins.append(v) }
        for e in active where e.has("TIM_USE_LED") && !ledPins.contains(e.pin) { ledPins.append(e.pin) }
        let defaultFeatures = target.values("DEFAULT_FEATURES").joined(separator: " ")
        let ledDefault = defaultFeatures.contains("FEATURE_LED_STRIP")
        if !ledPins.isEmpty {
            var notes = [Issue]()
            if target.defines["USE_LED_STRIP"] == nil {
                notes.append(Issue(severity: .info, text: "USE_LED_STRIP is not defined – the pad is a plain timer pin."))
            }
            if ledDefault {
                notes.append(Issue(severity: .warning, text: "FEATURE_LED_STRIP is in DEFAULT_FEATURES. In shared mode disable the LED_STRIP feature in the configurator to get the servo output."))
            }
            if ledPins.count > 1 {
                notes.append(Issue(severity: .info, text: "Several LED pads found (\(ledPins.joined(separator: ", "))) – board variants or additional TIM_USE_LED entries."))
            }
            var pins = [PinAnalysis]()
            for pin in ledPins {
                if let owner = padPins[pin] {
                    notes.append(Issue(severity: .info, text: "\(pin) is also \(owner) – listed under that UART."))
                    continue
                }
                padPins[pin] = "LED strip"
                pins.append(analyzePin(group: .led, role: "LED", pin: pin, ctx))
            }
            groups.append(PadGroup(kind: .led, pins: pins, notes: notes, isDefaultReceiver: false))
        }

        return TargetAnalysis(target: target, chip: chip, groups: groups, otherPinUsers: others,
                              softSerialPins: softPins, padPins: padPins, ledInDefaultFeatures: ledDefault,
                              motorOutputs: motors, minMotors: minMotors)
    }

    private static func analyzePin(group: PadKind, role: String, pin: String, _ c: Context) -> PinAnalysis {
        let existing = c.active.first { $0.pin == pin }
        var options = [TimerOption]()
        var notes = [Issue]()

        if let e = existing {
            let kind: OptionKind = e.has("TIM_USE_SERVO") ? .alreadyServo(line: e.line) : .upgradeExisting(line: e.line)
            options.append(TimerOption(channel: e.timerChannel, kind: kind,
                                       detail: "existing entry, line \(e.line + 1): \(e.roleDescription)", issues: []))
        } else {
            let caps = c.chip.capabilities(of: pin)
            if caps.isEmpty {
                notes.append(Issue(severity: .info, text: "\(pin) has no timer channel in the \(c.chip.mcu.displayName) alternate-function table."))
            }
            for cap in caps {
                options.append(TimerOption(channel: cap.channel, kind: cap.usable ? .newEntry : .unusable,
                                           detail: "\(cap.detail) · \(cap.source)",
                                           issues: cap.usable ? [] : [Issue(severity: .blocker, text: cap.detail)]))
            }
        }

        for i in options.indices where options[i].kind != .unusable {
            let tc = options[i].channel
            var issues = options[i].issues
            let sameTimer = c.active.filter { $0.timer == tc.timer && $0.pin != pin }
            // Motors and servos can never share a timer. Such an option is still offered when the
            // motor outputs on that timer can be given up and enough motor outputs remain.
            let motorsOnTimer = sameTimer.filter { $0.has("TIM_USE_MOTOR") }
            let sameChannel = sameTimer.filter { $0.timerChannel.baseChannel == tc.baseChannel }
            var disables = [TimerEntry]()
            for clash in sameChannel {
                if clash.has("TIM_USE_MOTOR") {
                    disables.append(clash)
                } else {
                    issues.append(Issue(severity: .blocker, text: "\(tc.timer) \(tc.baseChannel) is already used on \(clash.pin) (\(clash.roleDescription), line \(clash.line + 1))."))
                }
            }
            let frees = motorsOnTimer.filter { m in !disables.contains(where: { $0.line == m.line }) }
            if !motorsOnTimer.isEmpty {
                let remaining = c.motorCount - motorsOnTimer.count
                var text = "\(tc.timer) drives motor outputs (\(motorsOnTimer.map { $0.pin }.joined(separator: ", "))). Using it frees the timer:"
                if !frees.isEmpty { text += " \(frees.map { $0.pin }.joined(separator: ", ")) lose\(frees.count == 1 ? "s" : "") the motor role" }
                if !disables.isEmpty { text += "\(frees.isEmpty ? "" : ";") \(disables.map { $0.pin }.joined(separator: ", ")) \(disables.count == 1 ? "is" : "are") disabled (same channel \(tc.baseChannel))" }
                text += ". \(remaining) of \(c.motorCount) motor outputs remain."
                if remaining < c.minMotors {
                    issues.append(Issue(severity: .blocker, text: "\(tc.timer) drives motor outputs (\(motorsOnTimer.map { $0.pin }.joined(separator: ", "))); freeing it would leave only \(remaining) of \(c.motorCount) motor outputs (minimum \(c.minMotors))."))
                } else {
                    issues.append(Issue(severity: .warning, text: text))
                }
            }
            options[i].freesMotors = frees
            options[i].disablesEntries = disables
            if sameTimer.contains(where: { $0.has("TIM_USE_LED") }) {
                issues.append(Issue(severity: .warning, text: "\(tc.timer) also drives the LED strip; with LED_STRIP enabled the timer is unavailable for servos."))
            }
            if sameTimer.contains(where: { $0.has("TIM_USE_BEEPER") }) {
                issues.append(Issue(severity: .warning, text: "\(tc.timer) also drives the PWM beeper."))
            }
            let inputs = sameTimer.filter { $0.has("TIM_USE_PPM") || $0.has("TIM_USE_PWM") }
            if !inputs.isEmpty {
                issues.append(Issue(severity: .warning, text: "\(tc.timer) has PPM/PWM input entries (\(inputs.map { $0.pin }.joined(separator: ", ")))."))
            }
            if c.softTimers.contains(tc.timer) {
                issues.append(Issue(severity: .warning, text: "\(tc.timer) is used by softserial; with SOFTSERIAL enabled inav skips this timer."))
            }
            if tc.isComplementary {
                issues.append(Issue(severity: .info, text: "Complementary (N) channel – supported by inav, output polarity is handled by the driver."))
            }
            if c.adcPins.contains(pin) {
                issues.append(Issue(severity: .blocker, text: "\(pin) is configured as an ADC channel."))
            }
            if let users = c.otherUsers[pin] {
                issues.append(Issue(severity: .warning, text: "\(pin) is also referenced by \(users.sorted().joined(separator: ", "))."))
            }
            if c.softPins.contains(pin) {
                issues.append(Issue(severity: .warning, text: "\(pin) is also a softserial pin."))
            }
            options[i].issues = issues
        }

        let usedTimers = Set(c.active.map { $0.timer })
        options.sort { a, b in
            func s(_ o: TimerOption) -> Int {
                var v = o.score
                if !usedTimers.contains(o.channel.timer) { v -= 1 }   // prefer a free timer
                if o.channel.isComplementary { v += 1 }
                return v
            }
            let sa = s(a), sb = s(b)
            return sa == sb ? a.channel < b.channel : sa < sb
        }
        return PinAnalysis(group: group, role: role, pin: pin, options: options, existing: existing, notes: notes)
    }

    /// Issues that only appear for a combination of selections (two pads on the same timer channel, ...).
    static func crossCheck(selected: [(pin: PinAnalysis, option: TimerOption)], target: TargetInfo, minMotors: Int = 2) -> [Issue] {
        var issues = [Issue]()
        let motors = motorOutputs(target)
        let lost = selected.reduce(into: Set<Int>()) { $0.formUnion($1.option.affectedMotorLines) }
        if !lost.isEmpty {
            let remaining = motors.filter { !lost.contains($0.line) }
            if remaining.count < minMotors {
                issues.append(Issue(severity: .blocker, text: "This selection takes \(lost.count) motor outputs; only \(remaining.count) of \(motors.count) would remain (minimum \(minMotors)). Deselect a pad or choose another timer."))
            } else {
                let order = remaining.enumerated().map { "M\($0.offset + 1) \($0.element.pin)" }.joined(separator: ", ")
                issues.append(Issue(severity: .warning, text: "Motor outputs after applying: \(order). Motor numbering may change – check the motor order in the configurator before flying."))
            }
        }
        var byChannel = [String: [String]]()
        for s in selected {
            let key = "\(s.option.channel.timer)_\(s.option.channel.baseChannel)"
            byChannel[key, default: []].append("\(s.pin.pin) (\(s.pin.label))")
        }
        for (key, pins) in byChannel.sorted(by: { $0.key < $1.key }) where pins.count > 1 {
            issues.append(Issue(severity: .blocker, text: "\(key) selected for several pads: \(pins.joined(separator: ", ")). Choose a different timer for one of them."))
        }
        let maxServos = 18
        let currentOutputs = target.activeTimers.filter { $0.isOutput }.count
        let added = selected.filter { !$0.option.isAlreadyServo }.count
        if currentOutputs + added > maxServos {
            issues.append(Issue(severity: .warning, text: "Target would have \(currentOutputs + added) outputs; inav supports at most \(maxServos) servos."))
        }
        return issues
    }
}
