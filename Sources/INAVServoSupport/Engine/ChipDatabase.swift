import Foundation

enum MCUFamily: String {
    case f4 = "STM32F4"
    case f7 = "STM32F7"
    case h7 = "STM32H7"
    case at32 = "AT32F43x"
}

/// Static description of every MCU that inav targets can be built for.
struct MCUInfo {
    let cmakeFunction: String     // e.g. stm32f405xg (from target_stm32f405xg(NAME))
    let displayName: String
    let family: MCUFamily
    let timerPrefix: String       // TIM or TMR
    let timerDefHeader: String    // drivers/timer_def_*.h
    let timerImpl: String         // drivers/timer_*.c
    let embeddedTable: String?    // datasheet AF table (timer channels)
    let datasheet: String
    let excludedTimers: Set<String>

    static let all: [String: MCUInfo] = {
        var d = [String: MCUInfo]()
        func add(_ fn: String, _ name: String, _ fam: MCUFamily, _ prefix: String, _ hdr: String, _ impl: String,
                 _ table: String?, _ ds: String, excluded: Set<String> = []) {
            d[fn] = MCUInfo(cmakeFunction: fn, displayName: name, family: fam, timerPrefix: prefix,
                            timerDefHeader: hdr, timerImpl: impl, embeddedTable: table, datasheet: ds,
                            excludedTimers: excluded)
        }
        add("stm32f405xg", "STM32F405", .f4, "TIM", "timer_def_stm32f4xx.h", "timer_stm32f4xx.c",
            Datasheets.stm32f405, "ST DS8626 (STM32F405/407) – Table 9, alternate function mapping")
        add("stm32f427xg", "STM32F427", .f4, "TIM", "timer_def_stm32f4xx.h", "timer_stm32f4xx.c",
            Datasheets.stm32f405, "ST DS9405 (STM32F427/429) – alternate function mapping")
        add("stm32f411xe", "STM32F411", .f4, "TIM", "timer_def_stm32f4xx.h", "timer_stm32f4xx.c",
            Datasheets.stm32f411, "ST DS10314 (STM32F411xC/E) – Table 9, alternate function mapping",
            excluded: ["TIM8", "TIM12", "TIM13", "TIM14"])
        add("stm32f722xe", "STM32F722", .f7, "TIM", "timer_def_stm32f7xx.h", "timer_stm32f7xx.c",
            Datasheets.stm32f405, "ST DS11853 (STM32F722/723) – alternate function mapping")
        add("stm32f745xg", "STM32F745", .f7, "TIM", "timer_def_stm32f7xx.h", "timer_stm32f7xx.c",
            Datasheets.stm32f405, "ST DS10916 (STM32F745/746) – alternate function mapping")
        add("stm32f765xg", "STM32F765", .f7, "TIM", "timer_def_stm32f7xx.h", "timer_stm32f7xx.c",
            Datasheets.stm32f405, "ST DS11532 (STM32F765/767) – alternate function mapping")
        add("stm32f765xi", "STM32F765", .f7, "TIM", "timer_def_stm32f7xx.h", "timer_stm32f7xx.c",
            Datasheets.stm32f405, "ST DS11532 (STM32F765/767) – alternate function mapping")
        add("stm32h743xi", "STM32H743", .h7, "TIM", "timer_def_stm32h7xx.h", "timer_stm32h7xx.c",
            nil, "ST DS12110 (STM32H742/743/753) – alternate function mapping")
        add("at32f43x", "AT32F435/437", .at32, "TMR", "timer_def_at32f43x.h", "timer_at32f43x.c",
            nil, "Artery AT32F435/437 datasheet – multiplexed function (MUX) table")
        return d
    }()
}

/// Timer channel reference such as TIM5_CH3 or TIM1_CH2N.
struct TimerChannel: Hashable, Comparable, CustomStringConvertible {
    let timer: String     // TIM5 / TMR5
    let channel: String   // CH3 / CH2N

    init(timer: String, channel: String) {
        self.timer = timer
        self.channel = channel
    }

    init?(_ s: String) {
        guard let r = s.range(of: "_") else { return nil }
        timer = String(s[..<r.lowerBound])
        channel = String(s[r.upperBound...])
        if timer.isEmpty || !channel.hasPrefix("CH") { return nil }
    }

    var id: String { "\(timer)_\(channel)" }
    var description: String { id }
    var isComplementary: Bool { channel.hasSuffix("N") }
    var baseChannel: String { isComplementary ? String(channel.dropLast()) : channel }
    var timerNumber: Int { Int(timer.filter { $0.isNumber }) ?? 0 }

    static func < (a: TimerChannel, b: TimerChannel) -> Bool {
        if a.timerNumber != b.timerNumber { return a.timerNumber < b.timerNumber }
        return a.channel < b.channel
    }
}

/// A possible timer channel on a pin according to datasheet / inav tables.
struct PinTimerCapability: Hashable {
    let channel: TimerChannel
    let usable: Bool
    let detail: String       // "AF2" or reason why it cannot be used
    let source: String
}

enum ChipDatabaseError: LocalizedError {
    case unsupportedMCU(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMCU(let s): return "MCU '\(s)' is not supported by the servo helper."
        case .missingFile(let s): return "Required inav source file not found: \(s)"
        }
    }
}

/// Merges the embedded datasheet tables with the tables in the selected inav source tree.
/// Only channels that inav's DEF_TIM() macro can actually compile for are reported as usable.
final class ChipDatabase {
    let mcu: MCUInfo
    private(set) var inavAF: [String: [String: Int]] = [:]   // pin -> timch -> AF
    private(set) var dmaChannels: Set<String> = []            // DEF_TIM_DMA__BTCH_<x>
    private(set) var btchAlias: [String: String] = [:]        // TIM1_CH1N -> TIM1_CH1
    private(set) var timers: Set<String> = []
    private(set) var embedded: [String: [TimerChannel]] = [:]

    var sourceDescription: String {
        switch mcu.family {
        case .f4:
            return "Embedded datasheet table (\(mcu.datasheet)); validated against inav drivers/\(mcu.timerDefHeader)"
        case .f7:
            return "inav drivers/\(mcu.timerDefHeader) AF table, cross-checked with embedded datasheet table (\(mcu.datasheet))"
        case .h7, .at32:
            return "inav drivers/\(mcu.timerDefHeader) AF table (derived from \(mcu.datasheet))"
        }
    }

    init(inavRoot: URL, mcu: MCUInfo) throws {
        self.mcu = mcu
        let drivers = inavRoot.appendingPathComponent("src/main/drivers")
        func read(_ name: String) throws -> String {
            let url = drivers.appendingPathComponent(name)
            guard let s = try? String(contentsOf: url, encoding: .utf8) else {
                throw ChipDatabaseError.missingFile("src/main/drivers/\(name)")
            }
            return s
        }
        let header = try read(mcu.timerDefHeader)
        for m in header.regexMatches(#"^\s*#define\s+DEF_TIM_AF__(P[A-K][0-9]+)__TCH_(\w+?_CH[0-9]N?)\s+D\(\s*([0-9]+)\s*,\s*([0-9]+)\s*\)"#, multiline: true) {
            inavAF[m[1], default: [:]][m[2]] = Int(m[3]) ?? 0
        }
        for m in header.regexMatches(#"^\s*#define\s+DEF_TIM_DMA__BTCH_(\w+_CH[0-9]N?)\b"#, multiline: true) {
            dmaChannels.insert(m[1])
        }
        let timerDef = try read("timer_def.h")
        for m in timerDef.regexMatches(#"^\s*#define\s+BTCH_(\w+_CH[0-9]N)\s+BTCH_(\w+_CH[0-9])\b"#, multiline: true) {
            btchAlias[m[1]] = m[2]
        }
        let impl = try read(mcu.timerImpl)
        for m in impl.regexMatches(#"\.tim\s*=\s*(\#(mcu.timerPrefix)[0-9]+)"#) {
            timers.insert(m[1])
        }
        timers.subtract(mcu.excludedTimers)
        if let table = mcu.embeddedTable {
            embedded = Datasheets.parse(table)
        }
    }

    func baseDMAChannel(_ tc: TimerChannel) -> String {
        return btchAlias[tc.id] ?? tc.id
    }

    private func validate(_ tc: TimerChannel) -> String? {
        if !timers.contains(tc.timer) {
            return "\(tc.timer) is not available in inav for \(mcu.displayName)"
        }
        if !dmaChannels.contains(baseDMAChannel(tc)) {
            return "inav has no DEF_TIM_DMA__BTCH_\(baseDMAChannel(tc)) – DEF_TIM() would not compile"
        }
        return nil
    }

    /// All timer channels the pin can be routed to.
    func capabilities(of pin: String) -> [PinTimerCapability] {
        var out = [PinTimerCapability]()
        switch mcu.family {
        case .f4:
            for tc in embedded[pin] ?? [] {
                if let why = validate(tc) {
                    out.append(PinTimerCapability(channel: tc, usable: false, detail: why, source: "datasheet"))
                } else {
                    out.append(PinTimerCapability(channel: tc, usable: true, detail: "AF \(Datasheets.f4AF(for: tc.timer))", source: "datasheet"))
                }
            }
        case .f7, .h7, .at32:
            var seen = Set<String>()
            for (key, af) in (inavAF[pin] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let tc = TimerChannel(key) else { continue }
                seen.insert(key)
                if let why = validate(tc) {
                    out.append(PinTimerCapability(channel: tc, usable: false, detail: why, source: "inav AF table"))
                } else {
                    let label = mcu.family == .at32 ? "MUX \(af)" : "AF \(af)"
                    out.append(PinTimerCapability(channel: tc, usable: true, detail: label, source: "inav AF table"))
                }
            }
            if mcu.family == .f7 {
                for tc in embedded[pin] ?? [] where !seen.contains(tc.id) {
                    out.append(PinTimerCapability(channel: tc, usable: false,
                        detail: "Datasheet lists \(tc.id) on \(pin), but inav has no DEF_TIM_AF__\(pin)__TCH_\(tc.id) entry",
                        source: "datasheet"))
                }
            }
        }
        return out.sorted { $0.channel < $1.channel }
    }

    /// True if the datasheet / inav tables know any timer function for the pin.
    func hasAnyTimer(_ pin: String) -> Bool {
        return !capabilities(of: pin).isEmpty
    }
}

/// Timer alternate-function tables transcribed from the ST datasheets
/// (only the timer capture/compare channels relevant for PWM output).
enum Datasheets {
    /// STM32F405/407/415/417 and F427/429; identical timer mapping is used by STM32F72x/F74x/F76x.
    static let stm32f405 = """
    PA0:TIM2_CH1,TIM5_CH1 PA1:TIM2_CH2,TIM5_CH2 PA2:TIM2_CH3,TIM5_CH3,TIM9_CH1 PA3:TIM2_CH4,TIM5_CH4,TIM9_CH2
    PA5:TIM2_CH1,TIM8_CH1N PA6:TIM3_CH1,TIM13_CH1 PA7:TIM1_CH1N,TIM3_CH2,TIM8_CH1N,TIM14_CH1
    PA8:TIM1_CH1 PA9:TIM1_CH2 PA10:TIM1_CH3 PA11:TIM1_CH4 PA15:TIM2_CH1
    PB0:TIM1_CH2N,TIM3_CH3,TIM8_CH2N PB1:TIM1_CH3N,TIM3_CH4,TIM8_CH3N PB3:TIM2_CH2 PB4:TIM3_CH1 PB5:TIM3_CH2
    PB6:TIM4_CH1 PB7:TIM4_CH2 PB8:TIM4_CH3,TIM10_CH1 PB9:TIM4_CH4,TIM11_CH1 PB10:TIM2_CH3 PB11:TIM2_CH4
    PB13:TIM1_CH1N PB14:TIM1_CH2N,TIM8_CH2N,TIM12_CH1 PB15:TIM1_CH3N,TIM8_CH3N,TIM12_CH2
    PC6:TIM3_CH1,TIM8_CH1 PC7:TIM3_CH2,TIM8_CH2 PC8:TIM3_CH3,TIM8_CH3 PC9:TIM3_CH4,TIM8_CH4
    PD12:TIM4_CH1 PD13:TIM4_CH2 PD14:TIM4_CH3 PD15:TIM4_CH4
    PE5:TIM9_CH1 PE6:TIM9_CH2 PE8:TIM1_CH1N PE9:TIM1_CH1 PE10:TIM1_CH2N PE11:TIM1_CH2 PE12:TIM1_CH3N PE13:TIM1_CH3 PE14:TIM1_CH4
    PF6:TIM10_CH1 PF7:TIM11_CH1 PF8:TIM13_CH1 PF9:TIM14_CH1
    PH6:TIM12_CH1 PH9:TIM12_CH2 PH10:TIM5_CH1 PH11:TIM5_CH2 PH12:TIM5_CH3 PH13:TIM8_CH1N PH14:TIM8_CH2N PH15:TIM8_CH3N
    PI0:TIM5_CH4 PI2:TIM8_CH4 PI5:TIM8_CH1 PI6:TIM8_CH2 PI7:TIM8_CH3
    """

    /// STM32F411xC/E: TIM1..5, TIM9..11 only; PB11 is not bonded out on LQFP64/UFQFPN48.
    static let stm32f411 = """
    PA0:TIM2_CH1,TIM5_CH1 PA1:TIM2_CH2,TIM5_CH2 PA2:TIM2_CH3,TIM5_CH3,TIM9_CH1 PA3:TIM2_CH4,TIM5_CH4,TIM9_CH2
    PA5:TIM2_CH1 PA6:TIM3_CH1 PA7:TIM1_CH1N,TIM3_CH2 PA8:TIM1_CH1 PA9:TIM1_CH2 PA10:TIM1_CH3 PA11:TIM1_CH4 PA15:TIM2_CH1
    PB0:TIM1_CH2N,TIM3_CH3 PB1:TIM1_CH3N,TIM3_CH4 PB3:TIM2_CH2 PB4:TIM3_CH1 PB5:TIM3_CH2
    PB6:TIM4_CH1 PB7:TIM4_CH2 PB8:TIM4_CH3,TIM10_CH1 PB9:TIM4_CH4,TIM11_CH1 PB10:TIM2_CH3
    PB13:TIM1_CH1N PB14:TIM1_CH2N PB15:TIM1_CH3N
    PC6:TIM3_CH1 PC7:TIM3_CH2 PC8:TIM3_CH3 PC9:TIM3_CH4
    PD12:TIM4_CH1 PD13:TIM4_CH2 PD14:TIM4_CH3 PD15:TIM4_CH4
    PE5:TIM9_CH1 PE6:TIM9_CH2 PE8:TIM1_CH1N PE9:TIM1_CH1 PE10:TIM1_CH2N PE11:TIM1_CH2 PE12:TIM1_CH3N PE13:TIM1_CH3 PE14:TIM1_CH4
    """

    static func parse(_ table: String) -> [String: [TimerChannel]] {
        var d = [String: [TimerChannel]]()
        for token in table.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let parts = token.split(separator: ":")
            guard parts.count == 2 else { continue }
            d[String(parts[0])] = parts[1].split(separator: ",").compactMap { TimerChannel(String($0)) }
        }
        return d
    }

    /// STM32F4/F7 timer alternate function numbers.
    static func f4AF(for timer: String) -> Int {
        switch timer {
        case "TIM1", "TIM2": return 1
        case "TIM3", "TIM4", "TIM5": return 2
        case "TIM8", "TIM9", "TIM10", "TIM11": return 3
        case "TIM12", "TIM13", "TIM14": return 9
        default: return 0
        }
    }
}
