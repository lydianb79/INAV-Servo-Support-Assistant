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
                TextField("Branch / tag", text: $branch)
                Toggle("Shallow clone (--depth 1, much faster)", isOn: $shallow)
                HStack {
                    TextField("Destination", text: .constant(parent.path)).disabled(true)
                    Button("Choose…") { chooseParent() }
                }
                TextField("Folder name", text: $folderName)
            }
            destinationInfo
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone") {
                    state.clone(url: url, branch: branch, shallow: shallow, parent: parent, folderName: folderName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || folderName.trimmingCharacters(in: .whitespaces).isEmpty || state.jobRunning || !canClone)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let current = state.inavRoot { parent = current.deletingLastPathComponent() }
            folderName = state.uniqueFolderName(in: parent)
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
                        Text("Summary").tag(2)
                    }
                    .pickerStyle(.segmented).frame(width: 280)
                }
                Group {
                    if file == 2 {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(plan.changes, id: \.self) { c in Label(c, systemImage: "pencil").font(.callout) }
                                ForEach(plan.warnings) { w in IssueRow(issue: w) }
                                Text("Backups are written next to the originals as target.c.servo-backup / target.h.servo-backup (only if none exist yet).")
                                    .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    } else {
                        DiffTextView(lines: file == 0 ? LineDiff.diff(old: plan.target.cText, new: plan.newC)
                                                      : LineDiff.diff(old: plan.target.hText, new: plan.newH))
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("\(plan.cChanged ? "target.c" : "")\(plan.cChanged && plan.hChanged ? " and " : "")\(plan.hChanged ? "target.h" : "") will be modified.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Apply to Source") { state.apply() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.hasChanges)
                }
            }
        }
        .padding(16)
        .frame(width: 900, height: 620)
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
