import SwiftUI

#if os(iOS)

    /// iPad: straight into the studio — there's no Claude co-author to check for.
    @main
    struct MacfolioApp: App {
        var body: some Scene {
            WindowGroup {
                TouchMainView()
            }
        }
    }

#else

    @main
    struct MacfolioApp: App {
        var body: some Scene {
            WindowGroup {
                MainView()
                    .frame(minWidth: AppWindow.width, minHeight: AppWindow.height)
                    .environment(\.font, Theme.ui(13))
            }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Project") {
                        NotificationCenter.default.post(name: .newProject, object: nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                }

                CommandGroup(after: .textEditing) {
                    Button("Find") {
                        NotificationCenter.default.post(name: .openSearch, object: nil)
                    }
                    .keyboardShortcut("f", modifiers: .command)
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
    }

    extension Notification.Name {
        static let newProject = Notification.Name("newProject")
        static let openSearch = Notification.Name("openSearch")
    }

#endif
