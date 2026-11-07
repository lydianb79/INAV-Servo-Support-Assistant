import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    // Source tree
    @Published var inavRoot: URL?
    @Published var gitDescription: String = ""
    @Published var targets: [TargetSummary] = []
    @Published var showUnsupported = false
    @Published var searchText = ""

    // Selected target
    @Published var selectedTargetName: String? {
        didSet { if selectedTargetName != oldValue { loadSelectedTarget() } }
    }
    @Published var analysis: TargetAnalysis?
    @Published var loadError: String?

    // User choices, keyed by PinAnalysis.id ("UART2-TX")
    @Published var pinEnabled: [String: Bool] = [:]
    @Published var pinOption: [String: String] = [:]
    @Published var padMode: [String: UartMode] = [:]   // keyed by PadGroup.id
    @Published var portRefs: [PortReference] = []
    @Published var refAction: [Int: ReferenceAction] = [:]   // UART number -> action chosen by the user
    @Published var hoveredPin: String?

    // Peripheral planning
    @Published var receiverChoice: ReceiverChoice = .crsf
    @Published var wantGPS = true
    @Published var vtxChoice: VTXChoice = .smartAudio

    // Source management
    @Published var recentRoots: [URL] = []
    @Published var showStartSheet = false
    @Published var showStartScreenOnLaunch = true {
        didSet { UserDefaults.standard.set(showStartScreenOnLaunch, forKey: startKey) }
    }

    // Sheets / long running jobs
    @Published var showCloneSheet = false
    @Published var cloneFailed = false
    @Published var showDiffSheet = false
    @Published var showLogSheet = false
    @Published var logTitle = ""
    @Published var log = ""
    @Published var jobRunning = false
    @Published var statusMessage: String?
    @Published var alertMessage: String?

    private let runner = ProcessRunner()
    private let rootKey = "inavRootPath"
    private let recentsKey = "inavRecentRoots"
    private let startKey = "showStartScreenOnLaunch"

    init() {
        let defaults = UserDefaults.standard
        recentRoots = (defaults.stringArray(forKey: recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { TargetParser.isINAVRoot($0) }
        if defaults.object(forKey: startKey) != nil {
            showStartScreenOnLaunch = defaults.bool(forKey: startKey)
        }
        if let path = defaults.string(forKey: rootKey) {
            let url = URL(fileURLWithPath: path)
            if TargetParser.isINAVRoot(url) { setRoot(url) }
        }
        // Always offer the choice of source at launch (unless the user turned it off and a source exists).
        showStartSheet = showStartScreenOnLaunch || inavRoot == nil
    }

    // MARK: - Recents / start screen

    private func addRecent(_ url: URL) {
        var list = recentRoots.filter { $0.standardizedFileURL.path != url.standardizedFileURL.path }
        list.insert(url, at: 0)
        recentRoots = Array(list.prefix(8))
        UserDefaults.standard.set(recentRoots.map { $0.path }, forKey: recentsKey)
    }

    func removeRecent(_ url: URL) {
        recentRoots.removeAll { $0.path == url.path }
        UserDefaults.standard.set(recentRoots.map { $0.path }, forKey: recentsKey)
    }

    func openRecent(_ url: URL) {
        if TargetParser.isINAVRoot(url) {
            setRoot(url)
            showStartSheet = false
        } else {
            removeRecent(url)
            alertMessage = "\(url.path) is no longer an inav source tree."
        }
    }

    /// Opens the clone sheet, closing the start sheet first (only one sheet can be shown at a time).
    func presentClone() {
        if showStartSheet {
            showStartSheet = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showCloneSheet = true }
        } else {
            showCloneSheet = true
        }
    }

    func presentStartScreen() {
        showStartSheet = true
    }

    /// A folder name in `parent` that does not exist yet: inav, inav-2, inav-3 …
    func uniqueFolderName(in parent: URL, base: String = "inav") -> String {
        func usable(_ name: String) -> Bool {
            let st = cloneDestinationStatus(parent.appendingPathComponent(name))
            return st == .free || st == .emptyFolder
        }
        if usable(base) { return base }
        var i = 2
        while !usable("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    // MARK: - Source tree

    func chooseExistingSource() {
        let panel = NSOpenPanel()
        panel.title = "Select an inav source directory"
        panel.message = "Choose the root of an inav checkout (the folder that contains src/main/target)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = inavRoot { panel.directoryURL = current.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            if TargetParser.isINAVRoot(url) {
                setRoot(url)
                showStartSheet = false
            } else if TargetParser.isINAVRoot(url.appendingPathComponent("inav")) {
                setRoot(url.appendingPathComponent("inav"))
                showStartSheet = false
            } else {
                alertMessage = "\(url.path) does not look like an inav source tree (src/main/target and src/main/drivers/timer_def.h are missing)."
            }
        }
    }

    func setRoot(_ url: URL) {
        inavRoot = url
        UserDefaults.standard.set(url.path, forKey: rootKey)
        addRecent(url)
        searchText = ""
        targets = TargetParser.listTargets(root: url)
        selectedTargetName = nil
        analysis = nil
        refreshGitDescription()
        statusMessage = "\(targets.count) targets found in \(url.lastPathComponent)/src/main/target"
    }

    func reloadTargets() {
        guard let root = inavRoot else { return }
        targets = TargetParser.listTargets(root: root)
        loadSelectedTarget()
    }

    /// Light refresh (e.g. when the app becomes active): picks up target folders added or removed
    /// in Finder without discarding the current selection.
    func refreshTargetList() {
        guard let root = inavRoot, !jobRunning else { return }
        let fresh = TargetParser.listTargets(root: root)
        if fresh.map({ $0.name }) != targets.map({ $0.name }) {
            let added = Set(fresh.map { $0.name }).subtracting(targets.map { $0.name })
            targets = fresh
            if let sel = selectedTargetName, !fresh.contains(where: { $0.name == sel }) {
                selectedTargetName = nil
                statusMessage = "Target \(sel) no longer exists in \(root.lastPathComponent)/src/main/target."
            } else if !added.isEmpty {
                statusMessage = "New target folder(s): \(added.sorted().joined(separator: ", "))"
            }
        }
    }

    private func refreshGitDescription() {
        guard let root = inavRoot else { gitDescription = ""; return }
        gitDescription = ""
        var out = ""
        runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
                   arguments: ["-C", root.path, "log", "-1", "--format=%h %s (%cr)"],
                   in: nil, output: { out += $0 }) { [weak self] status in
            if status == 0 { self?.gitDescription = out.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    var filteredTargets: [TargetSummary] {
        targets.filter { t in
            (showUnsupported || t.isSupported) &&
            (searchText.isEmpty || t.name.localizedCaseInsensitiveContains(searchText)
             || t.mcuLabel.localizedCaseInsensitiveContains(searchText))
        }
    }

    // MARK: - Clone

    /// What is at a clone destination. Only `.free` and `.emptyFolder` can be cloned into
    /// (macOS' hidden .DS_Store does not count as content).
    enum CloneDestination: Equatable {
        case free
        case emptyFolder
        case inavCheckout
        case notEmpty([String])
        case isFile
    }

    func cloneDestinationStatus(_ dest: URL) -> CloneDestination {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir) else { return .free }
        if !isDir.boolValue { return .isFile }
        if TargetParser.isINAVRoot(dest) { return .inavCheckout }
        let items = ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).filter { $0 != ".DS_Store" }
        return items.isEmpty ? .emptyFolder : .notEmpty(items.sorted())
    }

    func clone(url: String, branch: String, shallow: Bool, parent: URL, folderName: String) {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = parent.appendingPathComponent(name)
        switch cloneDestinationStatus(dest) {
        case .free:
            break
        case .emptyFolder:
            // git refuses non-empty folders; an invisible .DS_Store would make it fail
            try? FileManager.default.removeItem(at: dest.appendingPathComponent(".DS_Store"))
        case .inavCheckout:
            alertMessage = "\(dest.path) already contains an inav checkout – it has been opened instead. Choose another folder name to clone a fresh copy."
            setRoot(dest)
            showCloneSheet = false
            showStartSheet = false
            return
        case .notEmpty(let items):
            alertMessage = "\(dest.path) already exists and is not empty (\(items.prefix(5).joined(separator: ", "))\(items.count > 5 ? ", …" : "")). Choose another folder name."
            return
        case .isFile:
            alertMessage = "A file named \(dest.path) already exists. Choose another folder name."
            return
        }
        var args = ["clone", "--progress"]
        if shallow { args += ["--depth", "1"] }
        if !branch.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--branch", branch.trimmingCharacters(in: .whitespaces)] }
        args += [url, dest.path]
        startJob(title: "git clone \(url)", showSheet: false)
        cloneFailed = false
        log += "$ git " + args.joined(separator: " ") + "\n"
        runner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, in: parent,
                   output: { [weak self] in self?.log += $0 }) { [weak self] status in
            guard let self = self else { return }
            self.jobRunning = false
            if status == 0 && TargetParser.isINAVRoot(dest) {
                self.log += "\nClone finished – \(dest.path) is now the active source.\n"
                self.setRoot(dest)
                self.showCloneSheet = false
                self.showStartSheet = false
            } else {
                self.log += "\ngit exited with status \(status) – the clone did not complete.\n"
                self.cloneFailed = true
            }
        }
    }

    // MARK: - Target

    func loadSelectedTarget() {
        analysis = nil
        loadError = nil
        pinEnabled = [:]
        pinOption = [:]
        padMode = [:]
        portRefs = []
        refAction = [:]
        guard let root = inavRoot, let name = selectedTargetName else { return }
        do {
            let target = try TargetParser.parse(root: root, name: name)
            guard let mcu = target.mcu else {
                loadError = "\(name) uses MCU '\(target.mcuFunction ?? "unknown")', which this helper has no datasheet data for."
                return
            }
            let chip = try ChipDatabase(inavRoot: root, mcu: mcu)
            let a = Analyzer.analyze(target: target, chip: chip)
            for g in a.groups {
                padMode[g.id] = g.requiresDedicated ? .dedicated : .shared
                for p in g.pins {
                    pinEnabled[p.id] = false
                    if let b = p.best { pinOption[p.id] = b.id }
                }
            }
            portRefs = PortReferences.find(in: target)
            analysis = a
        } catch {
            loadError = error.localizedDescription
        }
    }

    func pin(_ id: String) -> PinAnalysis? {
        analysis?.allPins.first { $0.id == id }
    }

    func selectedOption(for pin: PinAnalysis) -> TimerOption? {
        let id = pinOption[pin.id] ?? pin.best?.id
        return pin.options.first { $0.id == id && $0.isUsable } ?? pin.best
    }

    func setGroup(_ group: PadGroup, enabled: Bool) {
        for p in group.pins where p.isCandidate { pinEnabled[p.id] = enabled }
    }

    func isGroupSelected(_ group: PadGroup) -> Bool {
        group.pins.contains { pinEnabled[$0.id] == true }
    }

    func togglePin(named pinName: String) {
        guard let a = analysis else { return }
        for p in a.allPins where p.pin == pinName && p.isCandidate {
            pinEnabled[p.id] = !(pinEnabled[p.id] ?? false)
        }
    }

    var choices: [ServoChoice] {
        guard let a = analysis else { return [] }
        var result = [ServoChoice]()
        for g in a.groups {
            for p in g.pins where pinEnabled[p.id] == true {
                if let o = selectedOption(for: p) {
                    result.append(ServoChoice(pin: p, option: o, mode: padMode[g.id] ?? .shared))
                }
            }
        }
        return result
    }

    var portPlan: PortPlan? {
        guard let a = analysis else { return nil }
        return PortPlanner.plan(analysis: a, choices: choices, receiver: receiverChoice, gps: wantGPS, vtx: vtxChoice)
    }

    var selectionIssues: [Issue] {
        guard let a = analysis else { return [] }
        var issues = Analyzer.crossCheck(selected: choices.map { (pin: $0.pin, option: $0.option) }, target: a.target)
        for u in a.groups where isGroupSelected(u) {
            if u.requiresDedicated && padMode[u.id] == .shared {
                issues.append(Issue(severity: .warning, text: "UART1 in shared mode: inav does not skip timer outputs on UART1 pads – serial and servo would fight for the pins."))
            }
            if let n = u.kind.uartNumber {
                let refs = references(forUART: n)
                if !refs.isEmpty && refActionFor(n) == .keep {
                    if padMode[u.id] == .dedicated && refs.contains(where: { $0.isUnsafeIfRemoved }) {
                        issues.append(Issue(severity: .blocker, text: "config.c still configures \(u.name), which dedicated mode removes – inav would write outside the port table (portConfigs[-1]). Move or remove those lines."))
                    } else if padMode[u.id] != .dedicated {
                        issues.append(Issue(severity: .warning, text: "\(u.name) gets a default function (\(refs.map { $0.functionLabel }.joined(separator: ", "))) – its servo outputs stay off until that function is removed in the Ports tab."))
                    }
                }
            }
            if u.kind.isLED && padMode[u.id] == .shared && a.ledInDefaultFeatures {
                issues.append(Issue(severity: .warning, text: "LED pad in shared mode: FEATURE_LED_STRIP is on by default – disable LED_STRIP in the configurator to use the servo."))
            }
        }
        return issues
    }

    var plan: Result<PatchPlan, Error> {
        guard let a = analysis else { return .failure(PatchError.nothingSelected) }
        do {
            return .success(try Patcher.makePlan(target: a.target, choices: choices,
                                                 references: selectedReferences, actions: effectiveRefActions))
        }
        catch { return .failure(error) }
    }

    // MARK: - Port references (config.c / target.h defaults)

    /// UARTs that have at least one pad selected as servo.
    var selectedUARTs: Set<Int> {
        Set(choices.compactMap { $0.pin.group.uartNumber })
    }

    func references(forUART n: Int) -> [PortReference] {
        portRefs.filter { $0.uart == n }
    }

    /// References of UARTs that are being converted.
    var selectedReferences: [PortReference] {
        let sel = selectedUARTs
        return portRefs.filter { sel.contains($0.uart) }
    }

    /// Hardware UARTs that stay free (not selected) and have TX + RX – possible new homes for moved settings.
    func replacementUARTs(excluding n: Int) -> [Int] {
        guard let plan = portPlan else { return [] }
        return plan.ports.filter { !$0.isSoftSerial && $0.state.isFree && $0.tx != nil && $0.rx != nil && $0.tx != $0.rx }
            .compactMap { Int($0.id.dropFirst(4)) }
            .filter { $0 != n }
    }

    /// Default: follow the port planner for receiver / GPS / VTX, otherwise first free UART, otherwise remove.
    func defaultRefAction(forUART n: Int) -> ReferenceAction {
        let refs = references(forUART: n)
        let candidates = replacementUARTs(excluding: n)
        if let fn = PortReferences.mainFunction(refs), let plan = portPlan {
            let peripheral: Peripheral?
            switch fn {
            case "RX_SERIAL": peripheral = receiverChoice.peripheral
            case "GPS": peripheral = wantGPS ? .gps : nil
            case "VTX_SMARTAUDIO", "VTX_TRAMP": peripheral = .vtxSmartAudio
            case "MSP_OSD": peripheral = .vtxMSP
            default: peripheral = nil
            }
            if let p = peripheral, let port = plan.assignment[p], port.hasPrefix("UART"),
               let m = Int(port.dropFirst(4)), m != n {
                return .moveTo(m)
            }
        }
        if let first = candidates.first { return .moveTo(first) }
        return .remove
    }

    func refActionFor(_ n: Int) -> ReferenceAction {
        refAction[n] ?? defaultRefAction(forUART: n)
    }

    var effectiveRefActions: [Int: ReferenceAction] {
        var d = [Int: ReferenceAction]()
        for n in selectedUARTs where !references(forUART: n).isEmpty { d[n] = refActionFor(n) }
        return d
    }

    // MARK: - After-flash CLI

    var cliSnippet: String {
        guard let a = analysis else { return "" }
        var lines = ["# INAV Servo Support Assistant – CLI after flashing \(a.target.name)", "# paste into the configurator's CLI tab"]
        let selected = choices
        if !selected.isEmpty {
            lines.append("")
            lines.append("# servo pads")
            for c in selected {
                lines.append("#   \(c.pin.pin) (\(c.pin.label)) -> \(c.option.channel.timer) \(c.option.channel.channel)")
            }
            lines.append("feature PWM_OUTPUT_ENABLE")
            let ledInvolved = selected.contains { $0.pin.group.isLED && $0.mode == .shared }
                || selected.contains { c in c.option.issues.contains { $0.text.contains("LED strip") } }
            if ledInvolved { lines.append("feature -LED_STRIP          # LED strip timer is used for a servo") }
        }
        // shared UARTs must not have any function, otherwise inav switches their servo outputs off
        let sharedUARTs = Set(selected.filter { $0.mode == .shared }.compactMap { $0.pin.group.uartNumber })
        if !sharedUARTs.isEmpty {
            lines.append("")
            lines.append("# UARTs used as servo pads in shared mode: no function assigned")
            for n in sharedUARTs.sorted() { lines.append("serial \(n - 1) 0                # UART\(n)") }
        }
        if let plan = portPlan, !plan.assignment.isEmpty {
            lines.append("")
            lines.append("# peripherals on the remaining ports (serial <port id> <function mask>)")
            for p in Peripheral.allCases {
                guard let portID = plan.assignment[p], let id = Self.cliPortID(portID) else { continue }
                let (mask, name) = Self.functionMask(for: p)
                lines.append("serial \(id) \(mask)".padded(to: 26) + "# \(portID): \(name)")
            }
            if let rx = receiverChoice.peripheral, plan.assignment[rx] != nil {
                lines.append("set receiver_type = SERIAL")
                lines.append("set serialrx_provider = \(receiverChoice == .sbus ? "SBUS" : "CRSF")")
            }
        }
        lines.append("")
        lines.append("save")
        return lines.joined(separator: "\n")
    }

    static func cliPortID(_ portID: String) -> Int? {
        if portID.hasPrefix("UART"), let n = Int(portID.dropFirst(4)) { return n - 1 }
        if portID.hasPrefix("SOFTSERIAL"), let n = Int(portID.dropFirst(10)) { return 29 + n }
        return nil
    }

    /// inav serialPortFunction_e bit values (io/serial.h)
    static func functionMask(for p: Peripheral) -> (Int, String) {
        switch p {
        case .receiverCRSF, .receiverSBUS: return (1 << 6, "serial receiver")
        case .gps: return (1 << 1, "GPS")
        case .vtxSmartAudio: return (1 << 11, "VTX SmartAudio (Tramp: use \(1 << 12))")
        case .vtxMSP: return (1 << 25, "MSP DisplayPort")
        }
    }

    func copyCLI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cliSnippet, forType: .string)
        statusMessage = "CLI commands copied to the clipboard."
    }

    // MARK: - Apply / revert

    func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".servo-backup")
    }

    var hasBackup: Bool {
        guard let t = analysis?.target else { return false }
        let fm = FileManager.default
        return [t.cURL, t.hURL, t.configURL].contains { fm.fileExists(atPath: backupURL(for: $0).path) }
    }

    func apply() {
        guard case .success(let plan) = self.plan, plan.hasChanges else {
            alertMessage = "Nothing to apply."
            return
        }
        let t = plan.target
        let fm = FileManager.default
        do {
            var files = [t.cURL, t.hURL]
            if plan.configChanged { files.append(t.configURL) }
            for url in files {
                let b = backupURL(for: url)
                if !fm.fileExists(atPath: b.path) { try fm.copyItem(at: url, to: b) }
            }
            if plan.cChanged { try plan.newC.write(to: t.cURL, atomically: true, encoding: .utf8) }
            if plan.hChanged { try plan.newH.write(to: t.hURL, atomically: true, encoding: .utf8) }
            if plan.configChanged, let cfg = plan.newConfig { try cfg.write(to: t.configURL, atomically: true, encoding: .utf8) }
            statusMessage = "Applied \(choices.count) servo pad(s) to \(t.name). Backups: target.c.servo-backup / target.h.servo-backup"
            showDiffSheet = false
            loadSelectedTarget()
        } catch {
            alertMessage = "Writing files failed: \(error.localizedDescription)"
        }
    }

    func revert() {
        guard let t = analysis?.target else { return }
        let fm = FileManager.default
        do {
            for url in [t.cURL, t.hURL, t.configURL] {
                let b = backupURL(for: url)
                if fm.fileExists(atPath: b.path) {
                    let s = try String(contentsOf: b, encoding: .utf8)
                    try s.write(to: url, atomically: true, encoding: .utf8)
                    try fm.removeItem(at: b)
                }
            }
            statusMessage = "\(t.name) restored from backup."
            loadSelectedTarget()
        } catch {
            alertMessage = "Revert failed: \(error.localizedDescription)"
        }
    }

    func revealTarget() {
        guard let t = analysis?.target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([t.cURL, t.hURL])
    }

    // MARK: - Test build

    func testBuild() {
        guard let root = inavRoot, let t = analysis?.target else { return }
        let buildTarget = t.variants.first ?? t.name
        // Always re-run cmake: inav's CMake scans src/main/target when it configures, so a target folder
        // added after the first configure would otherwise be unknown to make ("No rule to make target").
        let cmd = "cd \(shellQuote(root.path)) && mkdir -p build && cd build && " +
                  "cmake .. && make \(shellQuote(buildTarget))"
        startJob(title: "Build \(buildTarget)")
        log += "Shared ARM toolchain cache: \(Self.sharedToolchainDir.path)\n"
        log += "$ \(cmd)\n"
        let full = Self.toolchainLinkScript(root: root) + "\n" + cmd
        runner.runShell(full, in: root, output: { [weak self] in
            guard let self = self else { return }
            self.log += $0
            if self.log.count > 400_000 { self.log = String(self.log.suffix(300_000)) }
        }) { [weak self] status in
            guard let self = self else { return }
            self.jobRunning = false
            self.log += status == 0 ? "\n✅ Build succeeded.\n" : "\n❌ Build failed (status \(status)).\n"
        }
    }

    // MARK: - Shared ARM toolchain

    /// inav's CMake downloads arm-none-eabi-gcc into <inav>/downloads and unpacks it into <inav>/tools.
    /// Both folders are linked to one shared cache so the compiler is downloaded only once,
    /// no matter how often the inav folder is re-cloned. The unpacked folder name contains the
    /// compiler version, so different inav versions can share the cache.
    static var sharedToolchainDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("INAV Servo Support Assistant/toolchain")
    }

    static func toolchainLinkScript(root: URL) -> String {
        let shared = shellQuote(sharedToolchainDir.path)
        return """
        SHARED=\(shared)
        mkdir -p "$SHARED/tools" "$SHARED/downloads"
        cd \(shellQuote(root.path)) || exit 1
        for d in tools downloads; do
          if [ -L "$d" ]; then
            :
          elif [ -d "$d" ]; then
            if [ -z "$(ls -A "$d")" ]; then
              rmdir "$d" && ln -s "$SHARED/$d" "$d" && echo "toolchain cache: linked $d -> shared cache"
            elif [ -z "$(ls -A "$SHARED/$d")" ]; then
              echo "toolchain cache: moving this checkout's $d folder into the shared cache"
              rmdir "$SHARED/$d" && mv "$d" "$SHARED/$d" && ln -s "$SHARED/$d" "$d"
            else
              echo "toolchain cache: keeping this checkout's own $d folder (shared cache already filled)"
            fi
          else
            ln -s "$SHARED/$d" "$d" && echo "toolchain cache: linked $d -> shared cache"
          fi
        done
        if [ -d .git/info ]; then
          for p in /tools /downloads; do
            grep -qxF "$p" .git/info/exclude 2>/dev/null || echo "$p" >> .git/info/exclude
          done
        fi
        """
    }

    func revealToolchainCache() {
        let dir = Self.sharedToolchainDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func cancelJob() {
        runner.cancel()
    }

    /// `showSheet: false` is used when the job is shown inside an already open sheet (clone):
    /// macOS cannot present a second sheet on top of it.
    private func startJob(title: String, showSheet: Bool = true) {
        logTitle = title
        log = ""
        jobRunning = true
        if showSheet { showLogSheet = true }
    }
}
