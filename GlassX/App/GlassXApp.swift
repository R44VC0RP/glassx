import SwiftUI

@main
struct GlassXApp: App {
    @State private var model = AppModel()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 96 << 20, diskCapacity: 768 << 20)
    }

    var body: some Scene {
        WindowGroup("GlassX", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 520, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Post") { model.compose = ComposeTarget() }
                    .keyboardShortcut("n")
                    .disabled(model.phase != .signedIn)
            }
            CommandMenu("Go") {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        .disabled(model.phase != .signedIn)
                }
                Divider()
                Button("For You") { UserDefaults.standard.set(false, forKey: "homeShowsFollowing"); model.section = .home }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(model.phase != .signedIn)
                Button("Following") { UserDefaults.standard.set(true, forKey: "homeShowsFollowing"); model.section = .home }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(model.phase != .signedIn)
                Divider()
                Button("Back") {
                    if !(model.paths[model.section] ?? []).isEmpty { model.paths[model.section]?.removeLast() }
                }
                .keyboardShortcut("[")
                Button("Refresh") { model.refreshToken = UUID() }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .signedIn)
            }
            CommandGroup(replacing: .appTermination) {
                Button("Sign Out") { model.signOut() }
                    .disabled(model.phase != .signedIn)
                Divider()
                Button("Quit GlassX") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }

        WindowGroup("Media", for: MediaGallery.self) { $gallery in
            MediaViewer(gallery: $gallery)
                .tint(.xBlue)
        }
        .defaultSize(width: 1000, height: 760)
        .windowStyle(.hiddenTitleBar)
    }
}
