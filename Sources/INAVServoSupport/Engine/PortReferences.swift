import Foundation

/// A place in the target sources that refers to a UART by its serial port identifier
/// (SERIAL_PORT_USARTn) – e.g. a default port function set in config.c or SERIALRX_UART in target.h.
struct PortReference: Identifiable, Hashable {
    enum File: String { case configC = "config.c", targetH = "target.h" }

    let file: File
    let line: Int            // 0-based
    let uart: Int
    let text: String
    let functions: [String]  // e.g. ["RX_SERIAL"]
    /// config.c indexes portConfigs[] directly: a removed UART there writes to portConfigs[-1].
    var isUnsafeIfRemoved: Bool { file == .configC }

    var id: String { "\(file.rawValue):\(line)" }
    var location: String { "\(file.rawValue) line \(line + 1)" }
    var functionLabel: String { functions.isEmpty ? "settings" : functions.joined(separator: " + ") }
}

/// What to do with the references of a UART that becomes a servo pad.
enum ReferenceAction: Hashable {
    case moveTo(Int)    // UART number
    case remove         // comment the lines out
    case keep           // leave unchanged (only sensible in shared mode)

    var label: String {
        switch self {
        case .moveTo(let n): return "Move to UART\(n)"
        case .remove: return "Remove (comment out)"
        case .keep: return "Keep unchanged"
        }
    }
}

enum PortReferences {
    /// target.h defines whose value is a serial port and the function they assign by default.
    static let defineFunctions: [String: String] = [
        "SERIALRX_UART": "RX_SERIAL",
        "GPS_UART": "GPS",
        "SMARTAUDIO_UART": "VTX_SMARTAUDIO",
        "TRAMP_UART": "VTX_TRAMP",
        "MSP_UART": "MSP",
        "MSP_DISPLAYPORT_UART": "MSP_OSD",
        "ESC_SENSOR_UART": "ESCSERIAL",
    ]

    static func find(in target: TargetInfo) -> [PortReference] {
        var refs = [PortReference]()
        if let config = target.configText {
            let lines = config.sourceLines
            let stripped = stripBlockComments(config).sourceLines
            for (i, line) in stripped.enumerated() {
                let code = line.codePart
                guard let m = code.firstMatch(#"SERIAL_PORT_USART([1-8])\b"#), let n = Int(m[1]) else { continue }
                let fns = code.regexMatches(#"FUNCTION_([A-Z0-9_]+)"#).map { $0[1] }
                let kind = code.contains("baudrateIndex") ? ["baud rate"] : fns
                refs.append(PortReference(file: .configC, line: i, uart: n, text: lines[i].trimmed, functions: kind))
            }
        }
        let hLines = target.hText.sourceLines
        for (name, entries) in target.defines {
            for e in entries {
                guard let m = e.value.firstMatch(#"^SERIAL_PORT_USART([1-8])$"#), let n = Int(m[1]) else { continue }
                let fn = defineFunctions[name] ?? name
                refs.append(PortReference(file: .targetH, line: e.line, uart: n,
                                          text: e.line < hLines.count ? hLines[e.line].trimmed : name,
                                          functions: [fn]))
            }
        }
        return refs.sorted { ($0.uart, $0.file.rawValue, $0.line) < ($1.uart, $1.file.rawValue, $1.line) }
    }

    /// Main function of a group of references (used to pick a sensible replacement port).
    static func mainFunction(_ refs: [PortReference]) -> String? {
        refs.flatMap { $0.functions }.first { $0 != "baud rate" }
    }
}
