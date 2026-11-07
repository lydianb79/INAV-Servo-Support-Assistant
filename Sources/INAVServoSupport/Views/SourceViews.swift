import SwiftUI

/// Toolbar / sidebar menu to switch the inav source at any time.
struct SourceMenu: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        Menu {
            Button { state.chooseExistingSource() } label: { Label("Open Other inav Folder…", systemImage: "folder") }
            Button { state.presentClone() } label: { Label("Clone inav Again…", systemImage: "arrow.down.circle") }
            if !state.recentRoots.isEmpty {
                Divider()
                Section("Recent sources") {
                    ForEach(state.recentRoots, id: \.self) { url in
                        Button {
                            state.openRecent(url)
                        } label: {
                            if url.path == state.inavRoot?.path {
                                Label(url.path, systemImage: "checkmark")
                            } else {
                                Text(url.path)
                            }
                        }
                    }
                }
            }
            Divider()
            Button { state.presentStartScreen() } label: { Label("Show Start Screen…", systemImage: "rectangle.grid.1x2") }
        } label: {
            if compact {
                Label("Change", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Source", systemImage: "folder")
            }
        }
        .help("Choose another inav source folder or clone a fresh copy")
    }
}

/// Shown at launch (and on demand): continue with the last source, pick another one or clone.
struct StartSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34)).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("INAV Servo Support Helper").font(.title2.weight(.semibold))
                    Text("Choose the inav source tree to work on.").foregroundColor(.secondary)
                }
            }

            if let root = state.inavRoot {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current source").font(.caption).foregroundColor(.secondary)
                            Text(root.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            if !state.gitDescription.isEmpty {
                                Text(state.gitDescription).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Continue") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(4)
                }
            }

            let others = state.recentRoots.filter { $0.path != state.inavRoot?.path }
            if !others.isEmpty {
                Text("Recent sources").font(.headline)
                VStack(spacing: 0) {
                    ForEach(others, id: \.self) { url in
                        HStack {
                            Image(systemName: "folder").foregroundColor(.secondary)
                            Text(url.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Open") { state.openRecent(url) }
                            Button { state.removeRecent(url) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Remove from list")
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
            }

            HStack(spacing: 12) {
                Button { state.chooseExistingSource() } label: {
                    Label("Open other inav folder…", systemImage: "folder")
                }
                .controlSize(.large)
                Button { state.presentClone() } label: {
                    Label(state.inavRoot == nil ? "Clone from GitHub…" : "Clone a fresh copy…", systemImage: "arrow.down.circle")
                }
                .controlSize(.large)
                Spacer()
                if state.inavRoot == nil {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }

            Toggle("Show this screen when the app starts", isOn: $state.showStartScreenOnLaunch)
                .toggleStyle(.checkbox).font(.caption)
        }
        .padding(22)
        .frame(width: 620)
    }
}
