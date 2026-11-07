import SwiftUI
import simd

/// Visual state of one GPIO in the map.
enum PinVisual: CaseIterable {
    case free, used, timerOther, output, uartNoTimer, candidate, alreadyServo, selected, selectedWarning, disabledMotor

    var title: String {
        switch self {
        case .free: return "Unused"
        case .used: return "Other function"
        case .timerOther: return "Timer (LED/beeper/PPM…)"
        case .output: return "Motor/servo output"
        case .uartNoTimer: return "UART/LED pad, no usable timer"
        case .candidate: return "Servo candidate (UART/LED)"
        case .alreadyServo: return "Pad already servo-capable"
        case .selected: return "Selected for servo"
        case .selectedWarning: return "Selected (check warnings)"
        case .disabledMotor: return "Motor output disabled"
        }
    }

    var rgba: SIMD4<Float> {
        switch self {
        case .free: return SIMD4(0.30, 0.32, 0.36, 0.55)
        case .used: return SIMD4(0.55, 0.57, 0.62, 1.0)
        case .timerOther: return SIMD4(0.35, 0.75, 0.85, 1.0)
        case .output: return SIMD4(0.25, 0.48, 0.98, 1.0)
        case .uartNoTimer: return SIMD4(0.62, 0.42, 0.85, 1.0)
        case .candidate: return SIMD4(0.20, 0.82, 0.42, 1.0)
        case .alreadyServo: return SIMD4(0.10, 0.75, 0.70, 1.0)
        case .selected: return SIMD4(1.00, 0.62, 0.10, 1.0)
        case .selectedWarning: return SIMD4(1.00, 0.30, 0.25, 1.0)
        case .disabledMotor: return SIMD4(0.50, 0.10, 0.14, 1.0)
        }
    }

    var color: Color {
        let c = rgba
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(max(c.w, 0.8)))
    }

    var pulses: Bool { self == .selected || self == .selectedWarning }
}

/// Shared geometry between the Metal layer and the SwiftUI overlay (points, origin top-left).
struct GPIOLayout {
    let ports: [Character]
    let size: CGSize
    let labelWidth: CGFloat = 34
    let headerHeight: CGFloat = 26
    let padding: CGFloat = 14

    var cell: CGFloat {
        let w = (size.width - labelWidth - padding * 2) / 16
        let h = (size.height - headerHeight - padding * 2) / CGFloat(max(ports.count, 1))
        return max(8, min(w, h, 46))
    }
    var gridSize: CGSize { CGSize(width: cell * 16, height: cell * CGFloat(ports.count)) }
    var origin: CGPoint {
        let totalW = labelWidth + gridSize.width
        let x = (size.width - totalW) / 2 + labelWidth
        let y = headerHeight + padding
        return CGPoint(x: x, y: y)
    }
    var chipRect: CGRect {
        CGRect(x: origin.x - cell * 0.35, y: origin.y - cell * 0.35,
               width: gridSize.width + cell * 0.7, height: gridSize.height + cell * 0.7)
    }

    func center(row: Int, column: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(column) + 0.5) * cell, y: origin.y + (CGFloat(row) + 0.5) * cell)
    }

    func pinName(at p: CGPoint) -> String? {
        let col = Int(floor((p.x - origin.x) / cell))
        let row = Int(floor((p.y - origin.y) / cell))
        guard col >= 0, col < 16, row >= 0, row < ports.count else { return nil }
        let c = center(row: row, column: col)
        let dx = p.x - c.x, dy = p.y - c.y
        guard (dx * dx + dy * dy).squareRoot() <= cell * 0.5 else { return nil }
        return "P\(ports[row])\(col)"
    }
}

struct GPIOMapView: View {
    @EnvironmentObject var state: AppState
    let analysis: TargetAnalysis

    private var ports: [Character] {
        var set: Set<Character> = ["A", "B", "C"]
        for vals in analysis.target.defines.values {
            for v in vals where isPinName(v.value) { set.insert(Array(v.value)[1]) }
        }
        for t in analysis.target.timers { if isPinName(t.pin) { set.insert(Array(t.pin)[1]) } }
        return set.sorted()
    }

    func visual(for pin: String) -> PinVisual {
        let selected = state.choices.first { $0.pin.pin == pin }
        if let s = selected {
            return s.option.issues.contains { $0.severity >= .warning } ? .selectedWarning : .selected
        }
        let disabledMotorPins = Set(state.choices.flatMap { c in c.option.disablesMotors.map { e in e.pin } })
        if disabledMotorPins.contains(pin) { return .disabledMotor }
        let uartPins = analysis.allPins.filter { $0.pin == pin }
        if let p = uartPins.first {
            if p.isAlreadyServo { return .alreadyServo }
            return p.isCandidate ? .candidate : .uartNoTimer
        }
        if let t = analysis.target.activeTimers.first(where: { $0.pin == pin }) {
            return t.isOutput ? .output : .timerOther
        }
        if analysis.otherPinUsers[pin] != nil || analysis.softSerialPins.contains(pin) { return .used }
        return .free
    }

    private func instances(_ layout: GPIOLayout) -> [GPIOInstance] {
        var list = [GPIOInstance]()
        let body = layout.chipRect
        list.append(GPIOInstance(center: SIMD2(Float(body.midX), Float(body.midY)),
                                 size: SIMD2(Float(body.width), Float(body.height)),
                                 color: SIMD4(0.13, 0.14, 0.16, 1.0), shape: 1, pulse: 0))
        let ball = Float(layout.cell * 0.62)
        for (row, port) in layout.ports.enumerated() {
            for col in 0..<16 {
                let name = "P\(port)\(col)"
                let v = visual(for: name)
                let c = layout.center(row: row, column: col)
                list.append(GPIOInstance(center: SIMD2(Float(c.x), Float(c.y)), size: SIMD2(ball, ball),
                                         color: v.rgba, shape: 0, pulse: v.pulses ? 1 : 0))
                if state.hoveredPin == name {
                    let r = Float(layout.cell * 0.86)
                    list.append(GPIOInstance(center: SIMD2(Float(c.x), Float(c.y)), size: SIMD2(r, r),
                                             color: SIMD4(1, 1, 1, 0.9), shape: 2, pulse: 0))
                }
            }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let layout = GPIOLayout(ports: ports, size: geo.size)
                ZStack(alignment: .topLeading) {
                    MetalGPIOView(instances: instances(layout))
                    ForEach(0..<16, id: \.self) { col in
                        Text("\(col)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: layout.center(row: 0, column: col).x, y: layout.origin.y - layout.cell * 0.35 - 9)
                    }
                    ForEach(Array(layout.ports.enumerated()), id: \.offset) { item in
                        Text("P\(String(item.element))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: layout.origin.x - layout.cell * 0.35 - 16, y: layout.center(row: item.offset, column: 0).y)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): state.hoveredPin = layout.pinName(at: p)
                            case .ended: state.hoveredPin = nil
                            }
                        }
                        .onTapGesture(count: 1, coordinateSpace: .local) { location in
                            if let name = layout.pinName(at: location) { state.togglePin(named: name) }
                        }
                }
            }
            .frame(height: min(440, CGFloat(ports.count) * 38 + 70))

            HStack(alignment: .top) {
                legend
                Spacer()
                hoverInfo.frame(maxWidth: 380, alignment: .trailing)
            }
        }
    }

    private var legend: some View {
        let items: [PinVisual] = [.candidate, .selected, .selectedWarning, .alreadyServo, .uartNoTimer, .output, .disabledMotor, .timerOther, .used, .free]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { v in
                HStack(spacing: 6) {
                    Circle().fill(v.color).frame(width: 10, height: 10)
                    Text(v.title).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var hoverInfo: some View {
        if let pin = state.hoveredPin {
            VStack(alignment: .trailing, spacing: 2) {
                Text(pin).font(.system(.headline, design: .monospaced))
                ForEach(describe(pin), id: \.self) { line in
                    Text(line).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.trailing)
                }
            }
        } else {
            Text("Hover a pad for details · click a green pad to select it")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func describe(_ pin: String) -> [String] {
        var lines = [String]()
        if let u = analysis.padPins[pin] { lines.append(u) }
        for t in analysis.target.activeTimers where t.pin == pin {
            lines.append("\(t.timer) \(t.channel) – \(t.roleDescription)")
        }
        if let users = analysis.otherPinUsers[pin] { lines.append(users.sorted().joined(separator: ", ")) }
        let caps = analysis.chip.capabilities(of: pin).filter { $0.usable }.map { $0.channel.id }
        if !caps.isEmpty { lines.append("Timer AF: " + caps.joined(separator: ", ")) }
        if lines.isEmpty { lines.append("not used by this target") }
        return lines
    }
}
