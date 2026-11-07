import SwiftUI
import AppKit

@main
struct INAVServoSupportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("INAV Servo Support") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open inav Source…") { state.chooseExistingSource() }
                    .keyboardShortcut("o")
                Button("Clone inav from GitHub…") { state.presentClone() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Choose Source / Start Screen…") { state.presentStartScreen() }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                Button("Reload Targets") { state.reloadTargets() }
                    .keyboardShortcut("r")
                    .disabled(state.inavRoot == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from a plain SwiftPM binary so the window gets focus and a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
