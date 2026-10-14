import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching: Color.clear
            case .signedOut: LoginView()
            case .signedIn: MainView()
            }
        }
        .tint(.xBlue)
        .preferredColorScheme(.dark)
        .containerBackground(Color.black, for: .window)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "glassx" else { return .systemAction }
            switch url.host() {
            case "user": model.open(.user(url.lastPathComponent))
            case "search":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                model.open(.search(query))
            default: break
            }
            return .handled
        })
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // System tab bar in the toolbar: Apple's recommended top-level navigation without a sidebar.
        TabView(selection: $model.section) {
            ForEach(Section.allCases) { section in
                Tab(section.title, systemImage: section.symbol, value: section) {
                    NavigationStack(path: model.path(for: section)) {
                        root(for: section)
                            .navigationDestination(for: Route.self) { RouteView(route: $0).toolbar { sharedToolbar } }
                            .toolbar { sharedToolbar }
                    }
                    .background(Color.black)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .overlay(alignment: .top) {
            if let banner = model.banner {
                GlassBanner(text: banner) { withAnimation { model.banner = nil } }
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner) {
                        try? await Task.sleep(for: .seconds(6))
                        withAnimation { model.banner = nil }
                    }
            }
        }
        .animation(.smooth, value: model.banner)
        .sheet(item: $model.compose) { target in
            NavigationStack { ComposeView(target: target) }
        }
    }

    @ViewBuilder private func root(for section: Section) -> some View {
        switch section {
        case .home: HomeView()
        case .search: ExploreView()
        case .notifications: NotificationsView()
        case .bookmarks: BookmarksView()
        case .profile:
            if let viewer = model.viewer { ProfileView(screenName: viewer.screenName) } else { ProgressView() }
        }
    }

    @ToolbarContentBuilder private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshToken = UUID() }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("New Post", systemImage: "square.and.pencil") { model.compose = ComposeTarget() }
                .buttonStyle(.glassProminent)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { AccountMenu() }
    }
}

/// The signed-in account, as a toolbar menu.
private struct AccountMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let viewer = model.viewer {
                SwiftUI.Section("\(viewer.name) · @\(viewer.screenName)") {
                    Button("View Profile", systemImage: "person") { model.section = .profile }
                    Button("Open on x.com", systemImage: "safari") {
                        NSWorkspace.shared.open(URL(string: "https://x.com/\(viewer.screenName)")!)
                    }
                }
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.signOut() }
        } label: {
            Avatar(user: model.viewer, size: 24)
        }
        .menuIndicator(.hidden)
        .help("Account")
        .accessibilityLabel("Account")
    }
}
