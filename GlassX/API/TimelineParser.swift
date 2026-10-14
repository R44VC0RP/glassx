import Foundation

/// Turns X's GraphQL timeline JSON into app models. X's payloads change shape often,
/// so every lookup is optional and tries both the current and the older field locations.
enum TimelineParser {
    typealias JSON = [String: Any]

    // MARK: Timelines

    static func page(from root: Any) -> FeedPage {
        let instructions = findInstructions(in: root) ?? []
        var items: [FeedItem] = []
        var bottom: String?
        var top: String?
        var seen = Set<String>()

        func append(_ item: FeedItem) {
            guard seen.insert(item.id).inserted else { return }
            items.append(item)
        }

        var entries: [JSON] = []
        for instruction in instructions {
            switch instruction["type"] as? String {
            case "TimelineAddEntries":
                entries += instruction["entries"] as? [JSON] ?? []
            case "TimelinePinEntry", "TimelineReplaceEntry":
                if let entry = instruction["entry"] as? JSON { entries.append(entry) }
            case "TimelineAddToModule":
                // Later pages of a module (e.g. the profile media grid) arrive as module items.
                let moduleItems = (instruction["moduleItems"] as? [JSON] ?? []).compactMap { $0["item"] as? JSON }
                entries.append(["entryId": instruction["moduleEntryId"] as? String ?? "module",
                                "content": ["entryType": "TimelineTimelineModule", "items": moduleItems.map { ["item": $0] }]])
            default:
                break
            }
        }

        for entry in entries {
            let entryID = entry["entryId"] as? String ?? ""
            guard !entryID.hasPrefix("promoted"), let content = entry["content"] as? JSON else { continue }
            let kind = (content["entryType"] as? String) ?? (content["__typename"] as? String) ?? ""

            switch kind {
            case "TimelineTimelineCursor":
                let value = content["value"] as? String
                switch content["cursorType"] as? String {
                case "Bottom": bottom = value
                case "Top": top = value
                default: break
                }
            case "TimelineTimelineItem":
                guard let itemContent = content["itemContent"] as? JSON else { continue }
                if let item = feedItem(from: itemContent, entryID: entryID, context: content) { append(item) }
                if itemContent["itemType"] as? String == "TimelineTimelineCursor" || itemContent["__typename"] as? String == "TimelineTimelineCursor",
                   itemContent["cursorType"] as? String == "Bottom" {
                    bottom = itemContent["value"] as? String
                }
            case "TimelineTimelineModule":
                let moduleItems = (content["items"] as? [JSON] ?? []).compactMap { $0["item"] as? JSON }
                var tweets: [FeedTweet] = []
                for moduleItem in moduleItems {
                    guard let itemContent = moduleItem["itemContent"] as? JSON,
                          case .tweet(let feedTweet)? = feedItem(from: itemContent, entryID: entryID, context: moduleItem)
                    else { continue }
                    tweets.append(feedTweet)
                }
                let isConversation = (content["displayType"] as? String)?.contains("Conversation") ?? false
                for (index, var tweet) in tweets.enumerated() {
                    if isConversation {
                        tweet.connectsAbove = index > 0
                        tweet.connectsBelow = index < tweets.count - 1
                    }
                    append(.tweet(tweet))
                }
            default:
                break
            }
        }
        return FeedPage(items: items, bottomCursor: bottom, topCursor: top)
    }

    private static func feedItem(from itemContent: JSON, entryID: String, context: JSON) -> FeedItem? {
        if itemContent["promotedMetadata"] != nil { return nil }
        let type = (itemContent["itemType"] as? String) ?? (itemContent["__typename"] as? String)
        switch type {
        case "TimelineTweet":
            guard let result = (itemContent["tweet_results"] as? JSON)?["result"] as? JSON,
                  let feedTweet = feedTweet(from: result)
            else { return nil }
            var item = feedTweet
            if let context = itemContent["socialContext"] as? JSON, let social = context["text"] as? String, item.repostedBy == nil {
                item.socialContext = social
                item.socialSymbol = switch (context["contextType"] as? String ?? "").lowercased() {
                case "pin": "pin.fill"
                case "like": "heart.fill"
                case "follow", "following": "person.fill"
                case "conversation", "reply": "bubble.left.fill"
                case "community": "person.3.fill"
                case "list": "list.bullet"
                case "topic": "number"
                case "location": "mappin"
                case "megaphone", "spaces": "megaphone.fill"
                default: social.lowercased().contains("pinned") ? "pin.fill" : "sparkles"
                }
            }
            return .tweet(item)
        case "TimelineNotification":
            return notification(from: itemContent, fallbackID: entryID).map(FeedItem.notification)
        default:
            return nil
        }
    }

    /// Recursively finds the first `instructions` array, whatever the operation's wrapper keys are.
    static func findInstructions(in value: Any, depth: Int = 0) -> [JSON]? {
        guard depth < 12 else { return nil }
        if let object = value as? JSON {
            if let instructions = object["instructions"] as? [JSON] { return instructions }
            for child in object.values {
                if let found = findInstructions(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    // MARK: Tweets

    static func feedTweet(from result: JSON) -> FeedTweet? {
        guard let outer = unwrapTweet(result), let legacy = outer["legacy"] as? JSON else { return nil }
        if let retweeted = ((legacy["retweeted_status_result"] as? JSON)?["result"] as? JSON),
           let inner = tweet(from: retweeted) {
            let reposter = user(fromResult: outer["core"])
            return FeedTweet(id: "rt-\(outer["rest_id"] as? String ?? inner.id)", tweet: inner, repostedBy: reposter)
        }
        guard let tweet = tweet(from: outer) else { return nil }
        return FeedTweet(id: tweet.id, tweet: tweet)
    }

    static func unwrapTweet(_ result: JSON) -> JSON? {
        switch result["__typename"] as? String {
        case "TweetWithVisibilityResults": return result["tweet"] as? JSON
        case "TweetTombstone", "TweetUnavailable": return nil
        default: return result
        }
    }

    static func tweet(from raw: JSON, includeQuote: Bool = true) -> XTweet? {
        guard let result = unwrapTweet(raw),
              let legacy = result["legacy"] as? JSON,
              let id = (result["rest_id"] as? String) ?? (legacy["id_str"] as? String),
              let author = user(fromResult: result["core"])
        else { return nil }

        var links: [String: URL] = [:]
        var text: String
        let noteResult = ((result["note_tweet"] as? JSON)?["note_tweet_results"] as? JSON)?["result"] as? JSON

        let mediaEntities = ((legacy["extended_entities"] as? JSON)?["media"] as? [JSON])
            ?? ((legacy["entities"] as? JSON)?["media"] as? [JSON]) ?? []

        if let note = noteResult, let noteText = note["text"] as? String {
            text = noteText
            let urls = ((note["entity_set"] as? JSON)?["urls"] as? [JSON]) ?? []
            text = expandURLs(in: text, urls: urls, links: &links)
        } else {
            text = legacy["full_text"] as? String ?? ""
            if let range = legacy["display_text_range"] as? [Int], range.count == 2 {
                let scalars = Array(text.unicodeScalars)
                let lower = min(max(range[0], 0), scalars.count)
                let upper = min(max(range[1], lower), scalars.count)
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[lower..<upper])
                text = String(view)
            }
            let urls = ((legacy["entities"] as? JSON)?["urls"] as? [JSON]) ?? []
            text = expandURLs(in: text, urls: urls, links: &links)
        }
        for media in mediaEntities {
            if let shortURL = media["url"] as? String { text = text.replacingOccurrences(of: shortURL, with: "") }
        }
        text = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)

        var tweet = XTweet(id: id, author: author, text: text, links: links)
        tweet.createdAt = (legacy["created_at"] as? String).flatMap(parseDate)
        tweet.replyCount = int(legacy["reply_count"])
        tweet.retweetCount = int(legacy["retweet_count"])
        tweet.likeCount = int(legacy["favorite_count"])
        tweet.quoteCount = int(legacy["quote_count"])
        tweet.bookmarkCount = int(legacy["bookmark_count"])
        tweet.viewCount = ((result["views"] as? JSON)?["count"] as? String).flatMap(Int.init)
        tweet.isLiked = legacy["favorited"] as? Bool ?? false
        tweet.isRetweeted = legacy["retweeted"] as? Bool ?? false
        tweet.isBookmarked = legacy["bookmarked"] as? Bool ?? false
        tweet.conversationId = legacy["conversation_id_str"] as? String
        tweet.media = mediaEntities.compactMap(media(from:))
        tweet.card = card(from: result["card"] as? JSON)

        if let replyTo = legacy["in_reply_to_screen_name"] as? String {
            let mentions = ((legacy["entities"] as? JSON)?["user_mentions"] as? [JSON] ?? []).compactMap { $0["screen_name"] as? String }
            var names = [replyTo] + mentions.filter { $0 != replyTo && !text.contains("@\($0)") }
            names = Array(NSOrderedSet(array: names)) as? [String] ?? names
            tweet.replyingTo = Array(names.prefix(3))
        }

        if includeQuote, let quoted = (result["quoted_status_result"] as? JSON)?["result"] as? JSON,
           let quotedTweet = Self.tweet(from: quoted, includeQuote: false) {
            tweet.quoted = [quotedTweet]
            if let permalink = (legacy["quoted_status_permalink"] as? JSON)?["url"] as? String {
                tweet.text = tweet.text.replacingOccurrences(of: permalink, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if tweet.card != nil || !tweet.quoted.isEmpty {
            // The card/quote already shows the trailing link; drop it from the text when it is the last token.
            if let last = tweet.links.first(where: { tweet.text.hasSuffix($0.key) && ($0.value.host?.contains("x.com") == true || $0.value.host?.contains("twitter.com") == true) }) {
                tweet.text = String(tweet.text.dropLast(last.key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return tweet
    }

    private static func expandURLs(in text: String, urls: [JSON], links: inout [String: URL]) -> String {
        var text = text
        for entry in urls {
            guard let short = entry["url"] as? String else { continue }
            let display = (entry["display_url"] as? String) ?? short
            text = text.replacingOccurrences(of: short, with: display)
            if let expanded = (entry["expanded_url"] as? String).flatMap(URL.init(string:)) { links[display] = expanded }
        }
        return text
    }

    private static func media(from entry: JSON) -> XMedia? {
        guard let preview = (entry["media_url_https"] as? String).flatMap(URL.init(string:)) else { return nil }
        let size = entry["original_info"] as? JSON
        let kind: XMedia.Kind = switch entry["type"] as? String {
        case "video": .video
        case "animated_gif": .gif
        default: .photo
        }
        let videoInfo = entry["video_info"] as? JSON
        let variants = (videoInfo?["variants"] as? [JSON] ?? []).filter { ($0["content_type"] as? String) == "video/mp4" }
        let best = variants.max { int($0["bitrate"]) < int($1["bitrate"]) }
        let sorted = variants.sorted { int($0["bitrate"]) < int($1["bitrate"]) }
        let inline = sorted.last { int($0["bitrate"]) <= 2_200_000 } ?? sorted.first
        return XMedia(
            id: entry["id_str"] as? String ?? preview.absoluteString,
            kind: kind,
            previewURL: preview,
            videoURL: (best?["url"] as? String).flatMap(URL.init(string:)),
            inlineVideoURL: (inline?["url"] as? String).flatMap(URL.init(string:)),
            width: double(size?["width"]),
            height: double(size?["height"]),
            altText: entry["ext_alt_text"] as? String,
            durationMillis: videoInfo?["duration_millis"] as? Int
        )
    }

    private static func card(from card: JSON?) -> XLinkCard? {
        guard let legacy = card?["legacy"] as? JSON, let bindings = legacy["binding_values"] as? [JSON] else { return nil }
        var values: [String: JSON] = [:]
        for binding in bindings {
            if let key = binding["key"] as? String, let value = binding["value"] as? JSON { values[key] = value }
        }
        func string(_ key: String) -> String? { values[key]?["string_value"] as? String }
        func image(_ keys: [String]) -> URL? {
            for key in keys { if let url = ((values[key]?["image_value"] as? JSON)?["url"] as? String).flatMap(URL.init(string:)) { return url } }
            return nil
        }
        guard let title = string("title"),
              let url = (string("card_url") ?? legacy["url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return XLinkCard(
            title: title,
            domain: string("vanity_url") ?? string("domain") ?? url.host ?? "",
            url: url,
            imageURL: image(["summary_photo_image_large", "thumbnail_image_large", "photo_image_full_size_large", "summary_photo_image"])
        )
    }

    // MARK: Users

    static func user(fromResult container: Any?) -> XUser? {
        guard let result = ((container as? JSON)?["user_results"] as? JSON)?["result"] as? JSON else { return nil }
        return user(from: result)
    }

    static func user(from result: JSON) -> XUser? {
        guard result["__typename"] as? String != "UserUnavailable",
              let id = result["rest_id"] as? String
        else { return nil }
        let legacy = result["legacy"] as? JSON ?? [:]
        let core = result["core"] as? JSON ?? [:]
        guard let screenName = (core["screen_name"] as? String) ?? (legacy["screen_name"] as? String) else { return nil }

        var user = XUser(
            id: id,
            name: (core["name"] as? String) ?? (legacy["name"] as? String) ?? screenName,
            screenName: screenName
        )
        user.avatarURL = (((result["avatar"] as? JSON)?["image_url"] as? String) ?? (legacy["profile_image_url_https"] as? String)).flatMap(URL.init(string:))
        let banner = ((result["banner"] as? JSON)?["image_url"] as? String) ?? (legacy["profile_banner_url"] as? String)
        user.bannerURL = banner.flatMap { URL(string: $0 + "/1500x500") }
        user.hasSquareAvatar = (result["profile_image_shape"] as? String) == "Square"

        let profileBio = result["profile_bio"] as? JSON
        let entities = (profileBio?["entities"] as? JSON) ?? (legacy["entities"] as? JSON)
        var bio = (profileBio?["description"] as? String) ?? (legacy["description"] as? String) ?? ""
        for url in (entities?["description"] as? JSON)?["urls"] as? [JSON] ?? [] {
            if let short = url["url"] as? String, let display = url["display_url"] as? String {
                bio = bio.replacingOccurrences(of: short, with: display)
            }
        }
        user.bio = decodeEntities(bio)
        user.location = ((result["location"] as? JSON)?["location"] as? String) ?? (legacy["location"] as? String) ?? ""
        let website = ((entities?["url"] as? JSON)?["urls"] as? [JSON])?.first
        user.website = website?["display_url"] as? String
        user.websiteURL = (website?["expanded_url"] as? String).flatMap(URL.init(string:))

        let counts = result["relationship_counts"] as? JSON
        user.followersCount = counts?["followers"] != nil ? int(counts?["followers"]) : int(legacy["followers_count"])
        user.followingCount = counts?["following"] != nil ? int(counts?["following"]) : int(legacy["friends_count"])
        let tweetCounts = result["tweet_counts"] as? JSON
        user.postsCount = tweetCounts?["tweets"] != nil ? int(tweetCounts?["tweets"]) : int(legacy["statuses_count"])
        user.isVerified = (result["is_blue_verified"] as? Bool ?? false)
            || ((result["verification"] as? JSON)?["verified"] as? Bool ?? false)
            || (legacy["verified"] as? Bool ?? false)
        user.verifiedType = (legacy["verified_type"] as? String) ?? ((result["verification"] as? JSON)?["verified_type"] as? String)
        user.isProtected = ((result["privacy"] as? JSON)?["protected"] as? Bool) ?? (legacy["protected"] as? Bool ?? false)
        let relationship = result["relationship_perspectives"] as? JSON
        user.isFollowing = (relationship?["following"] as? Bool) ?? (legacy["following"] as? Bool ?? false)
        user.followsYou = (relationship?["followed_by"] as? Bool) ?? (legacy["followed_by"] as? Bool ?? false)
        user.isMuting = (relationship?["muting"] as? Bool) ?? (legacy["muting"] as? Bool ?? false)
        user.isBlocking = (relationship?["blocking"] as? Bool) ?? (legacy["blocking"] as? Bool ?? false)
        user.pinnedTweetID = ((result["pinned_items"] as? JSON)?["tweet_ids_str"] as? [String])?.first
            ?? (legacy["pinned_tweet_ids_str"] as? [String])?.first
        user.joined = (((core["created_at"] as? String) ?? (legacy["created_at"] as? String))).flatMap(parseDate)
        return user
    }

    // MARK: Notifications

    static func notification(from content: JSON, fallbackID: String) -> XNotification? {
        let rich = (content["rich_message"] as? JSON) ?? (content["message"] as? JSON)
        guard let message = rich?["text"] as? String else { return nil }

        // Current shape: template.from_users / target_objects. Older: template.aggregateUserActionsV1.fromUsers / targetObjects.
        let template = content["template"] as? JSON
        let aggregate = (template?["aggregateUserActionsV1"] as? JSON) ?? template
        let userRefs = (aggregate?["from_users"] as? [JSON]) ?? (aggregate?["fromUsers"] as? [JSON]) ?? []
        let users = userRefs.compactMap { ((($0["user_results"] as? JSON)?["result"]) as? JSON).flatMap(user(from:)) }

        var tweet: XTweet?
        let targets = (aggregate?["target_objects"] as? [JSON]) ?? (aggregate?["targetObjects"] as? [JSON]) ?? []
        for target in targets {
            if let result = (target["tweet_results"] as? JSON)?["result"] as? JSON, let parsed = Self.tweet(from: result, includeQuote: false) {
                tweet = parsed
                break
            }
        }
        var tweetID = tweet?.id
        if tweetID == nil, let url = (content["notification_url"] as? JSON)?["url"] as? String,
           let match = url.range(of: #"status/(\d+)"#, options: .regularExpression) {
            tweetID = String(url[match].dropFirst("status/".count))
        }

        let bold = (rich?["entities"] as? [JSON] ?? []).compactMap { entity -> Range<Int>? in
            guard let from = entity["fromIndex"] as? Int, let to = entity["toIndex"] as? Int, from < to else { return nil }
            return from..<to
        }

        var date: Date?
        if let raw = content["timestamp_ms"] as? String {
            date = Double(raw).map { Date(timeIntervalSince1970: $0 / 1000) } ?? isoDate(raw)
        } else if let raw = content["timestamp_ms"] as? Double {
            date = Date(timeIntervalSince1970: raw / 1000)
        }

        return XNotification(
            id: content["id"] as? String ?? fallbackID,
            icon: ((content["notification_icon"] as? String) ?? "").lowercased(),
            message: message,
            boldRanges: bold,
            users: users,
            date: date,
            tweet: tweet,
            tweetID: tweetID
        )
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: Helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter
    }()

    static func parseDate(_ string: String) -> Date? { dateFormatter.date(from: string) }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return 0
    }
}
