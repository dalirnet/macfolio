import SwiftUI

@main
struct MacfolioApp: App {
    @State private var setupStep: SetupStep = .checking
    @StateObject private var projects = ProjectStore.shared

    enum SetupStep {
        case checking
        case access
        case ready
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch setupStep {
                case .checking:
                    Color.clear
                case .access:
                    AccessView { setupStep = .ready }
                case .ready:
                    MainView()
                }
            }
            .frame(minWidth: AppWindow.width, minHeight: AppWindow.height)
            .tint(Theme.primary)
            .environment(\.font, Theme.ui(13))
            .onAppear(perform: checkAccess)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    NotificationCenter.default.post(name: .newProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(setupStep != .ready)
            }

            CommandGroup(replacing: .appInfo) {
                Button("About Macfolio") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
                }
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Macfolio") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    /// If Claude Code is available, go straight to the studio; else AccessView.
    private func checkAccess() {
        guard setupStep == .checking else { return }
        Task.detached {
            let available = ClaudeService.shared.isAvailable()
            await MainActor.run {
                setupStep = available ? .ready : .access
            }
        }
    }
}

extension Notification.Name {
    static let newProject = Notification.Name("newProject")
}
