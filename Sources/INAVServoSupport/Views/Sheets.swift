import SwiftUI
import AppKit

struct CloneSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var url = "https://github.com/iNavFlight/inav.git"
    @State private var branch = "master"
    @State private var shallow = true
    @State private var parent: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    @State private var folderName = "inav"
    @StateObject private var refs = RemoteRefsModel()
    private var destination: URL {
        parent.appendingPathComponent(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var status: AppState.CloneDestination { state.cloneDestinationStatus(destination) }
    private var canClone: Bool {
        switch status {
        case .free, .emptyFolder, .inavCheckout: return true
        case .notEmpty, .isFile: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone inav").font(.title2.weight(.semibold))
            Form {
                TextField("Repository URL", text: $url)
                    .onSubmit { refs.load(url: url) }
                HStack {
                    TextField("Branch / tag", text: $branch)
                    branchStatusIcon
                }
                Toggle("Shallow clone (--depth 1, much faster)", isOn: $shallow)
                HStack {
                    TextField("Destination", text: .constant(parent.path)).disabled(true)
                    Button("Choose…") { chooseParent() }
                }
                TextField("Folder name", text: $folderName)
            }
            if !state.jobRunning {
                BranchPickerBox(refs: refs, url: url, branch: $branch)
            }
            if state.jobRunning || state.cloneFailed {
                cloneProgress
            }
            if !state.jobRunning {
                destinationInfo
            }
            HStack {
                if state.jobRunning {
                    Button("Stop Clone") { state.cancelJob() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.jobRunning)
                Button("Clone") {
                    state.clone(url: url, branch: branch, shallow: shallow, parent: parent, folderName: folderName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || folderName.trimmingCharacters(in: .whitespaces).isEmpty || state.jobRunning || !canClone)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            if let current = state.inavRoot { parent = current.deletingLastPathComponent() }
            folderName = state.uniqueFolderName(in: parent)
            state.cloneFailed = false
            refs.load(url: url)
        }
        .onChange(of: url) { _ in refs.markStale(for: url) }
    }

    /// ✓ when the typed branch / tag exists on the remote, ⚠ when the list is loaded and it doesn't.
    @ViewBuilder private var branchStatusIcon: some View {
        if refs.loadedURL == url, !refs.refs.isEmpty {
            let name = branch.trimmingCharacters(in: .whitespaces)
            if refs.refs.contains(where: { $0.name == name }) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    .help("\(name) exists on the remote")
            } else if !name.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    .help("No branch or tag named '\(name)' on the remote – git clone will fail")
            }
        }
    }

    /// git output shown inside the sheet while cloning (a second sheet cannot be presented on top).
    private var cloneProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.jobRunning {
                    ProgressView().controlSize(.small)
                    Text("Cloning into \(destination.path) …").font(.caption)
                } else {
                    Label("Clone failed – see the git output below. Fix the problem and press Clone again.",
                          systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundColor(.red)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.log.isEmpty ? "starting git …" : state.log)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: state.log) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var destinationInfo: some View {
        switch status {
        case .free:
            Label("Will create \(destination.path)", systemImage: "folder.badge.plus")
                .font(.caption).foregroundColor(.secondary)
        case .emptyFolder:
            Label("\(destination.path) exists and is empty – inav will be cloned into it.", systemImage: "checkmark.circle")
                .font(.caption).foregroundColor(.green)
        case .inavCheckout:
            HStack {
                Label("\(destination.path) already is an inav checkout – Clone opens it instead.", systemImage: "info.circle")
                    .font(.caption).foregroundColor(.blue)
                Spacer()
                Button("Use \(state.uniqueFolderName(in: parent))") { folderName = state.uniqueFolderName(in: parent) }
                    .controlSize(.small)
            }
        case .notEmpty(let items):
            HStack {
                Label("\(destination.path) already exists and contains \(items.count) item\(items.count == 1 ? "" : "s"): \(items.prefix(4).joined(separator: ", "))\(items.count > 4 ? ", …" : "")",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                Spacer()
                Button("Use \(state.uniqueFolderName(in: parent))") { folderName = state.uniqueFolderName(in: parent) }
                    .controlSize(.small)
            }
        case .isFile:
            Label("A file named \(destination.path) exists – choose another folder name.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let u = panel.url {
            parent = u
            folderName = state.uniqueFolderName(in: u)
        }
    }
}

/// Holds the branches / tags of the clone URL (loaded with `git ls-remote`).
@MainActor final class RemoteRefsModel: ObservableObject {
    @Published var refs: [RemoteRef] = []
    @Published var loading = false
    @Published var error: String?
    @Published var loadedURL: String?
    private var generation = 0

    func load(url: String) {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        generation += 1
        let gen = generation
        loading = true
        error = nil
        RemoteRefs.load(url: u) { [weak self] result in
            guard let self = self, gen == self.generation else { return }   // a newer request won
            self.loading = false
            switch result {
            case .success(let r):
                self.refs = r
                self.loadedURL = url
            case .failure(let e):
                self.refs = []
                self.loadedURL = nil
                self.error = e.message
            }
        }
    }

    /// The URL was edited: the list no longer belongs to it.
    func markStale(for url: String) {
        if loadedURL != url { generation += 1; loading = false; error = nil }
    }
}

/// Searchable list of the remote's branches and tags; clicking one puts it into the Branch / tag field.
struct BranchPickerBox: View {
    @ObservedObject var refs: RemoteRefsModel
    let url: String
    @Binding var branch: String
    @State private var search = ""
    @State private var kind: RemoteRef.Kind = .branch

    private var isCurrent: Bool { refs.loadedURL == url }
    private var filtered: [RemoteRef] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return refs.refs.filter { $0.kind == kind && (q.isEmpty || $0.name.lowercased().contains(q)) }
    }
    private func count(_ k: RemoteRef.Kind) -> Int { refs.refs.filter { $0.kind == k }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search branches and tags", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $kind) {
                    Text("Branches (\(isCurrent ? count(.branch) : 0))").tag(RemoteRef.Kind.branch)
                    Text("Tags (\(isCurrent ? count(.tag) : 0))").tag(RemoteRef.Kind.tag)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                Button { refs.load(url: url) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload branches and tags from the repository")
                    .disabled(refs.loading)
            }
            listArea
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
    }

    @ViewBuilder private var listArea: some View {
        if refs.loading {
            centered { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading branches and tags …") } }
        } else if let e = refs.error {
            centered {
                VStack(spacing: 6) {
                    Label("Could not load branches", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(e).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    Text("You can still type a branch or tag name above.").font(.caption).foregroundColor(.secondary)
                }.padding(8)
            }
        } else if !isCurrent {
            centered {
                Button("Load branches for this URL") { refs.load(url: url) }
            }
        } else if filtered.isEmpty {
            centered { Text(search.isEmpty ? "No \(kind == .branch ? "branches" : "tags")" : "No match for '\(search)'").foregroundColor(.secondary) }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { ref in row(ref).id(ref.id) }
                    }
                }
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: kind) { _ in scrollToSelection(proxy) }
            }
        }
    }

    private func row(_ ref: RemoteRef) -> some View {
        let selected = ref.name == branch.trimmingCharacters(in: .whitespaces)
        return Button { branch = ref.name } label: {
            HStack(spacing: 6) {
                Image(systemName: ref.kind == .branch ? "arrow.triangle.branch" : "tag")
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 16)
                Text(ref.name).font(.system(.body, design: .monospaced))
                if ref.name == "master" || ref.name == "main" {
                    Text("default").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(selected ? 0.4 : 0.18)))
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
            .foregroundColor(selected ? .white : .primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let name = branch.trimmingCharacters(in: .whitespaces)
        if let r = filtered.first(where: { $0.name == name }) {
            DispatchQueue.main.async { proxy.scrollTo(r.id, anchor: .center) }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LogSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.logTitle).font(.headline)
                Spacer()
                if state.jobRunning { ProgressView().controlSize(.small) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: state.log) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.log, forType: .string)
                }
                if !state.jobRunning && state.lastHex != nil && state.logTitle.hasPrefix("Build") {
                    Button { state.revealHex() } label: { Label("Reveal .hex", systemImage: "doc.badge.gearshape") }
                    Button { state.confirmFlash() } label: { Label("Flash via DFU…", systemImage: "bolt.horizontal.circle") }
                }
                Spacer()
                if state.jobRunning {
                    Button("Stop") { state.cancelJob() }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).disabled(state.jobRunning)
            }
        }
        .padding(16)
        .frame(width: 760, height: 520)
    }
}

struct DiffSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var file = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.plan {
            case .failure(let error):
                Text("Cannot build the change set").font(.headline)
                Text(error.localizedDescription).foregroundColor(.red)
                HStack { Spacer(); Button("Close") { dismiss() } }
            case .success(let plan):
                HStack {
                    Text("Review changes – \(plan.target.name)").font(.title3.weight(.semibold))
                    Spacer()
                    Picker("", selection: $file) {
                        Text("target.c").tag(0)
                        Text("target.h").tag(1)
                        if plan.target.configText != nil {
                            Text("config.c").tag(3)
                        }
                        Text("Summary").tag(2)
                        Text("CLI").tag(4)
                    }
                    .pickerStyle(.segmented).frame(width: 420)
                }
                HStack(spacing: 12) {
                    Picker("Apply to", selection: $state.applyAsCopy) {
                        Text("This target (in place)").tag(false)
                        Text("New target copy").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    if state.applyAsCopy {
                        TextField("New target name", text: $state.copyName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        if let problem = state.copyNameProblem {
                            Text(problem).font(.caption).foregroundColor(.red)
                        } else {
                            Text("build with: make \(state.copyName)").font(.caption.monospaced()).foregroundColor(.secondary)
                        }
                    } else {
                        Toggle("Back up target folder first", isOn: $state.backupBeforeApply)
                            .toggleStyle(.checkbox)
                            .help("Copies src/main/target/\(plan.target.name) to <inav>/.servo-backups/\(plan.target.name)/<date-time> before writing. Restore it via More → Restore target backup.")
                    }
                    Spacer()
                }
                if state.applyAsCopy {
                    Text("A new folder src/main/target/\(state.copyName) is created with the changes below; \(plan.target.name) stays untouched. Variant names get the new prefix and target.h maps them back to the original macros.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if file == 2 {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(plan.changes, id: \.self) { c in Label(c, systemImage: "pencil").font(.callout) }
                                ForEach(plan.warnings) { w in IssueRow(issue: w) }
                                Text(state.applyAsCopy
                                     ? "The original target is not modified."
                                     : (state.backupBeforeApply
                                        ? "Before writing, the whole target folder is copied to .servo-backups/\(plan.target.name)/<date-time> (restore via More → Restore target backup). target.c / target.h / config.c .servo-backup files are also kept for Revert to Backup."
                                        : "target.c / target.h / config.c .servo-backup files are written next to the originals (only if none exist yet) for Revert to Backup."))
                                    .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    } else if file == 4 {
                        ScrollView([.vertical, .horizontal]) {
                            Text(state.cliSnippet)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    } else if file == 3 {
                        DiffTextView(lines: LineDiff.diff(old: plan.target.configText ?? "", new: plan.newConfig ?? ""))
                    } else {
                        DiffTextView(lines: file == 0 ? LineDiff.diff(old: plan.target.cText, new: plan.newC)
                                                      : LineDiff.diff(old: plan.target.hText, new: plan.newH))
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(modifiedFiles(plan))
                        .font(.caption).foregroundColor(.secondary)
                    if file == 4 {
                        Button { state.copyCLI() } label: { Label("Copy CLI", systemImage: "doc.on.doc") }
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button { state.exportPatch() } label: { Label("Export .patch…", systemImage: "square.and.arrow.up") }
                        .disabled(!plan.hasChanges || state.copyNameProblem != nil)
                    Button(state.applyAsCopy ? "Create \(state.copyName)" : "Apply to Source") { state.apply() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.hasChanges || state.copyNameProblem != nil)
                }
            }
        }
        .padding(16)
        .frame(width: 960, height: 680)
    }
}

extension DiffSheet {
    func modifiedFiles(_ plan: PatchPlan) -> String {
        var files = [String]()
        if plan.cChanged { files.append("target.c") }
        if plan.hChanged { files.append("target.h") }
        if plan.configChanged { files.append("config.c") }
        return files.isEmpty ? "No file changes." : files.joined(separator: ", ") + " will be modified."
    }
}

struct DiffTextView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            if lines.allSatisfy({ $0.kind == .gap }) || lines.isEmpty {
                Text("No changes in this file.").foregroundColor(.secondary).padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { l in
                        HStack(spacing: 0) {
                            Text(l.oldNumber.map { String($0) } ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                            Text(l.newNumber.map { String($0) } ?? "").frame(width: 40, alignment: .trailing).foregroundColor(.secondary)
                            Text(prefix(l.kind)).frame(width: 18).foregroundColor(.secondary)
                            Text(l.text.isEmpty ? " " : l.text).fixedSize()
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(background(l.kind))
                    }
                }
                .padding(6)
            }
        }
    }

    private func prefix(_ k: DiffLine.Kind) -> String {
        switch k { case .added: return "+"; case .removed: return "−"; case .same: return " "; case .gap: return "⋯" }
    }

    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return Color.green.opacity(0.18)
        case .removed: return Color.red.opacity(0.18)
        case .gap: return Color.gray.opacity(0.08)
        case .same: return Color.clear
        }
    }
}

struct IssueRow: View {
    let issue: Issue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundColor(color)
            Text(issue.text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbol: String {
        switch issue.severity {
        case .blocker: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .blocker: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
