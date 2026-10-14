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
        NavigationStack(path: model.path(for: model.section)) {
            root(for: model.section)
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .id(model.section)
        .background(Color.black)
        .toolbar {
            ToolbarItem(placement: .principal) { SectionSwitcher() }
                .sharedBackgroundVisibility(.hidden)
            sharedToolbar
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// Top-level navigation: one Liquid Glass capsule with icon + title segments and a sliding selection.
/// Collapses to icons only when the window is narrow.
private struct SectionSwitcher: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments(showTitles: true)
            segments(showTitles: false)
        }
    }

    private func segments(showTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Section.allCases) { section in
                SectionSegment(section: section, isSelected: model.section == section, showTitle: showTitles, namespace: selection) {
                    withAnimation(.bouncy(duration: 0.35)) { model.section = section }
                }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct SectionSegment: View {
    var section: Section
    var isSelected: Bool
    var showTitle: Bool
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? section.selectedSymbol : section.symbol)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
                if showTitle {
                    Text(section.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? Color.white : (hovering ? Color.white.opacity(0.9) : Color.xGray))
            .padding(.horizontal, showTitle ? 14 : 12)
            .frame(height: 30)
            .background {
                if isSelected {
                    Capsule().fill(.white.opacity(0.14))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    Capsule().fill(.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
