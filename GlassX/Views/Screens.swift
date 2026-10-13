import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("homeShowsFollowing") private var following = false

    var body: some View {
        FeedView(feed: following ? model.followingFeed : model.forYouFeed, emptyTitle: "Your timeline is empty", emptySymbol: "house")
            .id(following)
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Timeline", selection: $following) {
                        Text("For You").tag(false)
                        Text("Following").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }
    }
}

// MARK: - Thread

struct TweetDetailView: View {
    var tweetID: String
    var initial: XTweet?
    @Environment(AppModel.self) private var model
    @State private var feed: FeedModel
    @State private var reply = ""
    @State private var isPosting = false
    @FocusState private var replyFocused: Bool

    init(tweetID: String, initial: XTweet? = nil) {
        self.tweetID = tweetID
        self.initial = initial
        _feed = State(initialValue: FeedModel { client, cursor in try await client.tweetDetail(id: tweetID, cursor: cursor) })
    }

    var body: some View {
        let parts = split()
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(parts.ancestors) { item in
                    TweetRow(item: item)
                }
                if let focal = parts.focal ?? initial {
                    FocalTweet(tweet: focal, connectsAbove: !parts.ancestors.isEmpty)
                } else if !feed.hasLoaded {
                    ProgressView().padding(40)
                }
                ForEach(parts.replies) { item in
                    FeedItemView(item: item)
                    if !item.connectsBelow { Divider() }
                }
                if feed.hasLoaded, !feed.reachedEnd, !parts.replies.isEmpty {
                    ProgressView().padding(24).onAppear { Task { await feed.loadMore(model) } }
                }
                if let error = feed.error {
                    Text(error).font(.callout).foregroundStyle(.secondary).padding(24)
                }
                Color.clear.frame(height: 80)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom) { replyBar(to: parts.focal ?? initial) }
        .navigationTitle("Post")
        .task(id: model.refreshToken) { await feed.loadIfNeeded(model) }
    }

    private func split() -> (ancestors: [FeedTweet], focal: XTweet?, replies: [FeedItem]) {
        var ancestors: [FeedTweet] = []
        var replies: [FeedItem] = []
        var focal: XTweet?
        for item in feed.items {
            guard case .tweet(let tweet) = item else { continue }
            if tweet.tweet.id == tweetID, tweet.repostedBy == nil, focal == nil { focal = tweet.tweet; continue }
            if focal == nil {
                var connected = tweet
                connected.connectsBelow = true
                ancestors.append(connected)
            } else {
                replies.append(item)
            }
        }
        if focal == nil { return ([], nil, feed.items) }
        return (ancestors, focal, replies)
    }

    @ViewBuilder private func replyBar(to tweet: XTweet?) -> some View {
        if let tweet {
            HStack(spacing: 10) {
                Avatar(user: model.viewer, size: 28)
                TextField("Post your reply", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($replyFocused)
                    .onSubmit { send(to: tweet) }
                Button {
                    send(to: tweet)
                } label: {
                    if isPosting { ProgressView().controlSize(.small) } else { Text("Reply").fontWeight(.semibold) }
                }
                .buttonStyle(.glassProminent)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            .frame(maxWidth: 600)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }

    private func send(to tweet: XTweet) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPosting else { return }
        isPosting = true
        Task {
            if await model.post(text: text, replyTo: tweet) {
                reply = ""
                replyFocused = false
            }
            isPosting = false
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    var screenName: String
    @Environment(AppModel.self) private var model
    @State private var user: XUser?
    @State private var feed: FeedModel?
    @State private var error: String?

    var body: some View {
        Group {
            if let user, let feed {
                FeedView(feed: feed, emptyTitle: "No posts yet", emptySymbol: "text.bubble") {
                    ProfileHeader(user: user)
                    Divider()
                }
            } else if let error {
                ContentUnavailableView("Couldn't load @\(screenName)", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(error))
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(user?.name ?? "@\(screenName)")
        .navigationSubtitle(user.map { "\($0.postsCount.compact) posts" } ?? "")
        .task(id: screenName) { await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            let loaded = try await client.user(screenName: screenName)
            let userID = loaded.id
            feed = FeedModel { client, cursor in try await client.userTweets(userID: userID, cursor: cursor) }
            user = loaded
        } catch {
            model.report(error)
            self.error = error.localizedDescription
        }
    }
}

struct ProfileHeader: View {
    var user: XUser
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3, contentMode: .fit)
                .overlay {
                    if let banner = user.bannerURL {
                        AsyncImage(url: banner) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }
                    } else {
                        LinearGradient(colors: [.xBlue.opacity(0.5), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .clipped()
                .backgroundExtensionEffect()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom) {
                    Avatar(user: user, size: 112)
                        .padding(4)
                        .background(Circle().fill(.background).opacity(user.hasSquareAvatar ? 0 : 1))
                        .offset(y: -56)
                        .padding(.bottom, -56)
                    Spacer()
                    Button("Open on x.com", systemImage: "arrow.up.right") {
                        openURL(URL(string: "https://x.com/\(user.screenName)")!)
                    }
                    .buttonStyle(.glass)
                    if user.isFollowing {
                        Text("Following")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.system(size: 22, weight: .bold))
                        VerifiedBadge(user: user, size: 18)
                        if user.isProtected { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    }
                    Text("@\(user.screenName)").foregroundStyle(.secondary)
                }

                if !user.bio.isEmpty {
                    Text(TweetText.attributed(user.bio, links: [:]))
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    if !user.location.isEmpty { Label(user.location, systemImage: "mappin.and.ellipse") }
                    if let website = user.website {
                        Button { if let url = user.websiteURL { openURL(url) } } label: {
                            Label(website, systemImage: "link")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.xBlue)
                    }
                    if let joined = user.joined { Label("Joined \(joined.formatted(.dateTime.month(.wide).year()))", systemImage: "calendar") }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 18) {
                    stat(user.followingCount, "Following")
                    stat(user.followersCount, "Followers")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value.compact).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .font(.system(size: 14))
    }
}

// MARK: - Explore / Search

struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var query = ""

    var body: some View {
        Group {
            if query.isEmpty {
                ContentUnavailableView {
                    Label("Search X", systemImage: "magnifyingglass")
                } description: {
                    Text("Find posts, people and topics. Search operators like from:, since: and filter:media work too.")
                }
            } else {
                SearchResultsView(query: query).id(query)
            }
        }
        .navigationTitle("Explore")
        .searchable(text: $text, placement: .toolbar, prompt: "Search X")
        .onSubmit(of: .search) { query = text.trimmingCharacters(in: .whitespaces) }
    }
}

struct SearchResultsView: View {
    var query: String
    @AppStorage("searchLatest") private var latest = false

    var body: some View {
        FeedView(feed: FeedModel { [latest] client, cursor in try await client.search(query, latest: latest, cursor: cursor) },
                 emptyTitle: "No results for “\(query)”", emptySymbol: "magnifyingglass")
            .id("\(query)-\(latest)")
            .navigationTitle(query)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Sort", selection: $latest) {
                        Text("Top").tag(false)
                        Text("Latest").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
    }
}

// MARK: - Notifications

struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FeedView(feed: model.notificationsFeed, emptyTitle: "No notifications yet", emptySymbol: "bell")
            .navigationTitle("Notifications")
    }
}

struct NotificationRow: View {
    var notification: XNotification
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.name)
                .font(.system(size: 22))
                .foregroundStyle(symbol.color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                if !notification.users.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(notification.users.prefix(8)) { user in
                            Avatar(user: user, size: 32)
                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                .onTapGesture { model.open(.user(user.screenName)) }
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(notification.message).font(.system(size: 15))
                    Spacer()
                    if let date = notification.date {
                        Text(date.timelineLabel).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                if let preview = notification.tweetPreview, !preview.isEmpty {
                    Text(preview).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hovering ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && notification.tweetID != nil }
        .onTapGesture { if let id = notification.tweetID { model.open(.tweetID(id)) } }
    }

    private var symbol: (name: String, color: Color) {
        let icon = notification.icon
        if icon.contains("heart") { return ("heart.fill", .xPink) }
        if icon.contains("retweet") { return ("arrow.2.squarepath", .xGreen) }
        if icon.contains("person") || icon.contains("follow") { return ("person.fill", .xBlue) }
        if icon.contains("bell") { return ("bell.fill", .xBlue) }
        if icon.contains("star") || icon.contains("bird") { return ("star.fill", .purple) }
        if icon.contains("security") || icon.contains("safety") { return ("lock.shield.fill", .orange) }
        if icon.contains("live") || icon.contains("space") { return ("waveform", .purple) }
        return ("sparkles", .xBlue)
    }
}

// MARK: - Bookmarks

struct BookmarksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FeedView(feed: model.bookmarksFeed, emptyTitle: "Save posts for later", emptySymbol: "bookmark")
            .navigationTitle("Bookmarks")
    }
}

// MARK: - Routing

struct RouteView: View {
    var route: Route
    var body: some View {
        switch route {
        case .tweet(let tweet): TweetDetailView(tweetID: tweet.id, initial: tweet)
        case .tweetID(let id): TweetDetailView(tweetID: id)
        case .user(let name): ProfileView(screenName: name)
        case .search(let query): SearchResultsView(query: query)
        }
    }
}
