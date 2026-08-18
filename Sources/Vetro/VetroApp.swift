import AppKit
import GhosttyKit
import SwiftUI

@MainActor
final class VetroApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var vmStore: VMStore?
    private var isStoppingVMs = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vmStore else { return .terminateNow }
        guard !isStoppingVMs else { return .terminateLater }

        isStoppingVMs = true
        Task {
            let stopped = await vmStore.stopAll()
            isStoppingVMs = false
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

struct VetroApp: App {
    @NSApplicationDelegateAdaptor(VetroApplicationDelegate.self) private var appDelegate
    @State private var store = ProjectStore()
    @State private var sessions = SessionManager()
    @State private var settings = AppSettings()
    @State private var vms = VMStore()
    @State private var ui = UIState()

    var body: some Scene {
        Window("Vetro", id: "main") {
            ContentView()
                .environment(store)
                .environment(sessions)
                .environment(settings)
                .environment(vms)
                .environment(ui)
                .preferredColorScheme(settings.appearance == .light ? .light : .dark)
                .onAppear {
                    appDelegate.vmStore = vms
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    newChatInCurrentEnvironment()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Chat in Current Project") {
                    newChatInCurrentEnvironment()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Chat") {
                    if let id = sessions.selectedSessionID { sessions.closeSession(id) }
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Split Right") { splitSelected(GHOSTTY_SPLIT_DIRECTION_RIGHT) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { splitSelected(GHOSTTY_SPLIT_DIRECTION_DOWN) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Split Left") { splitSelected(GHOSTTY_SPLIT_DIRECTION_LEFT) }
                Button("Split Up") { splitSelected(GHOSTTY_SPLIT_DIRECTION_UP) }

                Button("Search Chats") {
                    ui.view = .app
                    ui.searchFieldFocused = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Toggle Sidebar") {
                    settings.sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    ui.view = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func splitSelected(_ direction: ghostty_action_split_direction_e) {
        if let id = sessions.selectedSessionID {
            sessions.splitFocused(in: id, direction: direction)
        }
    }

    private func newChatInCurrentEnvironment() {
        if let target = sessions.selectedTarget {
            sessions.newSessionRequest?(target)
            return
        }
        guard let project = store.projects.first else { return }
        Task { await sessions.startSession(in: project) }
    }
}
