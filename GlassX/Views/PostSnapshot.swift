import SwiftUI

/// A static, self-contained card of a post for "Copy as Image". Only uses images already in the
/// image cache, so it renders synchronously.
struct PostSnapshot: View {
    var tweet: XTweet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(user: tweet.author, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(tweet.author.name).font(.system(size: 16, weight: .bold))
                        VerifiedBadge(user: tweet.author, size: 15)
                    }
                    Text("@\(tweet.author.screenName)").font(.system(size: 14)).foregroundStyle(Color.xGray)
                }
                Spacer()
                Text("𝕏").font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            }
            if !tweet.text.isEmpty {
                Text(TweetText.attributed(tweet.text, links: tweet.links))
                    .font(.system(size: 18))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let media = tweet.media.first {
                RemoteImage(url: media.previewURL, maxPixel: ImageSize.media)
                    .aspectRatio(max(media.aspectRatio, 0.8), contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 16) {
                if let date = tweet.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Label(tweet.replyCount.compact, systemImage: "bubble.left")
                Label(tweet.retweetCount.compact, systemImage: "arrow.2.squarepath")
                Label(tweet.likeCount.compact, systemImage: "heart")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.xGray)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .background(Color(red: 22 / 255, green: 24 / 255, blue: 28 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(20)
        .background(Color.black)
    }
}
