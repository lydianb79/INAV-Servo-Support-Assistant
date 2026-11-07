import Foundation

/// One user of a fixed DMA stream (DShot motor output, LED strip, ADC …).
struct DMAUser: Identifiable, Hashable {
    let name: String
    let stream: DMAStreamRef?   // nil = this output has no DMA (DShot impossible there)
    let line: Int?              // target.c line for timer users
    var id: String { name }
}

struct DMAReport {
    let applicable: Bool        // false on H7 / AT32 (DMAMUX)
    let users: [DMAUser]
    let issues: [Issue]
    var conflictCount: Int { issues.filter { $0.text.contains(" is shared by ") }.count }
}

/// DShot motor outputs and the WS2812 LED strip use timer DMA. On STM32F4/F7 every timer channel can only use
/// fixed DMA streams (chosen with the last DEF_TIM argument), so two users on the same stream clash.
/// Servo PWM outputs do not use DMA.
enum DMACheck {
    static func stream(of e: TimerEntry, chip: ChipDatabase) -> DMAStreamRef? {
        let options = chip.dmaOptions[chip.baseDMAChannel(e.timerChannel)] ?? []
        let variant = Int(e.args.count > 5 ? e.args[5].trimmed : "0") ?? 0
        return variant < options.count ? options[variant] : nil
    }

    static func usesBurstDMA(_ target: TargetInfo) -> Bool { target.defines["USE_DSHOT_DMAR"] != nil }

    static func users(target: TargetInfo, chip: ChipDatabase, excludingLines: Set<Int> = []) -> [DMAUser] {
        var users = [DMAUser]()
        let motors = Analyzer.motorOutputs(target)
        if usesBurstDMA(target) {
            // USE_DSHOT_DMAR: one burst DMA stream (TIMx_UP) per motor timer
            var timers = [String]()
            for m in motors where !excludingLines.contains(m.line) && !timers.contains(m.timer) { timers.append(m.timer) }
            for t in timers {
                let nums = motors.enumerated().filter { $0.element.timer == t }.map { String($0.offset + 1) }.joined(separator: ", ")
                users.append(DMAUser(name: "Motors \(nums) (\(t) burst)", stream: chip.dmaOptions["\(t)_UP"]?.first, line: nil))
            }
        } else {
            for (i, m) in motors.enumerated() where !excludingLines.contains(m.line) {
                users.append(DMAUser(name: "Motor \(i + 1) (\(m.pin), \(m.timer) \(m.channel))",
                                     stream: stream(of: m, chip: chip), line: m.line))
            }
        }
        for e in target.activeTimers where e.has("TIM_USE_LED") && !e.has("TIM_USE_MOTOR") && !excludingLines.contains(e.line) {
            users.append(DMAUser(name: "LED strip (\(e.pin), \(e.timer) \(e.channel))", stream: stream(of: e, chip: chip), line: e.line))
        }
        for (name, entries) in target.defines where name.hasSuffix("_DMA_STREAM") {
            for v in entries {
                if let m = v.value.firstMatch(#"DMA([12])_Stream([0-7])"#), let d = Int(m[1]), let st = Int(m[2]) {
                    users.append(DMAUser(name: name.replacingOccurrences(of: "_DMA_STREAM", with: ""),
                                         stream: DMAStreamRef(dma: d, stream: st, channel: -1), line: nil))
                }
            }
        }
        return users
    }

    static func report(target: TargetInfo, chip: ChipDatabase, excludingLines: Set<Int> = []) -> DMAReport {
        guard chip.hasFixedDMA else {
            return DMAReport(applicable: false, users: [], issues: [
                Issue(severity: .info, text: "\(chip.mcu.displayName) assigns DMA streams through a DMAMUX at runtime – no fixed DMA clashes possible.")])
        }
        let users = users(target: target, chip: chip, excludingLines: excludingLines)
        var issues = [Issue]()
        var byStream = [String: [DMAUser]]()
        for u in users { if let s = u.stream { byStream[s.streamKey, default: []].append(u) } }
        for (key, list) in byStream.sorted(by: { $0.key < $1.key }) where list.count > 1 {
            issues.append(Issue(severity: .info, text: "\(key) is shared by \(list.map { $0.name }.joined(separator: ", ")). Already like this in the target (not caused by servo changes): with DShot only one of them can get the stream – if a motor misbehaves with DShot, change its DMA option (last DEF_TIM argument) or use a PWM/Multishot protocol."))
        }
        if usesBurstDMA(target) {
            issues.append(Issue(severity: .info, text: "USE_DSHOT_DMAR: DShot uses one burst DMA stream per motor timer (TIMx_UP)."))
        }
        for u in users where u.stream == nil && u.name.hasPrefix("Motor") {
            issues.append(Issue(severity: .info, text: "\(u.name) has no DMA – DShot is not possible on that output."))
        }
        if issues.isEmpty {
            issues.append(Issue(severity: .info, text: "No DMA stream clashes between DShot motors, LED strip and ADC."))
        }
        return DMAReport(applicable: true, users: users, issues: issues)
    }

    /// DMA option (last DEF_TIM argument) for a new servo entry that avoids streams already in use.
    /// Servos do not use DMA, but keeping the table clash-free avoids confusion and later surprises.
    static func freeVariant(for tc: TimerChannel, target: TargetInfo, chip: ChipDatabase) -> Int {
        guard chip.hasFixedDMA else { return 0 }
        let used = Set(users(target: target, chip: chip).compactMap { $0.stream?.streamKey })
        let options = chip.dmaOptions[chip.baseDMAChannel(tc)] ?? []
        return options.firstIndex { !used.contains($0.streamKey) } ?? 0
    }
}
