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
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            NavigationStack(path: model.path) {
                sectionRoot
                    .navigationDestination(for: Route.self) { RouteView(route: $0).toolbar { sharedToolbar } }
                    .toolbar { sharedToolbar }
            }
            .id(model.section)
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                GlassBanner(text: banner) { withAnimation { model.banner = nil } }
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

    @ViewBuilder private var sectionRoot: some View {
        switch model.section {
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
                .keyboardShortcut("r")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("New Post", systemImage: "square.and.pencil") { model.compose = ComposeTarget() }
                .buttonStyle(.glassProminent)
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            ForEach(Section.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    model.compose = ComposeTarget()
                } label: {
                    Label("Post", systemImage: "square.and.pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                AccountRow()
            }
            .padding(12)
        }
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let viewer = model.viewer {
                Button("View Profile", systemImage: "person") { model.section = .profile }
                Button("Open on x.com", systemImage: "safari") {
                    NSWorkspace.shared.open(URL(string: "https://x.com/\(viewer.screenName)")!)
                }
                Divider()
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.signOut() }
        } label: {
            HStack(spacing: 10) {
                Avatar(user: model.viewer, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.viewer?.name ?? "Loading…").font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.viewer.map { "@\($0.screenName)" } ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }
}
