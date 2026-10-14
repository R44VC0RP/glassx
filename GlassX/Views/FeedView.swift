import os
import SwiftUI

/// A paginated feed backed by one of the client's timeline endpoints.
///
/// Feeds grow in both directions: `loadMore` follows the bottom cursor as you scroll down, and
/// `fetchNewer` follows the top cursor (the same request x.com makes when you pull to refresh)
/// to pick up posts published since the feed loaded.
@MainActor @Observable
final class FeedModel {
    static let log = Logger(subsystem: "com.ryanvogel.glassx", category: "feed")
    typealias Loader = @Sendable (XClient, String?) async throws -> FeedPage

    var items: [FeedItem] = []
    var isLoading = false
    var hasLoaded = false
    var error: String?
    /// Posts added above the reader while they were scrolled down; drives the "new posts" pill.
    var unseen: [FeedItem] = []
    /// Keyboard selection (J/K), shown with a blue accent bar.
    var selectedID: FeedItem.ID?
    /// Top visible post, restored when you come back to this tab.
    var anchorID: FeedItem.ID?
    /// Posts currently on screen, top to bottom.
    var visibleIDs: [FeedItem.ID] = []
    /// Bumped after every full reload so the view can jump back to the top.
    private(set) var reloadGeneration = 0
    /// Whether this feed checks for newer posts in the background.
    let autoRefresh: Bool
    private(set) var reachedEnd = false
    private var cursor: String?
    private var topCursor: String?
    private var loadedToken: UUID?
    private var isCheckingNewer = false
    private(set) var lastNewerCheck: Date?
    private let loader: Loader
    #if DEBUG
    /// `--simulate-new`: hold back the newest posts on load and "discover" them on the first check.
    private var debugHeldBack: [FeedItem] = []
    #endif

    init(autoRefresh: Bool = false, loader: @escaping Loader) {
        self.autoRefresh = autoRefresh
        self.loader = loader
    }

    func reset() {
        items = []
        unseen = []
        cursor = nil
        topCursor = nil
        hasLoaded = false
        reachedEnd = false
        loadedToken = nil
        error = nil
    }

    /// Starts a load owned by the model, so views being rebuilt or disappearing never cancel it.
    func loadIfNeeded(_ model: AppModel) {
        guard loadedToken != model.refreshToken, model.client != nil else { return }
        loadedToken = model.refreshToken
        loadTask?.cancel()
        loadTask = Task { await reload(model) }
    }

    func retry(_ model: AppModel) {
        loadTask?.cancel()
        loadTask = Task { await reload(model) }
    }

    private var loadTask: Task<Void, Never>?

    func reload(_ model: AppModel) async {
        guard let client = model.client else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await loader(client, nil)
            var loaded = page.items
            #if DEBUG
            if autoRefresh, CommandLine.arguments.contains("--simulate-new"), loaded.count > 8 {
                debugHeldBack = Array(loaded.prefix(5))
                loaded.removeFirst(5)
            }
            #endif
            Self.prefetchImages(for: loaded)
            selectedID = nil
            anchorID = nil
            withAnimation(.smooth) {
                items = loaded
                unseen = []
                hasLoaded = true
                reloadGeneration += 1
            }
            cursor = page.bottomCursor
            topCursor = page.topCursor
            lastNewerCheck = .now
            reachedEnd = page.bottomCursor == nil || page.items.isEmpty
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case XError.unauthorized = error { model.report(error) }
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Asks X for posts newer than the top of the feed. Returns only posts not already shown.
    func fetchNewer(_ model: AppModel) async -> [FeedItem] {
        guard autoRefresh, hasLoaded, !isLoading, !isCheckingNewer, let client = model.client else { return [] }
        lastNewerCheck = .now
        #if DEBUG
        if !debugHeldBack.isEmpty {
            defer { debugHeldBack = [] }
            return debugHeldBack
        }
        #endif
        guard let topCursor else { return [] }
        isCheckingNewer = true
        defer { isCheckingNewer = false }
        do {
            let page = try await loader(client, topCursor)
            if let newTop = page.topCursor { self.topCursor = newTop }
            let known = Set(items.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
            Self.log.notice("Checked for newer posts: \(fresh.count) new")
            Self.prefetchImages(for: fresh)
            return fresh
        } catch {
            Self.log.error("Newer-posts check failed: \(error.localizedDescription, privacy: .public)")
            if case XError.unauthorized = error { model.report(error) }
            return []
        }
    }

    /// Index from which reaching an item starts loading the next page (about a screen ahead).
    var prefetchThresholdID: FeedItem.ID? {
        guard !reachedEnd, items.count > 0 else { return nil }
        return items[max(0, items.count - 8)].id
    }

    private static func prefetchImages(for items: [FeedItem]) {
        var requests: [(URL, Int)] = []
        for item in items {
            guard case .tweet(let feedTweet) = item else { continue }
            let tweet = feedTweet.tweet
            if let avatar = tweet.author.avatarURL(forSize: 40) { requests.append((avatar, ImageSize.avatar)) }
            for media in tweet.media.prefix(4) { requests.append((media.previewURL, ImageSize.media)) }
            if let quoted = tweet.quoted.first {
                for media in quoted.media.prefix(4) { requests.append((media.previewURL, ImageSize.media)) }
            }
            if let card = tweet.card?.imageURL { requests.append((card, ImageSize.media)) }
        }
        ImagePipeline.shared.prefetch(requests)
    }

    func loadMore(_ model: AppModel) async {
        guard !isLoading, !reachedEnd, let cursor, let client = model.client else { return }
        isLoading = true
        defer { isLoading = false }
        let started = Date.now
        defer { Self.log.notice("Page \(self.items.count) items, loadMore took \(Int(Date.now.timeIntervalSince(started) * 1000))ms") }
        do {
            let page = try await loader(client, cursor)
            let known = Set(items.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
            Self.prefetchImages(for: fresh)
            items += fresh
            self.cursor = page.bottomCursor
            reachedEnd = page.bottomCursor == nil || fresh.isEmpty
        } catch {
            model.report(error)
        }
    }
}

struct FeedView<Header: View>: View {
    var feed: FeedModel
    var emptyTitle = "Nothing here yet"
    var emptySymbol = "text.bubble"
    @ViewBuilder var header: Header
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = ScrollPosition(idType: FeedItem.ID.self)
    @State private var isAtTop = true
    @FocusState private var focused: Bool

    private var pollInterval: Duration {
        #if DEBUG
        if CommandLine.arguments.contains("--simulate-new") { return .seconds(8) }
        #endif
        return .seconds(45)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(feed.items) { item in
                    VStack(spacing: 0) {
                        FeedItemView(item: item)
                            .overlay(alignment: .leading) {
                                if feed.selectedID == item.id {
                                    Capsule().fill(Color.xBlue).frame(width: 3).padding(.vertical, 10)
                                        .transition(.opacity)
                                }
                            }
                        if !item.connectsBelow { Hairline() }
                    }
                    .onAppear {
                        if item.id == feed.prefetchThresholdID { Task { await feed.loadMore(model) } }
                    }
                }
                footer
            }
            .scrollTargetLayout()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        // Anchoring on the top visible post keeps the reader in place when posts are added above.
        .scrollPosition($position, anchor: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 80
        } action: { _, atTop in
            isAtTop = atTop
            if atTop, !feed.unseen.isEmpty { withAnimation(.smooth) { feed.unseen = [] } }
        }
        .onScrollTargetVisibilityChange(idType: FeedItem.ID.self, threshold: 0.2) { ids in
            feed.visibleIDs = ids
            if let first = ids.first { feed.anchorID = first }
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .modifier(DebugAutoScroll(feed: feed, position: $position))
        .overlay(alignment: .top) {
            if !feed.unseen.isEmpty, !isAtTop {
                NewPostsPill(items: feed.unseen) { scrollToTop() }
                    .padding(.top, 10)
                    .onAppear { FeedModel.log.notice("New-posts pill shown (\(feed.unseen.count))") }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.bouncy(duration: 0.4), value: feed.unseen.isEmpty || isAtTop)
        .overlay {
            if feed.hasLoaded, feed.items.isEmpty, !feed.isLoading {
                if let error = feed.error {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { feed.retry(model) }.buttonStyle(.glass)
                    }
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
                }
            } else if !feed.hasLoaded {
                ProgressView().controlSize(.large)
            }
        }
        .onAppear {
            feed.loadIfNeeded(model)
            focused = true
            // Come back to the post you were reading when switching tabs.
            if let anchor = feed.anchorID, feed.items.contains(where: { $0.id == anchor }) {
                DispatchQueue.main.async { position.scrollTo(id: anchor, anchor: .top) }
            }
        }
        .onChange(of: model.refreshToken) { feed.loadIfNeeded(model) }
        .onChange(of: feed.reloadGeneration) { position.scrollTo(edge: .top) }
        .task(id: scenePhase) { await pollForNewer() }
    }

    /// While the window is on screen (focused or not), checks for newer posts on a timer, and once
    /// right away when it comes back after being hidden or minimized for a while.
    private func pollForNewer() async {
        guard feed.autoRefresh, scenePhase != .background else { return }
        if let last = feed.lastNewerCheck, Date.now.timeIntervalSince(last) > 20 { await insertNewer() }
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { return }
            await insertNewer()
        }
    }

    private func insertNewer() async {
        let fresh = await feed.fetchNewer(model)
        guard !fresh.isEmpty else { return }
        FeedModel.log.notice("Inserting \(fresh.count) newer posts (at top: \(isAtTop))")
        if isAtTop {
            withAnimation(.smooth(duration: 0.45)) {
                feed.items.insert(contentsOf: fresh, at: 0)
                position.scrollTo(edge: .top)
            }
        } else {
            // Insert above the reader without animation so the anchored post stays put.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                feed.unseen = fresh + feed.unseen
                feed.items.insert(contentsOf: fresh, at: 0)
            }
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case KeyEquivalent("j"): moveSelection(by: 1)
        case KeyEquivalent("k"): moveSelection(by: -1)
        case KeyEquivalent("."):
            scrollToTop()
        case .return, KeyEquivalent("o"):
            guard let item = selectedItem else { return .ignored }
            switch item {
            case .tweet(let tweet): model.open(.tweet(tweet.tweet))
            case .notification(let notification):
                if let tweet = notification.tweet { model.open(.tweet(tweet)) }
                else if let id = notification.tweetID { model.open(.tweetID(id)) }
            }
        default:
            guard let tweet = selectedTweet else { return .ignored }
            switch press.characters.lowercased() {
            case "l": model.toggleLike(tweet)
            case "r": model.compose = ComposeTarget(replyTo: tweet)
            case "t": model.toggleRepost(tweet)
            case "b": model.toggleBookmark(tweet)
            case "u": model.open(.user(tweet.author.screenName))
            default: return .ignored
            }
        }
        return .handled
    }

    private var selectedItem: FeedItem? {
        guard let id = feed.selectedID else { return nil }
        return feed.items.first { $0.id == id }
    }

    private var selectedTweet: XTweet? {
        switch selectedItem {
        case .tweet(let tweet): tweet.tweet
        case .notification(let notification): notification.tweet
        case nil: nil
        }
    }

    /// J/K: step through posts. Starts from the top visible post if the selection is off screen.
    private func moveSelection(by step: Int) {
        let ids = feed.items.map(\.id)
        guard !ids.isEmpty else { return }
        let next: Int
        if let current = feed.selectedID, feed.visibleIDs.contains(current), let index = ids.firstIndex(of: current) {
            next = min(max(index + step, 0), ids.count - 1)
        } else {
            let firstVisible = feed.visibleIDs.first.flatMap { ids.firstIndex(of: $0) } ?? 0
            next = step > 0 ? firstVisible : max(firstVisible - 1, 0)
        }
        withAnimation(.snappy(duration: 0.2)) { feed.selectedID = ids[next] }
        withAnimation(.smooth(duration: 0.25)) { position.scrollTo(id: ids[next], anchor: UnitPoint(x: 0.5, y: 0.08)) }
        if next >= ids.count - 6 { Task { await feed.loadMore(model) } }
    }

    private func scrollToTop() {
        withAnimation(.smooth(duration: 0.5)) { position.scrollTo(edge: .top) }
        withAnimation(.smooth) { feed.unseen = [] }
    }

    @ViewBuilder private var footer: some View {
        if feed.hasLoaded, !feed.items.isEmpty, !feed.reachedEnd {
            ProgressView()
                .padding(24)
                .frame(maxWidth: .infinity)
                .onAppear {
                    FeedModel.log.notice("Reached bottom spinner at \(feed.items.count) items (loading: \(feed.isLoading))")
                    Task { await feed.loadMore(model) }
                }
        } else {
            Color.clear.frame(height: 40)
        }
    }
}

/// X's blue "new posts" pill, as a tinted Liquid Glass capsule floating over the feed.
private struct NewPostsPill: View {
    var items: [FeedItem]
    var action: () -> Void

    private var authors: [XUser] {
        var seen = Set<String>()
        var result: [XUser] = []
        for item in items {
            let user: XUser? = switch item {
            case .tweet(let tweet): tweet.tweet.author
            case .notification(let notification): notification.users.first
            }
            if let user, seen.insert(user.id).inserted { result.append(user) }
            if result.count == 3 { break }
        }
        return result
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                if !authors.isEmpty {
                    AvatarStack(users: authors, size: 22).allowsHitTesting(false)
                }
                Text(items.count == 1 ? "1 new post" : "\(items.count) new posts")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.numericText(value: Double(items.count)))
            }
            .foregroundStyle(.white)
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.xBlue).interactive(), in: .capsule)
        .accessibilityLabel("Show \(items.count) new posts")
    }
}

extension FeedView where Header == EmptyView {
    init(feed: FeedModel, emptyTitle: String = "Nothing here yet", emptySymbol: String = "text.bubble") {
        self.init(feed: feed, emptyTitle: emptyTitle, emptySymbol: emptySymbol) { EmptyView() }
    }
}

extension FeedItem {
    var connectsBelow: Bool {
        if case .tweet(let tweet) = self { return tweet.connectsBelow }
        return false
    }
}

struct FeedItemView: View {
    var item: FeedItem
    var body: some View {
        switch item {
        case .tweet(let tweet): TweetRow(item: tweet)
        case .notification(let notification): NotificationRow(notification: notification)
        }
    }
}

/// Debug-only: `--autoscroll` walks the feed post by post (like steady reading), so pagination can
/// be measured without driving input; `--autoscroll-to N` stops after N posts.
private struct DebugAutoScroll: ViewModifier {
    var feed: FeedModel
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        #if DEBUG
        let args = CommandLine.arguments
        if args.contains("--autoscroll") || args.contains("--autoscroll-to") {
            let limit = args.firstIndex(of: "--autoscroll-to").flatMap { args[safe: $0 + 1] }.flatMap(Int.init) ?? .max
            content.task {
                try? await Task.sleep(for: .seconds(3))
                var index = 0
                while !Task.isCancelled, index < limit {
                    if index < feed.items.count {
                        withAnimation(.linear(duration: 0.3)) { position.scrollTo(id: feed.items[index].id, anchor: .top) }
                        index += 1
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
