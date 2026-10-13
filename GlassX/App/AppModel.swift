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

    let forYouFeed = FeedModel { client, cursor in try await client.homeTimeline(following: false, cursor: cursor) }
    let followingFeed = FeedModel { client, cursor in try await client.homeTimeline(following: true, cursor: cursor) }
    let notificationsFeed = FeedModel { client, cursor in try await client.notifications(cursor: cursor) }
    let bookmarksFeed = FeedModel { client, cursor in try await client.bookmarks(cursor: cursor) }

    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--guest-preview") {
            let screenName = CommandLine.arguments[safe: index + 1] ?? "opencode"
            startGuestPreview(screenName: screenName)
            return
        }
        #endif
        if let cookies = Keychain.loadCookies(), cookies["auth_token"] != nil {
            start(with: cookies)
        } else {
            phase = .signedOut
        }
    }

    var path: Binding<[Route]> {
        Binding(get: { self.paths[self.section] ?? [] }, set: { self.paths[self.section] = $0 })
    }

    func open(_ route: Route) {
        paths[section, default: []].append(route)
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
        for feed in [forYouFeed, followingFeed, notificationsFeed, bookmarksFeed] { feed.reset() }
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
