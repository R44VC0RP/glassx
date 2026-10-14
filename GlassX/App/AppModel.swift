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
    var quote: XTweet? = nil
    /// Debug demo: types this text in and posts it.
    var demoText: String? = nil
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
    /// Symbol for `banner`; warning by default, set by `showNotice` for good news.
    var bannerSymbol = "exclamationmark.triangle.fill"
    let scheduler = PostScheduler()
    /// While a queued post's ticket is flying to the toolbar, its count isn't shown yet.
    var holdQueueBadge = false
    /// Where the toolbar queue button is, in window coordinates (the queue animation's target).
    var queueButtonFrame: CGRect = .zero
    var visibleQueueCount: Int { max(0, scheduler.queue.count - (holdQueueBadge ? 1 : 0)) }
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
        if args.contains("--dry-run-posts") { XClient.dryRun = true }
        // `--test-upload`: upload a generated image for real (no post) and log the media ID.
        if args.contains("--test-upload") {
            XClient.dryRun = true
            XClient.dryRunAllowsUpload = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard let client = self.client else { return }
                let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                    NSColor.systemBlue.setFill(); rect.fill(); return true
                }
                let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                do {
                    let id = try await client.uploadMedia(png, mimeType: "image/png", category: .image)
                    FeedModel.log.notice("TEST UPLOAD OK media_id=\(id, privacy: .public)")
                } catch {
                    FeedModel.log.error("TEST UPLOAD FAILED \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if args.contains("--clear-queue") { scheduler.clearAll() }
        // `--demo-composer`: dry run that writes and sends one post, then writes one that queues.
        if args.contains("--demo-composer") {
            XClient.dryRun = true
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "pacing.enabled")
            defaults.set(60, forKey: "pacing.gapMinutes")
            defaults.set(0, forKey: "pacing.startHour")
            defaults.set(0, forKey: "pacing.endHour")
            defaults.set(0.0, forKey: "pacing.lastSentAt")
            scheduler.clearAll()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self.compose = ComposeTarget(demoText: "the new composer just shipped and it feels so good ✨")
                while self.compose != nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1.4))
                self.compose = ComposeTarget(demoText: "this one waits its turn ⏳")
            }
        }
        // `--demo-thread`: dry run that types a 3-post thread and sends it.
        if args.contains("--demo-thread") {
            XClient.dryRun = true
            UserDefaults.standard.set(false, forKey: "pacing.enabled")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self.compose = ComposeTarget(demoText: "a thread about glassx 🧵\n---\nit's a native mac x client built on liquid glass\n---\nand threads now post in order, each replying to the last")
            }
        }
        // `--demo-quote`: dry run that quotes the first post in the feed.
        if args.contains("--demo-quote") {
            XClient.dryRun = true
            UserDefaults.standard.set(false, forKey: "pacing.enabled")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                let feed = UserDefaults.standard.bool(forKey: "homeShowsFollowing") ? self.followingFeed : self.forYouFeed
                guard let first = feed.items.lazy.compactMap({ item -> XTweet? in
                    if case .tweet(let tweet) = item { return tweet.tweet } else { return nil }
                }).first else { return }
                self.compose = ComposeTarget(quote: first, demoText: "this is a great point")
            }
        }
        // `--test-mute <screen_name>`: real, reversible: mute then immediately unmute (mutes are private).
        if let i = args.firstIndex(of: "--test-mute"), let name = args[safe: i + 1] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard let client = self.client else { return }
                do {
                    let user = try await client.user(screenName: name)
                    try await client.setMuted(true, userID: user.id)
                    let muted = try await client.user(screenName: name).isMuting
                    try await client.setMuted(false, userID: user.id)
                    let after = try await client.user(screenName: name).isMuting
                    FeedModel.log.notice("TEST MUTE @\(name, privacy: .public): muted=\(muted) after unmute=\(after)")
                } catch {
                    FeedModel.log.error("TEST MUTE failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if args.contains("--reset-pacing") {
            for key in ["pacing.enabled", "pacing.gapMinutes", "pacing.startHour", "pacing.endHour", "pacing.lastSentAt"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        // `--test-pacing`: dry-run three posts back to back with pacing on (1 minute apart).
        if args.contains("--test-pacing") {
            XClient.dryRun = true
            UserDefaults.standard.set(true, forKey: "pacing.enabled")
            UserDefaults.standard.set(1, forKey: "pacing.gapMinutes")
            UserDefaults.standard.set(0, forKey: "pacing.startHour")
            UserDefaults.standard.set(0, forKey: "pacing.endHour")
            UserDefaults.standard.set(0.0, forKey: "pacing.lastSentAt")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                for n in 1...3 {
                    let outcome = await self.post(text: "pacing test \(n)", replyTo: nil)
                    FeedModel.log.notice("TEST PACING post \(n): \(String(describing: outcome), privacy: .public)")
                }
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
        scheduler.start(model: self)
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
        bannerSymbol = "exclamationmark.triangle.fill"
        banner = error.localizedDescription
    }

    func showNotice(_ message: String, symbol: String = "checkmark.circle.fill") {
        bannerSymbol = symbol
        banner = message
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

    enum PostOutcome { case sent, queued(Date), failed }

    /// Sends a single post (the thread reply bar uses this).
    func post(text: String, replyTo: XTweet?, attachments: [PostAttachment] = [], announce: Bool = true,
              progress: (@Sendable (Double) -> Void)? = nil) async -> PostOutcome {
        await post(PostDraft(parts: [.init(text: text, attachments: attachments)], replyTo: replyTo),
                   announce: announce, progress: progress)
    }

    /// Sends a post or thread now, or queues it when "Space out my posts" says it's too soon.
    /// A thread is sent part by part, each replying to the one before.
    func post(_ draft: PostDraft, announce: Bool = true,
              progress: (@Sendable (Double) -> Void)? = nil, partSent: ((Int) -> Void)? = nil) async -> PostOutcome {
        guard let client else { return .failed }
        if scheduler.wouldQueue(isReply: draft.replyTo != nil) {
            do {
                if !announce { holdQueueBadge = true }
                let queued = try scheduler.enqueue(draft)
                if announce { showNotice("Scheduled for \(queued.sendAt.formatted(date: Calendar.current.isDateInToday(queued.sendAt) ? .omitted : .abbreviated, time: .shortened))",
                           symbol: "clock.fill") }
                return .queued(queued.sendAt)
            } catch {
                report(error)
                return .failed
            }
        }
        do {
            try await Self.send(draft, with: client, progress: progress) { index, _ in partSent?(index) }
            scheduler.recordSent()
            return .sent
        } catch {
            report(error)
            return .failed
        }
    }

    /// Uploads each part's media and posts the parts in order, chaining replies. Shared with the queue.
    /// `resumeAfter`: parts already posted (index of the last one and its ID), so a retried thread continues.
    static func send(_ draft: PostDraft, with client: XClient, progress: (@Sendable (Double) -> Void)? = nil,
                     resumeAfter: (index: Int, id: String)? = nil,
                     partSent: @escaping @MainActor (Int, String) -> Void = { _, _ in }) async throws {
        var previousID = resumeAfter?.id ?? draft.replyTo?.id ?? draft.replyToID
        let totalMedia = Double(max(draft.parts.reduce(0) { $0 + $1.attachments.count }, 1))
        var uploaded = 0.0
        for (index, part) in draft.parts.enumerated() {
            if let resumeAfter, index <= resumeAfter.index { continue }
            var mediaIDs: [String] = []
            for attachment in part.attachments {
                let base = uploaded
                mediaIDs.append(try await client.uploadMedia(attachment.data, mimeType: attachment.mimeType, category: attachment.category) { value in
                    progress?((base + value) / totalMedia)
                })
                uploaded += 1
            }
            previousID = try await client.post(text: part.text, replyTo: previousID, mediaIDs: mediaIDs,
                                               quoteURL: index == 0 ? draft.quote?.url ?? draft.quoteURL : nil)
            if let previousID { await partSent(index, previousID) }
        }
    }

    // MARK: Your posts and accounts

    /// A post waiting for the "Delete post?" confirmation.
    var confirmDelete: XTweet?

    /// Renders the post as a dark card image and puts it on the clipboard.
    func copyAsImage(_ tweet: XTweet) {
        let renderer = ImageRenderer(content: PostSnapshot(tweet: tweet).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage else { report(XError.api("Couldn't render the post.")); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showNotice("Copied post as image", symbol: "photo.fill")
    }

    /// Posts deleted in this session, hidden from every feed immediately.
    private(set) var deletedTweetIDs: Set<String> = []

    func delete(_ tweet: XTweet) {
        guard let client else { return }
        withAnimation(.smooth) { _ = deletedTweetIDs.insert(tweet.id) }
        Task {
            do {
                try await client.deleteTweet(id: tweet.id)
                showNotice("Post deleted", symbol: "trash.fill")
            } catch {
                withAnimation(.smooth) { _ = deletedTweetIDs.remove(tweet.id) }
                report(error)
            }
        }
    }

    func isDeleted(_ item: FeedItem) -> Bool {
        guard !deletedTweetIDs.isEmpty, case .tweet(let tweet) = item else { return false }
        return deletedTweetIDs.contains(tweet.tweet.id)
    }

    func isPinned(_ tweet: XTweet) -> Bool { viewer?.pinnedTweetID == tweet.id }

    func togglePin(_ tweet: XTweet) {
        guard let client else { return }
        let pin = !isPinned(tweet)
        let previous = viewer?.pinnedTweetID
        viewer?.pinnedTweetID = pin ? tweet.id : nil
        Task {
            do {
                try await client.setPinned(pin, tweetID: tweet.id)
                showNotice(pin ? "Pinned to your profile" : "Unpinned from your profile", symbol: "pin.fill")
                profileRevision += 1
            } catch {
                viewer?.pinnedTweetID = previous
                report(error)
            }
        }
    }

    /// Bumped when your own profile changes, so it reloads.
    var profileRevision = 0
    /// Relationship changes made here, by user ID, applied over what X returned.
    private(set) var relationships: [String: Relationship] = [:]

    struct Relationship: Equatable { var following: Bool; var muting: Bool; var blocking: Bool }

    func relationship(for user: XUser) -> Relationship {
        relationships[user.id] ?? Relationship(following: user.isFollowing, muting: user.isMuting, blocking: user.isBlocking)
    }

    func setFollowing(_ follow: Bool, _ user: XUser) {
        updateRelationship(user, { $0.following = follow; if follow { $0.blocking = false } }) { try await $0.setFollowing(follow, userID: user.id) }
    }

    func setMuted(_ mute: Bool, _ user: XUser) {
        updateRelationship(user, { $0.muting = mute }, notice: mute ? "Muted @\(user.screenName)" : "Unmuted @\(user.screenName)") {
            try await $0.setMuted(mute, userID: user.id)
        }
    }

    func setBlocked(_ block: Bool, _ user: XUser) {
        updateRelationship(user, { $0.blocking = block; if block { $0.following = false } },
                           notice: block ? "Blocked @\(user.screenName)" : "Unblocked @\(user.screenName)") {
            try await $0.setBlocked(block, userID: user.id)
        }
    }

    private func updateRelationship(_ user: XUser, _ change: (inout Relationship) -> Void, notice: String? = nil,
                                    action: @escaping (XClient) async throws -> Void) {
        guard let client else { return }
        let previous = relationship(for: user)
        var next = previous
        change(&next)
        withAnimation(.snappy) { relationships[user.id] = next }
        Task {
            do {
                try await action(client)
                if let notice { showNotice(notice, symbol: "checkmark.circle.fill") }
            } catch {
                withAnimation(.snappy) { relationships[user.id] = previous }
                report(error)
            }
        }
    }
}

/// A post or a thread of posts, optionally replying to or quoting another post.
struct PostDraft {
    struct Part {
        var text: String
        var attachments: [PostAttachment] = []
    }

    var parts: [Part]
    var replyTo: XTweet? = nil
    var quote: XTweet? = nil
    /// Used when restoring a queued draft (the original posts aren't stored).
    var replyToID: String? = nil
    var quoteURL: URL? = nil
}
