import Foundation

/// Peripheral connections checked against the serial ports that remain after the servo selection.
enum Peripheral: String, CaseIterable, Identifiable, Hashable {
    case receiverCRSF = "Receiver CRSF/ELRS"
    case receiverSBUS = "Receiver SBUS"
    case gps = "GPS"
    case vtxSmartAudio = "VTX SmartAudio/Tramp"
    case vtxMSP = "VTX MSP DisplayPort"

    var id: String { rawValue }
    var short: String {
        switch self {
        case .receiverCRSF: return "CRSF/ELRS"
        case .receiverSBUS: return "SBUS"
        case .gps: return "GPS"
        case .vtxSmartAudio: return "SmartAudio"
        case .vtxMSP: return "MSP-DP"
        }
    }
    var requirement: String {
        switch self {
        case .receiverCRSF: return "TX + RX (RX only = no telemetry)"
        case .receiverSBUS: return "RX pin, inverted signal (F4 needs a hardware inverter)"
        case .gps: return "TX + RX (RX only = no GPS configuration)"
        case .vtxSmartAudio: return "TX pin (single-wire, half duplex); softserial works"
        case .vtxMSP: return "TX + RX (DJI / Walksnail / HDZero OSD)"
        }
    }
}

enum ReceiverChoice: String, CaseIterable, Identifiable {
    case crsf = "CRSF / ELRS"
    case sbus = "SBUS"
    case none = "None"
    var id: String { rawValue }
    var peripheral: Peripheral? {
        switch self { case .crsf: return .receiverCRSF; case .sbus: return .receiverSBUS; case .none: return nil }
    }
}

enum VTXChoice: String, CaseIterable, Identifiable {
    case smartAudio = "SmartAudio / Tramp"
    case msp = "MSP DisplayPort (HD)"
    case none = "None"
    var id: String { rawValue }
    var peripheral: Peripheral? {
        switch self { case .smartAudio: return .vtxSmartAudio; case .msp: return .vtxMSP; case .none: return nil }
    }
}

enum CapLevel: Int, Comparable {
    case no = 0, limited = 1, ok = 2
    static func < (a: CapLevel, b: CapLevel) -> Bool { a.rawValue < b.rawValue }
}

struct PortCapability: Hashable {
    let level: CapLevel
    let note: String
}

enum PortState: Hashable {
    case free
    case servoShared        // pads selected as servos, UART still defined
    case servoDedicated     // UART removed from the target
    case unusable(String)

    var label: String {
        switch self {
        case .free: return "free"
        case .servoShared: return "servo (shared)"
        case .servoDedicated: return "servo (UART disabled)"
        case .unusable(let s): return s
        }
    }
    var isFree: Bool { self == .free }
}

struct SerialPortStatus: Identifiable, Hashable {
    let id: String              // UART3 / SOFTSERIAL1
    let isSoftSerial: Bool
    let tx: String?
    let rx: String?
    let state: PortState
    let isDefaultReceiver: Bool
    let hasInverter: Bool
    let notes: [String]
    let caps: [Peripheral: PortCapability]

    var pinsLabel: String {
        if let t = tx, let r = rx, t == r { return "\(t) (single wire)" }
        return "TX \(tx ?? "–") · RX \(rx ?? "–")"
    }
}

struct PortPlan {
    let ports: [SerialPortStatus]
    let assignment: [Peripheral: String]       // peripheral -> port id
    let issues: [Issue]
    var freeUARTCount: Int { ports.filter { !$0.isSoftSerial && $0.state.isFree }.count }
}

enum PortPlanner {
    static func plan(analysis: TargetAnalysis, choices: [ServoChoice],
                     receiver: ReceiverChoice, gps: Bool, vtx: VTXChoice) -> PortPlan {
        let target = analysis.target
        let family = analysis.chip.mcu.family
        let selectedPins = Set(choices.map { $0.pin.pin })
        var ports = [SerialPortStatus]()

        // ---- hardware UARTs ----
        for g in analysis.uarts {
            guard let n = g.kind.uartNumber else { continue }
            let tx = target.values("UART\(n)_TX_PIN").first { isPinName($0) }
            let rx = target.values("UART\(n)_RX_PIN").first { isPinName($0) }
            let groupChoices = choices.filter { $0.pin.group == g.kind }
            var state = PortState.free
            if !groupChoices.isEmpty {
                state = groupChoices.contains { $0.mode == .dedicated } ? .servoDedicated : .servoShared
            }
            var notes = [String]()
            for pin in [tx, rx].compactMap({ $0 }) {
                if let users = analysis.otherPinUsers[pin] { notes.append("\(pin) also used by \(users.sorted().joined(separator: ", "))") }
                if analysis.softSerialPins.contains(pin) { notes.append("\(pin) is shared with softserial") }
                if analysis.padPins[pin] == "LED strip" { notes.append("\(pin) is the LED strip pad") }
            }
            let inverter = target.defines["INVERTER_PIN_UART\(n)_RX"] != nil || target.defines["INVERTER_PIN_USART\(n)"] != nil
            let caps = capabilities(tx: tx, rx: rx, soft: false, family: family, hasInverter: inverter)
            ports.append(SerialPortStatus(id: "UART\(n)", isSoftSerial: false, tx: tx, rx: rx, state: state,
                                          isDefaultReceiver: g.isDefaultReceiver, hasInverter: inverter,
                                          notes: notes, caps: caps))
        }

        // ---- softserial ----
        for n in 1...2 where target.defines["USE_SOFTSERIAL\(n)"] != nil {
            let tx = target.values("SOFTSERIAL_\(n)_TX_PIN").first { isPinName($0) }
            let rx = target.values("SOFTSERIAL_\(n)_RX_PIN").first { isPinName($0) }
            var state = PortState.free
            let sharedWith = [tx, rx].compactMap { $0 }.compactMap { analysis.padPins[$0] }
            var notes = ["Needs the SOFTSERIAL feature" + (sharedWith.isEmpty ? "" : "; pins shared with " + sharedWith.joined(separator: ", "))]
            if [tx, rx].compactMap({ $0 }).contains(where: { selectedPins.contains($0) }) {
                state = .unusable("pad selected as servo")
            }
            let softTimers = Set(target.activeTimers.filter { $0.pin == tx || $0.pin == rx }.map { $0.timer })
            if choices.contains(where: { softTimers.contains($0.option.channel.timer) }) {
                notes.append("its timer is also used by a selected servo pad – softserial and servo exclude each other")
            }
            let caps = capabilities(tx: tx, rx: rx, soft: true, family: family, hasInverter: false)
            ports.append(SerialPortStatus(id: "SOFTSERIAL\(n)", isSoftSerial: true, tx: tx, rx: rx, state: state,
                                          isDefaultReceiver: false, hasInverter: false, notes: notes, caps: caps))
        }

        // ---- assignment (exhaustive search, at most 3 peripherals) ----
        let wanted = [receiver.peripheral, gps ? Peripheral.gps : nil, vtx.peripheral].compactMap { $0 }
        let available = ports.filter { $0.state.isFree }
        // ports that share a pin (softserial on UART pads) cannot be used together
        var conflicts = [String: Set<String>]()
        for a in ports {
            let pa = Set([a.tx, a.rx].compactMap { $0 })
            for b in ports where b.id != a.id && !pa.isDisjoint(with: [b.tx, b.rx].compactMap { $0 }) {
                conflicts[a.id, default: []].insert(b.id)
            }
        }
        var best: [Peripheral: String] = [:]
        var bestScore = -1.0
        func search(_ i: Int, _ used: Set<String>, _ current: [Peripheral: String], _ score: Double) {
            if i == wanted.count {
                if score > bestScore { bestScore = score; best = current }
                return
            }
            let p = wanted[i]
            // option: leave unassigned
            search(i + 1, used, current, score)
            for port in available where !used.contains(port.id) && conflicts[port.id, default: []].isDisjoint(with: used) {
                guard let cap = port.caps[p], cap.level > .no else { continue }
                var s = score + 10 + Double(cap.level.rawValue) * 2
                if p == .receiverCRSF || p == .receiverSBUS, port.isDefaultReceiver { s += 1 }
                if port.isSoftSerial { s -= 1.5 }         // keep softserial as last resort
                if !port.notes.isEmpty && !port.isSoftSerial { s -= 0.5 }
                var next = current
                next[p] = port.id
                search(i + 1, used.union([port.id]), next, s)
            }
        }
        search(0, [], [:], 0)

        var issues = [Issue]()
        for p in wanted {
            if let portID = best[p], let port = ports.first(where: { $0.id == portID }), let cap = port.caps[p] {
                if cap.level == .limited {
                    issues.append(Issue(severity: .warning, text: "\(p.rawValue) → \(portID): \(cap.note)"))
                }
            } else {
                let possible = ports.filter { ($0.caps[p]?.level ?? .no) > .no }
                let reason: String
                if possible.isEmpty {
                    reason = "no serial port of this target meets the requirement (\(p.requirement))."
                } else {
                    reason = "suitable ports (\(possible.map { $0.id }.joined(separator: ", "))) are taken by servos or other peripherals. Deselect a servo UART or use another port."
                }
                issues.append(Issue(severity: .blocker, text: "\(p.rawValue): \(reason)"))
            }
        }
        if wanted.isEmpty {
            issues.append(Issue(severity: .info, text: "Choose the peripherals you want to connect to get a suggested port assignment."))
        }
        return PortPlan(ports: ports, assignment: best, issues: issues)
    }

    static func capabilities(tx: String?, rx: String?, soft: Bool, family: MCUFamily, hasInverter: Bool) -> [Peripheral: PortCapability] {
        let singleWire = tx != nil && tx == rx
        let hasTX = tx != nil
        let hasRX = rx != nil && !singleWire
        let full = hasTX && hasRX
        var c = [Peripheral: PortCapability]()

        if soft {
            c[.receiverCRSF] = PortCapability(level: .no, note: "softserial is too slow for CRSF (420k baud)")
            c[.receiverSBUS] = PortCapability(level: .no, note: "SBUS is not supported on softserial")
            c[.gps] = PortCapability(level: .no, note: "GPS on softserial is not supported by inav")
            c[.vtxMSP] = PortCapability(level: .no, note: "MSP DisplayPort needs a hardware UART")
            c[.vtxSmartAudio] = hasTX ? PortCapability(level: .ok, note: "SmartAudio/Tramp works on softserial TX")
                                      : PortCapability(level: .no, note: "no TX pin")
            return c
        }

        if full {
            c[.receiverCRSF] = PortCapability(level: .ok, note: "TX + RX available")
        } else if hasRX {
            c[.receiverCRSF] = PortCapability(level: .limited, note: "RX only – control works, no telemetry")
        } else if singleWire {
            c[.receiverCRSF] = PortCapability(level: .no, note: "single-wire port – CRSF needs separate TX and RX")
        } else {
            c[.receiverCRSF] = PortCapability(level: .no, note: "no RX pin")
        }

        if !hasRX && !singleWire {
            c[.receiverSBUS] = PortCapability(level: .no, note: "no RX pin")
        } else if family == .f4 && !hasInverter {
            c[.receiverSBUS] = PortCapability(level: .limited, note: "STM32F4 cannot invert UART signals and this UART has no inverter – use an uninverted SBUS output")
        } else {
            c[.receiverSBUS] = PortCapability(level: .ok, note: family == .f4 ? "hardware inverter on this UART" : "MCU inverts the signal internally")
        }

        if full {
            c[.gps] = PortCapability(level: .ok, note: "TX + RX available")
        } else if hasRX {
            c[.gps] = PortCapability(level: .limited, note: "RX only – GPS cannot be configured, set the module up beforehand")
        } else {
            c[.gps] = PortCapability(level: .no, note: "needs at least an RX pin")
        }

        c[.vtxSmartAudio] = hasTX ? PortCapability(level: .ok, note: "TX pin available")
                                  : PortCapability(level: .no, note: "no TX pin")
        c[.vtxMSP] = full ? PortCapability(level: .ok, note: "TX + RX available")
                          : PortCapability(level: .no, note: "needs TX and RX")
        return c
    }
}
