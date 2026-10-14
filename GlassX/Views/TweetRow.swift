import SwiftUI

struct TweetRow: View {
    var item: FeedTweet
    @Environment(AppModel.self) private var model
    @Environment(\.showsReplyContext) private var showsReplyContext

    private var tweet: XTweet { item.tweet }
    private var topPadding: CGFloat { item.connectsAbove ? 4 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reposter = item.repostedBy {
                contextLabel("arrow.2.squarepath", "\(reposter.name) reposted")
                    .onTapGesture { model.open(.user(reposter.screenName)) }
            } else if let context = item.socialContext {
                contextLabel("person.2.fill", context)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    Avatar(user: tweet.author, size: 40)
                        .onTapGesture { model.open(.user(tweet.author.screenName)) }
                        .pointerStyle(.link)
                    if item.connectsBelow {
                        Capsule().fill(Color.xLine).frame(width: 2).frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 40)

                VStack(alignment: .leading, spacing: 6) {
                    AuthorLine(user: tweet.author, date: tweet.createdAt)
                    if showsReplyContext, !tweet.replyingTo.isEmpty, !item.connectsAbove {
                        ReplyingToLabel(names: tweet.replyingTo)
                    }
                    if !tweet.text.isEmpty { TweetText(tweet: tweet) }
                    if !tweet.media.isEmpty { MediaGrid(media: tweet.media).padding(.top, 4) }
                    if let card = tweet.card, tweet.media.isEmpty { LinkCardView(card: card).padding(.top, 4) }
                    if let quoted = tweet.quoted.first { QuoteCard(tweet: quoted).padding(.top, 4) }
                    EngagementBar(tweet: tweet).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, item.connectsBelow ? 0 : 6)
        .overlay(alignment: .topLeading) {
            // Continue the thread line from the previous post down to this avatar.
            if item.connectsAbove {
                Rectangle().fill(Color.xLine).frame(width: 2, height: topPadding - 2).offset(x: 16 + 19)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(.tweet(tweet)) }
        .contextMenu { TweetMenu(tweet: tweet) }
        .accessibilityElement(children: .contain)
    }

    private func contextLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).frame(width: 40, alignment: .trailing)
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Color.xGray)
    }
}

struct ReplyingToLabel: View {
    var names: [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 3) {
            Text("Replying to").foregroundStyle(Color.xGray)
            ForEach(names, id: \.self) { name in
                Button("@\(name)") { model.open(.user(name)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.xBlue)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }
}

struct EngagementBar: View {
    var tweet: XTweet
    var showViews = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.state(for: tweet)
        HStack(spacing: 0) {
            EngagementButton(symbol: "bubble.left", count: tweet.replyCount, label: "Reply") {
                model.compose = ComposeTarget(replyTo: tweet)
            }
            Spacer(minLength: 0)
            EngagementButton(symbol: "arrow.2.squarepath", count: state.repostCount, isActive: state.reposted, activeColor: .xGreen, label: state.reposted ? "Undo repost" : "Repost") {
                model.toggleRepost(tweet)
            }
            Spacer(minLength: 0)
            EngagementButton(symbol: "heart", activeSymbol: "heart.fill", count: state.likeCount, isActive: state.liked, activeColor: .xPink, label: state.liked ? "Unlike" : "Like") {
                model.toggleLike(tweet)
            }
            Spacer(minLength: 0)
            if showViews {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar").frame(width: 30, height: 30)
                    if let views = tweet.viewCount { Text(views.compact).monospacedDigit() }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.xGray)
                .accessibilityLabel("\(tweet.viewCount ?? 0) views")
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                EngagementButton(symbol: "bookmark", activeSymbol: "bookmark.fill", isActive: state.bookmarked, label: state.bookmarked ? "Remove bookmark" : "Bookmark") {
                    model.toggleBookmark(tweet)
                }
                ShareLink(item: tweet.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Color.xGray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, -8)
    }
}

struct QuoteCard: View {
    var tweet: XTweet
    @Environment(AppModel.self) private var model

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Avatar(user: tweet.author, size: 20)
                AuthorLine(user: tweet.author, date: tweet.createdAt, compact: true)
            }
            if !tweet.text.isEmpty { TweetText(tweet: tweet, size: 14, lineLimit: 8) }
            if !tweet.media.isEmpty { MediaGrid(media: tweet.media, maxHeight: 280) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(Color.xLine, lineWidth: 1))
        .contentShape(shape)
        .onTapGesture { model.open(.tweet(tweet)) }
    }
}

struct TweetMenu: View {
    var tweet: XTweet
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Reply", systemImage: "bubble.left") { model.compose = ComposeTarget(replyTo: tweet) }
        Button("View @\(tweet.author.screenName)", systemImage: "person") { model.open(.user(tweet.author.screenName)) }
        Divider()
        Button("Copy Link", systemImage: "link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tweet.url.absoluteString, forType: .string)
        }
        Button("Copy Text", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tweet.text, forType: .string)
        }
        Button("Open on x.com", systemImage: "safari") { openURL(tweet.url) }
    }
}

/// The large, selectable post at the top of a thread.
struct FocalTweet: View {
    var tweet: XTweet
    var connectsAbove = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(user: tweet.author, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(tweet.author.name).font(.system(size: 15, weight: .semibold))
                        VerifiedBadge(user: tweet.author, size: 15)
                    }
                    Text("@\(tweet.author.screenName)").font(.system(size: 14)).foregroundStyle(Color.xGray)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.open(.user(tweet.author.screenName)) }
                Spacer()
            }
            if !tweet.replyingTo.isEmpty { ReplyingToLabel(names: tweet.replyingTo) }
            if !tweet.text.isEmpty {
                TweetText(tweet: tweet, size: 17).textSelection(.enabled)
            }
            if !tweet.media.isEmpty { MediaGrid(media: tweet.media, maxHeight: 640) }
            if let card = tweet.card, tweet.media.isEmpty { LinkCardView(card: card) }
            if let quoted = tweet.quoted.first { QuoteCard(tweet: quoted) }

            HStack(spacing: 4) {
                if let date = tweet.createdAt {
                    Text(date.formatted(date: .omitted, time: .shortened) + " · " + date.formatted(.dateTime.month(.abbreviated).day().year()))
                }
                if let views = tweet.viewCount {
                    Text("·")
                    Text(views.compact).foregroundStyle(.primary).fontWeight(.semibold)
                    Text("Views")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.xGray)

            Hairline()
            EngagementBar(tweet: tweet, showViews: false)
            Hairline()
        }
        .padding(.horizontal, 16)
        .padding(.top, connectsAbove ? 4 : 12)
        .contextMenu { TweetMenu(tweet: tweet) }
    }
}
