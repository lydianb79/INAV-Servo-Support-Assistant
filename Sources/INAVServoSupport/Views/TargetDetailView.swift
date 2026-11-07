import SwiftUI

struct TargetDetailView: View {
    @EnvironmentObject var state: AppState
    let analysis: TargetAnalysis

    private var target: TargetInfo { analysis.target }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    GroupBox {
                        GPIOMapView(analysis: analysis).padding(6)
                    } label: {
                        Label("GPIO map – \(analysis.chip.mcu.displayName) (rendered with Metal)", systemImage: "cpu")
                    }
                    padSection
                    PortPlanSection(analysis: analysis)
                    CLISnippetBox()
                    existingTimersSection
                    dmaSection
                }
                .padding(20)
            }
            Divider()
            actionBar
        }
        .navigationTitle(target.name)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(target.name).font(.largeTitle.weight(.semibold).monospaced())
                Text(analysis.chip.mcu.displayName)
                    .font(.headline)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                if target.variants.count > 1 {
                    Text("variants: " + target.variants.joined(separator: ", "))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Text(analysis.chip.sourceDescription).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 18) {
                stat("\(target.activeTimers.filter { $0.isOutput }.count)", "outputs today")
                stat("\(analysis.uarts.count)", "UARTs defined")
                stat("\(analysis.candidateCount)", "servo candidate groups")
                stat(analysis.ledGroup.map { $0.pins.map { $0.pin }.joined(separator: ",") } ?? "–", "LED pad")
                stat(target.firstValue("SERIAL_PORT_COUNT") ?? "–", "SERIAL_PORT_COUNT")
                stat(target.firstValue("MAX_PWM_OUTPUT_PORTS") ?? "–", "MAX_PWM_OUTPUT_PORTS")
            }
            .padding(.top, 4)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: UART + LED pads

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Servo candidates – UART and LED pads").font(.title2.weight(.semibold))
            Text("Candidates are pads whose GPIO can be routed to a timer channel that inav can drive without conflicting with motors or other timer users.")
                .font(.callout).foregroundColor(.secondary)
            HowItWorksBox()
            if !analysis.motorOutputs.isEmpty {
                MotorStrip(analysis: analysis)
            }
            let ordered = analysis.groups.sorted { ($0.isCandidate ? 0 : 1, $0.kind.sortKey) < ($1.isCandidate ? 0 : 1, $1.kind.sortKey) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(ordered) { g in
                    PadGroupCard(group: g)
                }
            }
            let issues = state.selectionIssues
            if !issues.isEmpty {
                GroupBox("Selection check") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues) { IssueRow(issue: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: existing timers

    private var existingTimersSection: some View {
        DisclosureGroup("timerHardware[] in target.c (\(target.timers.count) entries)") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(target.timers) { t in
                    HStack(spacing: 10) {
                        Text("\(t.line + 1)").frame(width: 34, alignment: .trailing).foregroundColor(.secondary)
                        Text(t.timer).frame(width: 52, alignment: .leading)
                        Text(t.channel).frame(width: 44, alignment: .leading)
                        Text(t.pin).frame(width: 44, alignment: .leading)
                        Text(t.usage).frame(width: 250, alignment: .leading).lineLimit(1)
                        Text(t.comment).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .opacity(t.active ? 1 : 0.4)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: DMA

    private var dmaSection: some View {
        let report = analysis.dmaReport
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if report.applicable {
                    ForEach(report.users) { u in
                        HStack(spacing: 10) {
                            Text(u.name).frame(width: 300, alignment: .leading)
                            Text(u.stream.map { "\($0.streamKey), channel \($0.channel)" } ?? "no DMA")
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    Divider()
                }
                ForEach(report.issues) { IssueRow(issue: $0) }
                Text("Servo outputs don't use DMA. New servo entries get a DMA option that avoids these streams.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("DMA check (DShot motors, LED strip, ADC)")
                if report.conflictCount > 0 {
                    Text("\(report.conflictCount) shared stream\(report.conflictCount == 1 ? "" : "s") in the original target")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: actions

    private var actionBar: some View {
        HStack(spacing: 12) {
            let count = state.choices.count
            Text(count == 0 ? "No pads selected" : "\(count) pad\(count == 1 ? "" : "s") selected")
                .foregroundColor(.secondary)
            if let s = state.statusMessage {
                Text(s).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if state.hasBackup {
                Button(role: .destructive) { state.revert() } label: { Label("Revert to Backup", systemImage: "arrow.uturn.backward") }
            }
            Menu {
                Button { state.exportPatch() } label: { Label("Export changes as .patch…", systemImage: "square.and.arrow.up") }
                    .disabled(count == 0)
                Button { state.importPatch() } label: { Label("Apply a .patch…", systemImage: "square.and.arrow.down") }
                Button { state.promptCommitBranch() } label: { Label("Commit target to git branch…", systemImage: "arrow.triangle.branch") }
                Divider()
                Button { state.revealHex() } label: { Label("Reveal last .hex", systemImage: "doc.badge.gearshape") }
                    .disabled(state.lastHex == nil)
                Button { state.confirmFlash() } label: { Label("Flash last build via DFU…", systemImage: "bolt.horizontal.circle") }
                    .disabled(state.lastHex == nil || state.jobRunning)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            Button { state.testBuild() } label: { Label("Test Build", systemImage: "hammer") }
                .help("Runs cmake + make for this target in <inav>/build (requires cmake). The ARM compiler is downloaded once into a shared cache and reused for every inav checkout.")
                .disabled(state.jobRunning)
            Button { state.showDiffSheet = true } label: { Label("Review & Apply…", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0 || state.selectionIssues.contains { $0.severity == .blocker })
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }
}

struct PadGroupCard: View {
    @EnvironmentObject var state: AppState
    let group: PadGroup
    private var uart: PadGroup { group }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { state.isGroupSelected(uart) },
                                         set: { state.setGroup(uart, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(uart.name, systemImage: uart.kind.isLED ? "lightbulb" : "cable.connector")
                                .font(.title3.weight(.semibold).monospaced())
                            Text(switchCaption)
                                .font(.caption)
                                .foregroundColor(selected ? .orange : .secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!uart.isCandidate)
                    .help(uart.kind.isLED
                          ? "Switch on to turn the LED strip pad into a servo output."
                          : "Switch on to turn all usable pads of \(uart.name) into servo outputs. Use the checkboxes below to pick TX or RX only.")
                    Spacer()
                    badge
                }
                if uart.isCandidate && selected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(uart.kind.isLED ? "How should the LED pad be converted?" : "How should \(uart.name) be converted?")
                            .font(.caption.weight(.semibold))
                        Picker("Mode", selection: Binding(get: { mode },
                                                          set: { state.padMode[uart.id] = $0 })) {
                            ForEach(UartMode.allCases) { m in Text(m.title(for: uart.kind)).tag(m) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        OutcomeBox(group: uart, mode: mode)
                        if let n = uart.kind.uartNumber, !state.references(forUART: n).isEmpty {
                            PortReferencesBox(uart: n, mode: mode)
                        }
                    }
                } else if uart.isCandidate {
                    Text(uart.kind.isLED
                         ? "Off: the pad stays the LED strip output. Switch on to use it as a servo."
                         : "Off: \(uart.name) stays a normal serial port. Switch on (or tick single pads below) to use its pads as servo outputs.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(uart.notes) { IssueRow(issue: $0) }
                ForEach(uart.pins) { p in
                    PinRow(pin: p)
                    if p.id != uart.pins.last?.id { Divider() }
                }
            }
            .padding(4)
        }
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(state.isGroupSelected(uart) ? Color.orange : Color.clear, lineWidth: 2))
        .opacity(uart.isCandidate ? 1 : 0.75)
    }

    private var selected: Bool { state.isGroupSelected(uart) }
    private var mode: UartMode { state.padMode[uart.id] ?? .shared }

    private var switchCaption: String {
        let usable = uart.pins.filter { $0.isCandidate }
        let on = usable.filter { state.pinEnabled[$0.id] == true }
        if usable.isEmpty { return "no pad can be a servo" }
        if on.isEmpty { return uart.kind.isLED ? "off – LED strip output" : "off – normal UART" }
        let names = on.map { $0.group.isLED ? $0.pin : "\($0.role) \($0.pin)" }.joined(separator: " + ")
        let partial = on.count < usable.count ? " (\(on.count) of \(usable.count) pads)" : ""
        return "on – \(names) → servo\(partial)"
    }

    @ViewBuilder private var badge: some View {
        if !uart.isCandidate {
            pill("not possible", .gray)
        } else if !uart.hasNewWork {
            pill("already servo", .teal)
        } else {
            pill("candidate", .green)
        }
    }

    private func pill(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.18)))
            .foregroundColor(c)
    }
}

struct PinRow: View {
    @EnvironmentObject var state: AppState
    let pin: PinAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { state.pinEnabled[pin.id] ?? false },
                                     set: { state.pinEnabled[pin.id] = $0 })) {
                    HStack(spacing: 6) {
                        Text(pin.role).font(.caption.weight(.bold)).foregroundColor(.secondary).frame(width: 30, alignment: .leading)
                        Text(pin.pin).font(.body.monospaced().weight(.semibold))
                        if let l = padBadge {
                            Text("pad \(l)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!pin.isCandidate)
                .help(pin.isCandidate ? "Tick to make \(pin.pin) (\(pin.label)) a servo output." : "This pad cannot be a servo output – see the reasons below.")
                Spacer()
                if pin.isCandidate {
                    Picker("", selection: Binding(get: { state.pinOption[pin.id] ?? pin.best?.id ?? "" },
                                                  set: { state.pinOption[pin.id] = $0 })) {
                        ForEach(pin.options.filter { $0.isUsable }) { o in
                            Text(optionLabel(o)).tag(o.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 250)
                } else {
                    Text("no usable timer").font(.caption).foregroundColor(.secondary)
                }
            }
            .onHover { inside in state.hoveredPin = inside ? pin.pin : nil }

            if let o = state.selectedOption(for: pin), pin.isCandidate {
                Text(o.detail).font(.caption2).foregroundColor(.secondary)
                ForEach(o.issues) { IssueRow(issue: $0).font(.caption) }
            }
            ForEach(pin.notes) { IssueRow(issue: $0) }
            let rejected = pin.options.filter { !$0.isUsable }
            if !rejected.isEmpty {
                DisclosureGroup("\(rejected.count) rejected timer option\(rejected.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rejected) { o in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.channel.id).font(.caption.monospaced().weight(.semibold))
                                ForEach(o.issues.filter { $0.severity == .blocker }) { IssueRow(issue: $0) }
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
                .font(.caption)
            }
        }
    }

    /// Board pad name, unless it just repeats the UART pin role (TX2 for UART2 TX).
    private var padBadge: String? {
        guard let l = state.analysis?.padLabel(pin.pin) else { return nil }
        if let n = pin.group.uartNumber, l == pin.role + String(n) { return nil }
        return l
    }

    private func optionLabel(_ o: TimerOption) -> String {
        var label = "\(o.channel.timer) \(o.channel.channel)  ·  \(shortKind(o.kind))"
        if o.takesMotors, let a = state.analysis {
            let nums = o.disablesMotors.compactMap { a.motorNumber($0) }.map(String.init).joined(separator: ", ")
            label += "  ·  disables motor " + nums
        }
        return label
    }

    private func shortKind(_ k: OptionKind) -> String {
        switch k {
        case .alreadyServo: return "already servo"
        case .upgradeExisting: return "upgrade existing"
        case .newEntry: return "new entry"
        case .unusable: return "unusable"
        }
    }
}
