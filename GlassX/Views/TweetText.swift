import SwiftUI

/// Post text with tappable links, @mentions, #hashtags and $cashtags.
struct TweetText: View {
    var tweet: XTweet
    var size: CGFloat = 15
    var lineLimit: Int?

    var body: some View {
        Text(Self.attributed(tweet.text, links: tweet.links))
            .font(.system(size: size))
            .lineSpacing(2)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Formatting cache: building the attributed string runs a regex, so do it once per post.
    @MainActor private static var cache: [Int: AttributedString] = [:]

    @MainActor static func attributed(_ text: String, links: [String: URL]) -> AttributedString {
        var hasher = Hasher()
        hasher.combine(text)
        for key in links.keys.sorted() { hasher.combine(key) }
        let key = hasher.finalize()
        if let hit = cache[key] { return hit }
        let value = build(text, links: links)
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    private static func build(_ text: String, links: [String: URL]) -> AttributedString {
        let urlPattern = links.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        let patterns = urlPattern + [#"(?<![\w@])@\w{1,15}"#, #"(?<![\w&])#\w+"#, #"(?<![\w])\$[A-Za-z]{1,6}\b"#]
        guard let regex = try? NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|")) else {
            return AttributedString(text)
        }

        var result = AttributedString()
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound { result += AttributedString(text[cursor..<range.lowerBound]) }
            let token = String(text[range])
            var piece = AttributedString(token)
            piece.link = destination(for: token, links: links)
            piece.foregroundColor = .xBlue
            result += piece
            cursor = range.upperBound
        }
        if cursor < text.endIndex { result += AttributedString(text[cursor...]) }
        return result
    }

    private static func destination(for token: String, links: [String: URL]) -> URL? {
        if let url = links[token] { return url }
        if token.hasPrefix("@") { return URL(string: "glassx://user/\(token.dropFirst())") }
        var components = URLComponents()
        components.scheme = "glassx"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: token)]
        return components.url
    }
}
