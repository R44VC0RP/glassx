import Foundation

struct XUser: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var screenName: String
    var avatarURL: URL?
    var bannerURL: URL?
    var bio: String = ""
    var location: String = ""
    var website: String?
    var websiteURL: URL?
    var hasSquareAvatar = false
    var followersCount: Int = 0
    var followingCount: Int = 0
    var postsCount: Int = 0
    var isVerified: Bool = false
    var verifiedType: String?
    var isProtected: Bool = false
    var isFollowing: Bool = false
    var followsYou: Bool = false
    var isMuting: Bool = false
    var isBlocking: Bool = false
    var pinnedTweetID: String?
    var joined: Date?

    /// The avatar variant to fetch for a given display size in points.
    func avatarURL(forSize size: Double) -> URL? {
        if size > 56 { return largeAvatarURL }
        return avatarURL.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "_normal.", with: "_bigger.")) }
    }

    /// A sharper avatar than the 48px `_normal` default.
    var largeAvatarURL: URL? {
        guard let avatarURL else { return nil }
        return URL(string: avatarURL.absoluteString.replacingOccurrences(of: "_normal.", with: "_400x400."))
    }
}

struct XMedia: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case photo, video, gif }
    var id: String
    var kind: Kind
    var previewURL: URL
    var videoURL: URL?
    /// A lighter variant (≤ ~2 Mbps) for muted inline autoplay.
    var inlineVideoURL: URL?
    var width: Double
    var height: Double
    var altText: String?
    var durationMillis: Int?

    var aspectRatio: Double { width > 0 && height > 0 ? width / height : 16 / 9 }

    var fullSizeURL: URL {
        guard kind == .photo else { return previewURL }
        return URL(string: previewURL.absoluteString + "?name=orig") ?? previewURL
    }
}

struct XLinkCard: Hashable, Codable, Sendable {
    var title: String
    var domain: String
    var url: URL
    var imageURL: URL?
}

struct XTweet: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var author: XUser
    var text: String
    /// Display URL → destination, for linking the shortened URLs shown in `text`.
    var links: [String: URL] = [:]
    var createdAt: Date?
    var replyCount = 0
    var retweetCount = 0
    var likeCount = 0
    var quoteCount = 0
    var bookmarkCount = 0
    var viewCount: Int?
    var isLiked = false
    var isRetweeted = false
    var isBookmarked = false
    var media: [XMedia] = []
    /// Zero or one quoted post (an array keeps the struct non-recursive).
    var quoted: [XTweet] = []
    var card: XLinkCard?
    var replyingTo: [String] = []
    var conversationId: String?

    var url: URL { URL(string: "https://x.com/\(author.screenName)/status/\(id)")! }
}

/// A post as it appears in a feed, with the context of how it got there.
struct FeedTweet: Identifiable, Hashable, Sendable {
    var id: String
    var tweet: XTweet
    var repostedBy: XUser?
    var socialContext: String?
    /// SF Symbol for the context line ("Pinned", "X liked", "Followed by …").
    var socialSymbol: String?
    /// Draws a thread line down to the next post (conversation modules and reply chains).
    var connectsBelow = false
    var connectsAbove = false
}

struct XNotification: Identifiable, Hashable, Sendable {
    var id: String
    var icon: String
    var message: String
    /// Unicode-scalar ranges in `message` that X renders bold (the people's names).
    var boldRanges: [Range<Int>] = []
    var users: [XUser]
    var date: Date?
    var tweet: XTweet?
    var tweetID: String?
}

enum FeedItem: Identifiable, Hashable, Sendable {
    case tweet(FeedTweet)
    case notification(XNotification)

    var id: String {
        switch self {
        case .tweet(let item): "t-\(item.id)"
        case .notification(let item): "n-\(item.id)"
        }
    }
}

struct FeedPage: Sendable {
    var items: [FeedItem]
    var bottomCursor: String?
    var topCursor: String?
}

enum XError: LocalizedError, Sendable {
    case notSignedIn
    case unauthorized
    case rateLimited(resetAt: Date?)
    case http(Int, String)
    case api(String)
    case catalog(String)
    case missingOperation(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "You're not signed in."
        case .unauthorized: "Your X session expired. Sign in again."
        case .rateLimited(let reset):
            if let reset { "X rate limit reached. Try again \(reset.formatted(.relative(presentation: .named)))." }
            else { "X rate limit reached. Try again in a few minutes." }
        case .http(let code, let body): "X returned HTTP \(code). \(body.prefix(200))"
        case .api(let message): message
        case .catalog(let message): message
        case .missingOperation(let name): "X's web client no longer exposes \(name)."
        }
    }
}
