import SwiftUI
import AppKit

@main
struct INAVServoSupportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("INAV Servo Support Assistant") {
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
        // Set the Dock icon explicitly so it shows even when the system icon cache is stale.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
