import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("homeShowsFollowing") private var following = false

    var body: some View {
        FeedView(feed: following ? model.followingFeed : model.forYouFeed, emptyTitle: "Your timeline is empty", emptySymbol: "house")
            .id(following)
            .transition(.opacity)
            .navigationTitle(following ? "Following" : "For You")
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
    @FocusState private var threadFocused: Bool

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
                    if !item.connectsBelow { Hairline() }
                }
                if feed.hasLoaded, !feed.reachedEnd, !parts.replies.isEmpty {
                    ProgressView().padding(24).onAppear { Task { await feed.loadMore(model) } }
                }
                if let error = feed.error {
                    Text(error).font(.callout).foregroundStyle(Color.xGray).padding(24)
                }
                Color.clear.frame(height: 24)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .environment(\.showsReplyContext, false)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .focusable()
        .focusEffectDisabled()
        .focused($threadFocused)
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  let tweet = parts.focal ?? initial else { return .ignored }
            switch press.characters.lowercased() {
            case "q": model.compose = ComposeTarget(quote: tweet)
            case "l": model.toggleLike(tweet)
            case "r": replyFocused = true
            case "t": model.toggleRepost(tweet)
            case "b": model.toggleBookmark(tweet)
            case "u": model.open(.user(tweet.author.screenName))
            default: return .ignored
            }
            return .handled
        }
        .onAppear { threadFocused = true }
        .safeAreaBar(edge: .bottom) { replyBar(to: parts.focal ?? initial) }
        .navigationTitle("Post")
        .onAppear { feed.loadIfNeeded(model) }
        .onChange(of: model.refreshToken) { feed.loadIfNeeded(model) }
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
            .glassEffect(.regular.tint(.black.opacity(0.35)).interactive(), in: .rect(cornerRadius: 22))
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
            if case .failed = await model.post(text: text, replyTo: tweet) {} else {
                reply = ""
                replyFocused = false
            }
            isPosting = false
        }
    }
}

// MARK: - Profile

enum ProfileTab: String, CaseIterable, Hashable {
    case posts, replies, media, likes
    var title: String {
        switch self {
        case .posts: "Posts"
        case .replies: "Replies"
        case .media: "Media"
        case .likes: "Likes"
        }
    }
}

struct ProfileView: View {
    var screenName: String
    @Environment(AppModel.self) private var model
    @State private var user: XUser?
    @State private var feeds: [ProfileTab: FeedModel] = [:]
    @State private var tab: ProfileTab = .posts
    @State private var error: String?

    private var isSelf: Bool { user != nil && user?.id == model.viewer?.id }
    /// X keeps likes private, so the Likes tab only exists on your own profile.
    private var tabs: [ProfileTab] { isSelf ? ProfileTab.allCases : [.posts, .replies, .media] }

    var body: some View {
        Group {
            if let user, let feed = feeds[tab] {
                FeedView(feed: feed, emptyTitle: emptyTitle, emptySymbol: tab == .media ? "photo" : "text.bubble",
                         layout: tab == .media ? .mediaGrid : .list) {
                    ProfileHeader(user: user)
                    FeedTabs(selection: $tab.animation(.smooth), options: tabs.map { ($0, $0.title) })
                }
                .id(tab)
            } else if let error {
                ContentUnavailableView("Couldn't load @\(screenName)", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(error))
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(user?.name ?? "@\(screenName)")
        .navigationSubtitle(user.map { "\($0.postsCount.compact) posts" } ?? "")
        .task(id: "\(screenName)-\(model.profileRevision)") { await load() }
        #if DEBUG
        .onAppear {
            if let i = CommandLine.arguments.firstIndex(of: "--profile-tab"),
               let raw = CommandLine.arguments[safe: i + 1], let forced = ProfileTab(rawValue: raw) { tab = forced }
        }
        #endif
    }

    private var emptyTitle: String {
        switch tab {
        case .posts: "No posts yet"
        case .replies: "No replies yet"
        case .media: "No photos or videos yet"
        case .likes: "No likes yet"
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            let loaded = try await client.user(screenName: screenName)
            let userID = loaded.id
            feeds = [
                .posts: FeedModel { client, cursor in try await client.userTweets(userID: userID, cursor: cursor) },
                .replies: FeedModel { client, cursor in try await client.userReplies(userID: userID, cursor: cursor) },
                .media: FeedModel { client, cursor in try await client.userMedia(userID: userID, cursor: cursor) },
                .likes: FeedModel { client, cursor in try await client.likes(userID: userID, cursor: cursor) },
            ]
            user = loaded
        } catch {
            model.report(error)
            self.error = error.localizedDescription
        }
    }
}

struct ProfileHeader: View {
    var user: XUser
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3, contentMode: .fit)
                .overlay {
                    if let banner = user.bannerURL {
                        RemoteImage(url: banner, maxPixel: ImageSize.banner)
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
                        .background(Circle().fill(Color.black).opacity(user.hasSquareAvatar ? 0 : 1))
                        .offset(y: -56)
                        .padding(.bottom, -56)
                    Spacer()
                    if model.viewer?.id == user.id {
                        OutlineButton(title: "Edit profile") { openURL(URL(string: "https://x.com/settings/profile")!) }
                    } else {
                        ProfileMoreMenu(user: user)
                        FollowButton(user: user)
                    }
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.system(size: 22, weight: .bold))
                        VerifiedBadge(user: user, size: 18)
                        if user.isProtected { Image(systemName: "lock.fill").foregroundStyle(Color.xGray) }
                    }
                    HStack(spacing: 6) {
                        Text("@\(user.screenName)").foregroundStyle(Color.xGray)
                        if user.followsYou, model.viewer?.id != user.id {
                            Text("Follows you")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.xGray)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
                        }
                        if model.relationship(for: user).muting {
                            Label("Muted", systemImage: "speaker.slash.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.xGray)
                        }
                    }
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
                .foregroundStyle(Color.xGray)
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
            Text(label).foregroundStyle(Color.xGray)
        }
        .font(.system(size: 14))
    }
}

/// X's outlined pill button (white text, gray hairline border).
struct OutlineButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .bold)) }
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(.white.opacity(hovering ? 0.1 : 0)))
            .overlay(Capsule().strokeBorder(Color(red: 83 / 255, green: 100 / 255, blue: 113 / 255), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// X's follow button: white "Follow", outlined "Following" that turns into a red "Unfollow" on
/// hover, and a red "Blocked" / "Unblock" when you've blocked them.
struct FollowButton: View {
    var user: XUser
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let relationship = model.relationship(for: user)
        let title: String = relationship.blocking ? (hovering ? "Unblock" : "Blocked")
            : relationship.following ? (hovering ? "Unfollow" : "Following")
            : (user.followsYou ? "Follow back" : "Follow")
        let destructive = relationship.blocking || (relationship.following && hovering)
        let filled = !relationship.following && !relationship.blocking

        Button {
            if relationship.blocking { model.setBlocked(false, user) }
            else { model.setFollowing(!relationship.following, user) }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(filled ? Color.black : (destructive ? Color.red : Color.white))
                .contentTransition(.interpolate)
                .padding(.horizontal, 16)
                .frame(minWidth: 104)
                .frame(height: 34)
                .background(Capsule().fill(filled ? Color.white : (destructive ? Color.red.opacity(0.1) : .clear)))
                .overlay(Capsule().strokeBorder(destructive ? Color.red.opacity(0.5) : Color(red: 83 / 255, green: 100 / 255, blue: 113 / 255),
                                                lineWidth: filled ? 0 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .animation(.snappy(duration: 0.25), value: relationship)
        .accessibilityLabel(title)
    }
}

/// "…" menu on someone's profile: mute, block, copy link, open on x.com.
struct ProfileMoreMenu: View {
    var user: XUser
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmingBlock = false

    var body: some View {
        let relationship = model.relationship(for: user)
        Menu {
            Button(relationship.muting ? "Unmute @\(user.screenName)" : "Mute @\(user.screenName)",
                   systemImage: relationship.muting ? "speaker.wave.2" : "speaker.slash") {
                model.setMuted(!relationship.muting, user)
            }
            if relationship.blocking {
                Button("Unblock @\(user.screenName)", systemImage: "hand.raised.slash") { model.setBlocked(false, user) }
            } else {
                Button("Block @\(user.screenName)…", systemImage: "hand.raised", role: .destructive) { confirmingBlock = true }
            }
            Divider()
            Button("Copy Link to Profile", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://x.com/\(user.screenName)", forType: .string)
            }
            Button("Open on x.com", systemImage: "safari") { openURL(URL(string: "https://x.com/\(user.screenName)")!) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Color(red: 83 / 255, green: 100 / 255, blue: 113 / 255), lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .confirmationDialog("Block @\(user.screenName)?", isPresented: $confirmingBlock) {
            Button("Block", role: .destructive) { model.setBlocked(true, user) }
        } message: {
            Text("They won't be able to follow you or see your posts, and you won't see their posts or notifications.")
        }
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
            .transition(.opacity)
            .navigationTitle(query)
    }
}

// MARK: - Notifications

struct NotificationsView: View {
    enum Tab: String { case all, priority, mentions }
    @Environment(AppModel.self) private var model
    @AppStorage("notificationsTab") private var tab: Tab = .all

    var body: some View {
        FeedView(feed: feed, emptyTitle: tab == .mentions ? "No mentions yet" : "No notifications yet", emptySymbol: "bell")
            .id(tab)
            .transition(.opacity)
            .navigationTitle("Notifications")
    }

    private var feed: FeedModel {
        switch tab {
        case .all: model.notificationsFeed
        case .priority: model.priorityNotificationsFeed
        case .mentions: model.mentionsFeed
        }
    }
}

/// Mirrors x.com: icon column, avatar row, bold names + action + time, gray post text, media thumbnail.
struct NotificationRow: View {
    var notification: XNotification
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol.name)
                .font(.system(size: 26))
                .foregroundStyle(symbol.color)
                .frame(width: 40, height: 32, alignment: .trailing)

            VStack(alignment: .leading, spacing: 12) {
                if !notification.users.isEmpty {
                    AvatarStack(users: Array(notification.users.prefix(8))) { model.open(.user($0.screenName)) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    (Text(headline) + timeText)
                        .font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                    if let text = notification.tweet?.text, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.xGray)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let thumb = notification.tweet?.media.first {
                Color.clear
                    .frame(width: 64, height: 64)
                    .overlay {
                        RemoteImage(url: thumb.previewURL, maxPixel: ImageSize.thumbnail)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.xLine, lineWidth: 1))
                    .padding(.top, 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if let tweet = notification.tweet { model.open(.tweet(tweet)) }
            else if let id = notification.tweetID { model.open(.tweetID(id)) }
            else if let user = notification.users.first { model.open(.user(user.screenName)) }
        }
    }

    private var headline: AttributedString {
        var result = AttributedString(notification.message)
        result.foregroundColor = Color(red: 231 / 255, green: 233 / 255, blue: 234 / 255)
        // X's fromIndex/toIndex count Unicode scalars (code points).
        let scalars = notification.message.unicodeScalars
        for range in notification.boldRanges {
            guard range.upperBound <= scalars.count else { continue }
            let lower = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
            let upper = scalars.index(scalars.startIndex, offsetBy: range.upperBound)
            guard let attrRange = Range(lower..<upper, in: result) else { continue }
            result[attrRange].font = .system(size: 15, weight: .bold)
        }
        return result
    }

    private var timeText: Text {
        guard let date = notification.date else { return Text("") }
        return Text(" · \(date.timelineLabel)").foregroundStyle(Color.xGray)
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
        if icon.contains("milestone") || icon.contains("trending") { return ("chart.line.uptrend.xyaxis", .xBlue) }
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
