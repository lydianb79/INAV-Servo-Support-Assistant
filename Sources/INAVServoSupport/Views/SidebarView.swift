import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let root = state.inavRoot {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(root.lastPathComponent, systemImage: "folder.fill").font(.headline)
                        Spacer()
                        SourceMenu(compact: true)
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                    Text(root.path).font(.caption2).foregroundColor(.secondary).lineLimit(2).truncationMode(.middle)
                    if !state.gitDescription.isEmpty {
                        Text(state.gitDescription).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                    }
                    Toggle("Show unsupported MCUs", isOn: $state.showUnsupported)
                        .font(.caption).toggleStyle(.checkbox).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                Divider()
                List(state.filteredTargets, id: \.name, selection: $state.selectedTargetName) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.body.monospaced())
                            if t.variants.count > 1 {
                                Text(t.variants.joined(separator: ", ")).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(t.mcuLabel)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(t.isSupported ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15)))
                            .foregroundColor(t.isSupported ? .accentColor : .secondary)
                    }
                    .tag(t.name)
                }
                .listStyle(.sidebar)
                .searchable(text: $state.searchText, placement: .sidebar, prompt: "Filter targets / MCU")
                if let s = state.statusMessage {
                    Divider()
                    Text(s).font(.caption2).foregroundColor(.secondary).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text("No inav source selected").foregroundColor(.secondary)
                Button("Choose Source…") { state.presentStartScreen() }.padding(.top, 6)
                Spacer()
            }
        }
    }
}
