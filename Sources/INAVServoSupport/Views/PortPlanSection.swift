import SwiftUI

/// Shows the serial ports that remain after the servo selection and which peripherals they can take.
struct PortPlanSection: View {
    @EnvironmentObject var state: AppState
    let analysis: TargetAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remaining serial ports").font(.title2.weight(.semibold))
            Text("Updates live with your servo selection. UARTs used for servos are no longer available; the suggestion assigns the peripherals you need to the free ports.")
                .font(.callout).foregroundColor(.secondary)

            HStack(spacing: 18) {
                Picker("Receiver", selection: $state.receiverChoice) {
                    ForEach(ReceiverChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 230)
                Toggle("GPS", isOn: $state.wantGPS).toggleStyle(.checkbox)
                Picker("VTX", selection: $state.vtxChoice) {
                    ForEach(VTXChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
            }

            if let plan = state.portPlan {
                summary(plan)
                table(plan)
                if !plan.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.issues) { IssueRow(issue: $0) }
                    }
                }
                Text("✓ suitable · ⚠ limited · ✗ not possible – hover a symbol for the reason.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func summary(_ plan: PortPlan) -> some View {
        let wanted: [Peripheral] = [state.receiverChoice.peripheral, state.wantGPS ? Peripheral.gps : nil, state.vtxChoice.peripheral].compactMap { $0 }
        return HStack(spacing: 10) {
            Text("\(plan.freeUARTCount) free UART\(plan.freeUARTCount == 1 ? "" : "s")")
                .font(.headline)
            ForEach(wanted) { p in
                let port = plan.assignment[p]
                HStack(spacing: 4) {
                    Image(systemName: port == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(port == nil ? .red : .green)
                    Text("\(p.short) → \(port ?? "none")").font(.callout.monospaced())
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer()
        }
    }

    private func table(_ plan: PortPlan) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Port").bold()
                Text("Pins").bold()
                Text("Status").bold()
                ForEach(Peripheral.allCases) { p in
                    Text(p.short).bold().help(p.requirement)
                }
                Text("Suggested").bold()
            }
            .font(.caption)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(plan.ports) { port in
                GridRow {
                    HStack(spacing: 4) {
                        Text(port.id).font(.callout.monospaced().weight(.semibold))
                        if port.isDefaultReceiver {
                            Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.secondary)
                                .help("default receiver port (SERIALRX_UART)")
                        }
                        if !port.notes.isEmpty {
                            Image(systemName: "info.circle").foregroundColor(.secondary)
                                .help(port.notes.joined(separator: "\n"))
                        }
                    }
                    Text(port.pinsLabel).font(.caption.monospaced())
                    Text(port.state.label)
                        .font(.caption)
                        .foregroundColor(port.state.isFree ? .green : .orange)
                    ForEach(Peripheral.allCases) { p in
                        cell(port.caps[p], available: port.state.isFree)
                    }
                    Text(suggested(port, plan))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                .opacity(port.state.isFree ? 1 : 0.5)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func suggested(_ port: SerialPortStatus, _ plan: PortPlan) -> String {
        let list = plan.assignment.filter { $0.value == port.id }.map { $0.key.short }.sorted()
        return list.isEmpty ? "" : list.joined(separator: ", ")
    }

    @ViewBuilder private func cell(_ cap: PortCapability?, available: Bool) -> some View {
        if let c = cap {
            switch c.level {
            case .ok:
                Image(systemName: "checkmark").foregroundColor(.green).help(c.note)
            case .limited:
                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange).help(c.note)
            case .no:
                Image(systemName: "xmark").foregroundColor(.secondary).help(c.note)
            }
        } else {
            Text("–").foregroundColor(.secondary)
        }
    }
}
