import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            Group {
                if state.inavRoot == nil {
                    WelcomeView()
                } else if let a = state.analysis {
                    TargetDetailView(analysis: a)
                } else if let err = state.loadError {
                    MessageView(symbol: "exclamationmark.triangle", title: "Target not supported", message: err)
                } else {
                    MessageView(symbol: "cpu", title: "Pick a target",
                                message: "Select a board from src/main/target in the list on the left.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SourceMenu()
                Button { state.presentClone() } label: { Label("Clone", systemImage: "arrow.down.circle") }
                    .help("Clone inav from GitHub")
                if state.analysis != nil {
                    Button { state.revealTarget() } label: { Label("Reveal", systemImage: "magnifyingglass") }
                        .help("Show target.c / target.h in Finder")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshTargetList()
        }
        .sheet(isPresented: $state.showStartSheet) { StartSheet().environmentObject(state) }
        .sheet(isPresented: $state.showCloneSheet) { CloneSheet().environmentObject(state) }
        .sheet(isPresented: $state.showDiffSheet) { DiffSheet().environmentObject(state) }
        .sheet(isPresented: $state.showLogSheet) { LogSheet().environmentObject(state) }
        .alert("INAV Servo Support Assistant", isPresented: Binding(get: { state.alertMessage != nil },
                                                          set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK", role: .cancel) { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }
}

struct MessageView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundColor(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .padding(40)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 56)).foregroundColor(.accentColor)
            Text("INAV Servo Support Assistant").font(.largeTitle.weight(.semibold))
            Text("Turn spare UART pads of an inav flight controller target into servo outputs. The helper checks each UART pin against the MCU's timer alternate-function table, shows the conflicts and edits target.c / target.h for you.")
                .multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 560)
            HStack(spacing: 16) {
                Button { state.chooseExistingSource() } label: {
                    Label("Open existing inav source…", systemImage: "folder").frame(minWidth: 220)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                Button { state.presentClone() } label: {
                    Label("Clone from GitHub…", systemImage: "arrow.down.circle").frame(minWidth: 180)
                }
                .controlSize(.large)
            }
        }
        .padding(40)
    }
}
