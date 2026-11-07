import SwiftUI

/// Explains the controls of the pad cards and compares Shared vs Dedicated.
struct HowItWorksBox: View {
    @AppStorage("howItWorksExpanded") private var expanded = true

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        control("switch.2", "Switch next to the UART / LED name",
                                "Turns every usable pad of that UART (TX and RX) or the LED pad into a servo output. Off = the port keeps working as before.")
                        control("checkmark.square", "Checkbox per pad",
                                "Pick TX or RX individually. Even one selected pad uses up the UART: inav cannot run the serial port and a servo on its pads at the same time.")
                        control("list.bullet", "Timer menu on the right",
                                "Which timer channel drives the pad. The best option is preselected; others are listed with their warnings.")
                        control("rectangle.split.2x1", "Shared / Dedicated",
                                "How the UART (or LED pad) is converted – see the comparison below.")
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            Text("")
                            Label("Shared – UART or servo", systemImage: "arrow.left.arrow.right")
                                .font(.callout.weight(.semibold)).foregroundColor(.blue)
                            Label("Dedicated – servo only", systemImage: "lock")
                                .font(.callout.weight(.semibold)).foregroundColor(.purple)
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        row("UART in the configurator's Ports tab", "stays listed", "removed from the firmware")
                        row("Servo output works", "only while the UART has no function assigned (no RX, GPS, MSP …)", "always")
                        row("Switch back later", "yes – just assign a function to the UART again (servo turns off)", "only by building the firmware again")
                        row("target.h changes", "none (only MAX_PWM_OUTPUT_PORTS is raised)", "USE_UARTn / UARTn_* commented out, SERIAL_PORT_COUNT − 1")
                        row("LED pad", "LED_STRIP feature on = LED strip, off = servo", "LED strip support removed, pad is always a servo")
                        row("Choose it when", "you may still need the port as a UART", "UART1 (required), or you want a fixed, fool-proof servo layout")
                    }
                    .font(.caption)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))

                    Text("Nothing is written until you press Review & Apply; backups of target.c / target.h are kept.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label("How the switches and modes work", systemImage: "questionmark.circle")
                    .font(.headline)
            }
            .padding(4)
        }
    }

    private func control(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 20).foregroundColor(.accentColor)
            (Text(title).bold() + Text(" – " + text).foregroundColor(.secondary))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: String, _ shared: String, _ dedicated: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundColor(.secondary)
            Text(shared).fixedSize(horizontal: false, vertical: true)
            Text(dedicated).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Live "what will happen" summary inside a selected pad card.
struct OutcomeBox: View {
    @EnvironmentObject var state: AppState
    let group: PadGroup
    let mode: UartMode

    private struct Line: Identifiable {
        let id = UUID()
        let symbol: String
        let color: Color
        let text: String
    }

    private var lines: [Line] {
        var out = [Line]()
        for c in state.choices where c.pin.group == group.kind {
            let tc = c.option.channel
            let how: String
            switch c.option.kind {
            case .alreadyServo: how = " (already a servo output – no change needed)"
            case .upgradeExisting: how = " (existing DEF_TIM line gets TIM_USE_SERVO)"
            default: how = ""
            }
            out.append(Line(symbol: "arrow.right.circle.fill", color: .orange,
                            text: "\(c.pin.pin) (\(c.pin.label)) → servo output on \(tc.timer) \(tc.channel)\(how)"))
        }
        let target = state.analysis?.target
        switch (group.kind, mode) {
        case (.uart, .shared):
            out.append(Line(symbol: "checkmark.circle", color: .green,
                            text: "\(group.name) stays in the Ports tab of the configurator."))
            out.append(Line(symbol: "exclamationmark.triangle", color: .orange,
                            text: "Leave all functions of \(group.name) off. As soon as a function (receiver, GPS, MSP, telemetry …) is assigned to it, inav switches these servo outputs off."))
            if group.requiresDedicated {
                out.append(Line(symbol: "xmark.octagon.fill", color: .red,
                                text: "Not safe on UART1: inav does not switch the servo off when UART1 is used, so serial and servo would fight for the pins. Choose Dedicated."))
            }
            if group.isDefaultReceiver {
                out.append(Line(symbol: "antenna.radiowaves.left.and.right", color: .orange,
                                text: "\(group.name) is the default receiver port – move the receiver to another UART first."))
            }
        case (.uart, .dedicated):
            let count = target?.firstValue("SERIAL_PORT_COUNT").flatMap { Int($0) }
            let countText = count.map { " (SERIAL_PORT_COUNT \($0) → \($0 - 1))" } ?? ""
            out.append(Line(symbol: "minus.circle", color: .purple,
                            text: "\(group.name) is removed from the firmware and from the Ports tab\(countText)."))
            out.append(Line(symbol: "lock.circle", color: .purple,
                            text: "The pads are always servo outputs. To get the UART back, use Revert to Backup and rebuild."))
        case (.led, .shared):
            out.append(Line(symbol: "lightbulb", color: .green,
                            text: "LED_STRIP feature on → the pad drives the LED strip; LED_STRIP off → the pad is a servo."))
            if state.analysis?.ledInDefaultFeatures == true {
                out.append(Line(symbol: "exclamationmark.triangle", color: .orange,
                                text: "LED_STRIP is enabled by default on this target – switch it off in the configurator to get the servo."))
            }
        case (.led, .dedicated):
            out.append(Line(symbol: "lightbulb.slash", color: .purple,
                            text: "LED strip support is removed from the firmware (USE_LED_STRIP / WS2811_PIN commented out); the pad is always a servo."))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("After applying:").font(.caption.weight(.semibold))
            ForEach(lines) { l in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: l.symbol).foregroundColor(l.color)
                    Text(l.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill((mode == .shared ? Color.blue : Color.purple).opacity(0.07)))
    }
}
