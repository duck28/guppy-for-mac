import SwiftUI

@main
struct GuppyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Guppy", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 820, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            GuppyCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = GuppyModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Guppy is white and orange, also in Dark Mode.
        NSApp.appearance = NSAppearance(named: .aqua)
        model.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.confirmQuit() ? .terminateNow : .terminateCancel
    }
}

private struct GuppyCommands: Commands {
    @ObservedObject var model: GuppyModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Paste Link and Look Up", action: model.pasteAndFetch)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.canDownload)
            Button("Download", action: model.download)
                .keyboardShortcut("d")
                .disabled(model.info == nil || !model.canDownload)
            Divider()
            Button("Convert Files…", action: model.chooseFilesToConvert)
                .keyboardShortcut("o")
                .disabled(model.tools?.ffmpeg == nil)
            Divider()
            Button("Show Downloads Folder", action: model.openFolder)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Clear Finished", action: model.clearFinished)
                .keyboardShortcut("k")
                .disabled(!model.hasFinishedJobs)
        }
    }
}
