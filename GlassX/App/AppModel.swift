import Observation
import SwiftUI

enum Section: String, CaseIterable, Identifiable, Hashable {
    case home, search, notifications, bookmarks, profile
    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Explore"
        case .notifications: "Notifications"
        case .bookmarks: "Bookmarks"
        case .profile: "Profile"
        }
    }

    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .notifications: "bell.fill"
        case .bookmarks: "bookmark.fill"
        case .profile: "person.crop.circle.fill"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .notifications: "bell"
        case .bookmarks: "bookmark"
        case .profile: "person.crop.circle"
        }
    }
}

enum Route: Hashable {
    case tweet(XTweet)
    case tweetID(String)
    case user(String)
    case search(String)
}

/// Local overrides for like/repost/bookmark so every view shows the same state immediately.
struct EngagementState: Hashable {
    var liked: Bool
    var reposted: Bool
    var bookmarked: Bool
    var likeCount: Int
    var repostCount: Int
    var bookmarkCount: Int
}

struct ComposeTarget: Identifiable {
    let id = UUID()
    var replyTo: XTweet?
}

@MainActor @Observable
final class AppModel {
    enum Phase { case launching, signedOut, signedIn }

    var phase: Phase = .launching
    var viewer: XUser?
    var section: Section = .home
    var paths: [Section: [Route]] = [:]
    var compose: ComposeTarget?
    var banner: String?
    var refreshToken = UUID()
    private(set) var engagement: [String: EngagementState] = [:]
    private(set) var client: XClient?

    let forYouFeed = FeedModel(autoRefresh: true) { client, cursor in try await client.homeTimeline(following: false, cursor: cursor) }
    let followingFeed = FeedModel(autoRefresh: true) { client, cursor in try await client.homeTimeline(following: true, cursor: cursor) }
    let notificationsFeed = FeedModel(autoRefresh: true) { client, cursor in try await client.notifications(type: "All", cursor: cursor) }
    let priorityNotificationsFeed = FeedModel { client, cursor in try await client.notifications(type: "Priority", cursor: cursor) }
    let mentionsFeed = FeedModel { client, cursor in try await client.notifications(type: "Mentions", cursor: cursor) }
    let bookmarksFeed = FeedModel { client, cursor in try await client.bookmarks(cursor: cursor) }

    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--guest-preview") {
            let screenName = CommandLine.arguments[safe: index + 1] ?? "opencode"
            startGuestPreview(screenName: screenName)
            return
        }
        // Screenshot helpers: `--section notifications`, `--open-tweet <id>`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--section"), let raw = args[safe: i + 1], let section = Section(rawValue: raw) {
            self.section = section
        }
        if let i = args.firstIndex(of: "--search"), let query = args[safe: i + 1] {
            section = .search
            paths[.search] = [.search(query)]
        }
        if args.contains("--compose") { compose = ComposeTarget() }
        // `--simulate-away N`: pretend the user left 10s after launch and came back N seconds later.
        if let i = args.firstIndex(of: "--simulate-away"), let seconds = args[safe: i + 1].flatMap(Double.init) {
            freshFeedAfter = min(freshFeedAfter, seconds)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self.appDidResignActive()
                try? await Task.sleep(for: .seconds(seconds))
                self.appDidBecomeActive()
            }
        }
        // `--bounce-section S`: after 9s switch to section S, then back after 3s.
        if let i = args.firstIndex(of: "--bounce-section"), let raw = args[safe: i + 1], let other = Section(rawValue: raw) {
            let original = section
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                self.section = other
                try? await Task.sleep(for: .seconds(3))
                self.section = original
            }
        }
        if let i = args.firstIndex(of: "--open-user"), let name = args[safe: i + 1] {
            paths[section, default: []].append(.user(name))
        }
        if let i = args.firstIndex(of: "--open-tweet"), let id = args[safe: i + 1] {
            paths[section, default: []].append(.tweetID(id))
        }
        #endif
        if let cookies = Keychain.loadCookies(), cookies["auth_token"] != nil {
            start(with: cookies)
        } else {
            phase = .signedOut
        }
    }

    func path(for section: Section) -> Binding<[Route]> {
        Binding(get: { self.paths[section] ?? [] }, set: { self.paths[section] = $0 })
    }

    func open(_ route: Route) {
        paths[section, default: []].append(route)
    }

    // MARK: Freshness

    /// After this long away from the app, coming back reloads every feed from the top.
    var freshFeedAfter: TimeInterval = 60
    private var inactiveSince: Date?

    func appDidResignActive() {
        inactiveSince = .now
    }

    func appDidBecomeActive() {
        guard let since = inactiveSince else { return }
        inactiveSince = nil
        let away = Date.now.timeIntervalSince(since)
        guard phase == .signedIn, away >= freshFeedAfter else { return }
        FeedModel.log.notice("Back after \(Int(away))s away: loading a fresh feed")
        refreshToken = UUID()
    }

    // MARK: Session

    func signIn(with cookies: [String: String]) {
        Keychain.saveCookies(cookies)
        start(with: cookies)
    }

    private func start(with cookies: [String: String]) {
        let client = XClient(cookies: cookies) { updated in Keychain.saveCookies(updated) }
        self.client = client
        refreshToken = UUID()
        phase = .signedIn
        Task { await loadViewer() }
    }

    #if DEBUG
    /// Logged-out preview of public data, for checking layout without an account.
    private func startGuestPreview(screenName: String) {
        let client = XClient(cookies: [:]) { _ in }
        self.client = client
        section = .profile
        phase = .signedIn
        Task {
            do {
                try await client.activateGuestSession()
                viewer = try await client.user(screenName: screenName)
            } catch {
                banner = error.localizedDescription
            }
        }
    }
    #endif

    func loadViewer() async {
        guard let client else { return }
        do {
            viewer = try await client.viewer()
        } catch XError.unauthorized {
            signOut(message: XError.unauthorized.errorDescription)
        } catch {
            banner = error.localizedDescription
        }
    }

    func signOut(message: String? = nil) {
        Keychain.deleteCookies()
        client = nil
        viewer = nil
        paths = [:]
        engagement = [:]
        for feed in [forYouFeed, followingFeed, notificationsFeed, priorityNotificationsFeed, mentionsFeed, bookmarksFeed] { feed.reset() }
        section = .home
        phase = .signedOut
        banner = message
    }

    func report(_ error: Error) {
        if case XError.unauthorized = error { signOut(message: error.localizedDescription); return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        banner = error.localizedDescription
    }

    // MARK: Engagement

    func state(for tweet: XTweet) -> EngagementState {
        engagement[tweet.id] ?? EngagementState(
            liked: tweet.isLiked, reposted: tweet.isRetweeted, bookmarked: tweet.isBookmarked,
            likeCount: tweet.likeCount, repostCount: tweet.retweetCount, bookmarkCount: tweet.bookmarkCount
        )
    }

    func toggleLike(_ tweet: XTweet) {
        var state = state(for: tweet)
        state.liked.toggle()
        state.likeCount += state.liked ? 1 : -1
        mutate(tweet, to: state) { client in try await client.setLiked(state.liked, tweetID: tweet.id) }
    }

    func toggleRepost(_ tweet: XTweet) {
        var state = state(for: tweet)
        state.reposted.toggle()
        state.repostCount += state.reposted ? 1 : -1
        mutate(tweet, to: state) { client in try await client.setReposted(state.reposted, tweetID: tweet.id) }
    }

    func toggleBookmark(_ tweet: XTweet) {
        var state = state(for: tweet)
        state.bookmarked.toggle()
        state.bookmarkCount += state.bookmarked ? 1 : -1
        mutate(tweet, to: state) { client in try await client.setBookmarked(state.bookmarked, tweetID: tweet.id) }
    }

    private func mutate(_ tweet: XTweet, to newState: EngagementState, action: @escaping (XClient) async throws -> Void) {
        guard let client else { return }
        let previous = state(for: tweet)
        withAnimation(.snappy) { engagement[tweet.id] = newState }
        Task {
            do { try await action(client) } catch {
                withAnimation(.snappy) { engagement[tweet.id] = previous }
                report(error)
            }
        }
    }

    // MARK: Posting

    func post(text: String, replyTo: XTweet?) async -> Bool {
        guard let client else { return false }
        do {
            try await client.post(text: text, replyTo: replyTo?.id)
            refreshToken = UUID()
            return true
        } catch {
            report(error)
            return false
        }
    }
}
