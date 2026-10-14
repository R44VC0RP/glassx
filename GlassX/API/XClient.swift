import Foundation
import os

/// Talks to X's web GraphQL API with the cookies from the in-app sign-in.
actor XClient {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// The public bearer token embedded in x.com's web client for every visitor (not a secret).
    static let webBearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private static let catalogLifetime: TimeInterval = 6 * 3600

    private let log = Logger(subsystem: "com.ryanvogel.glassx", category: "api")
    private let session: URLSession
    private var cookies: [String: String]
    private let onCookiesChanged: @Sendable ([String: String]) -> Void
    private var catalog: CatalogSnapshot?
    private var catalogTask: Task<CatalogSnapshot, Error>?
    /// Debug-only logged-out mode used to preview the UI with public data.
    private var guestToken: String?

    func activateGuestSession() async throws {
        var request = URLRequest(url: URL(string: "https://api.x.com/1.1/guest/activate.json")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Self.webBearer)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        guestToken = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["guest_token"] as? String
    }

    init(cookies: [String: String], onCookiesChanged: @escaping @Sendable ([String: String]) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        self.cookies = cookies
        self.onCookiesChanged = onCookiesChanged
    }

    // MARK: - Catalog

    private static var catalogFile: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "GlassX", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "web-client-catalog.json")
    }

    func currentCatalog(forceRefresh: Bool = false) async throws -> CatalogSnapshot {
        if !forceRefresh, let catalog, Date.now.timeIntervalSince(catalog.createdAt) < Self.catalogLifetime { return catalog }
        if !forceRefresh, catalog == nil,
           let data = try? Data(contentsOf: Self.catalogFile),
           let cached = try? JSONDecoder().decode(CatalogSnapshot.self, from: data),
           Date.now.timeIntervalSince(cached.createdAt) < Self.catalogLifetime {
            catalog = cached
            return cached
        }
        if let catalogTask { return try await catalogTask.value }

        let task = Task { () throws -> CatalogSnapshot in
            try await CatalogBuilder.build { url in try await self.fetchText(url) }
        }
        catalogTask = task
        defer { catalogTask = nil }
        do {
            let snapshot = try await task.value
            catalog = snapshot
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.catalogFile, options: .atomic) }
            log.notice("Catalog built: \(snapshot.operations.count) operations, transaction id \(snapshot.transactionAnimationKey == nil ? "unavailable" : "ready", privacy: .public)")
            return snapshot
        } catch {
            log.error("Catalog build failed: \(error.localizedDescription, privacy: .public)")
            if let catalog { return catalog }
            let fallback = CatalogSnapshot.fallback
            catalog = fallback
            return fallback
        }
    }

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if url.host() == "x.com" { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if url.host() == "x.com" { absorbCookies(from: http) }
            guard (200..<300).contains(http.statusCode) else { throw XError.http(http.statusCode, url.absoluteString) }
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Requests

    private var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    private func absorbCookies(from response: HTTPURLResponse) {
        guard let fields = response.allHeaderFields as? [String: String], let url = response.url else { return }
        let updated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !updated.isEmpty else { return }
        var changed = false
        for cookie in updated where cookie.domain.hasSuffix("x.com") {
            if let expires = cookie.expiresDate, expires < .now {
                changed = cookies.removeValue(forKey: cookie.name) != nil || changed
            } else if cookies[cookie.name] != cookie.value {
                cookies[cookie.name] = cookie.value
                changed = true
            }
        }
        if changed { onCookiesChanged(cookies) }
    }

    private func apiRequest(url: URL, method: String, body: Data?, transactionPath: String, generator: TransactionIDGenerator?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(Self.webBearer)", forHTTPHeaderField: "Authorization")
        request.setValue(cookies["ct0"] ?? "", forHTTPHeaderField: "x-csrf-token")
        request.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
        request.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
        request.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://x.com", forHTTPHeaderField: "Origin")
        request.setValue("https://x.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let guestToken {
            request.setValue(guestToken, forHTTPHeaderField: "x-guest-token")
            request.setValue(nil, forHTTPHeaderField: "x-twitter-auth-type")
            request.setValue(nil, forHTTPHeaderField: "x-csrf-token")
        }
        if let generator {
            request.setValue(generator.generate(method: method, path: transactionPath), forHTTPHeaderField: "x-client-transaction-id")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Any, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XError.http(0, "No response") }
        absorbCookies(from: http)
        let json = try? JSONSerialization.jsonObject(with: data)
        switch http.statusCode {
        case 200..<300:
            return (json ?? [:], http.statusCode)
        case 401:
            throw XError.unauthorized
        case 429:
            let reset = (http.value(forHTTPHeaderField: "x-rate-limit-reset")).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            throw XError.rateLimited(resetAt: reset)
        default:
            let message = Self.errorMessages(json).first ?? String(decoding: data.prefix(300), as: UTF8.self)
            if http.statusCode == 403, message.localizedCaseInsensitiveContains("authenticat") || message.contains("(32)") {
                throw XError.unauthorized
            }
            return (json ?? ["__status": http.statusCode, "__message": message], http.statusCode)
        }
    }

    private static func errorMessages(_ json: Any?) -> [String] {
        ((json as? [String: Any])?["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    }

    /// Runs a GraphQL operation with variables, retrying once with a fresh catalog when X has
    /// rotated query IDs (404) or added required feature flags (400).
    func graphQL(_ operation: String, variables: [String: JSONValue], usePOST: Bool? = nil) async throws -> Any {
        var extraFeatures: [String: JSONValue] = [:]
        var refreshed = false
        var forceRefresh = false
        for _ in 0..<3 {
            let catalog = try await currentCatalog(forceRefresh: forceRefresh)
            forceRefresh = false
            guard let op = catalog.operations[operation] else {
                if !refreshed { refreshed = true; forceRefresh = true; continue }
                throw XError.missingOperation(operation)
            }

            var features: [String: JSONValue] = [:]
            for name in op.featureSwitches { features[name] = catalog.featureValues[name] ?? false }
            features.merge(extraFeatures) { $1 }
            var toggles: [String: JSONValue] = [:]
            for name in op.fieldToggles { toggles[name] = false }

            let path = "/i/api/graphql/\(op.queryId)/\(operation)"
            let isPOST = usePOST ?? (op.type == "mutation")
            if Self.dryRun, op.type == "mutation", operation != "CreateTweet" {
                log.notice("DRY RUN \(operation, privacy: .public) \(JSONValue.object(variables).encodedString(), privacy: .public)")
                return ["data": [String: Any]()]
            }
            let request: URLRequest
            if isPOST {
                var body: [String: JSONValue] = ["variables": .object(variables), "queryId": .string(op.queryId)]
                if !features.isEmpty { body["features"] = .object(features) }
                if !toggles.isEmpty { body["fieldToggles"] = .object(toggles) }
                request = apiRequest(url: URL(string: "https://x.com\(path)")!, method: "POST",
                                     body: Data(JSONValue.object(body).encodedString().utf8),
                                     transactionPath: path, generator: catalog.transactionGenerator)
            } else {
                var components = URLComponents(string: "https://x.com\(path)")!
                var items = [URLQueryItem(name: "variables", value: JSONValue.object(variables).encodedString())]
                if !features.isEmpty { items.append(URLQueryItem(name: "features", value: JSONValue.object(features).encodedString())) }
                if !toggles.isEmpty { items.append(URLQueryItem(name: "fieldToggles", value: JSONValue.object(toggles).encodedString())) }
                components.queryItems = items
                components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                request = apiRequest(url: components.url!, method: "GET", body: nil,
                                     transactionPath: path, generator: catalog.transactionGenerator)
            }

            let started = Date.now
            let (json, status) = try await perform(request)
            log.notice("\(operation, privacy: .public) → HTTP \(status) in \(Int(Date.now.timeIntervalSince(started) * 1000))ms")
            if (200..<300).contains(status) {
                let object = json as? [String: Any]
                if object?["data"] == nil, let message = Self.errorMessages(json).first { throw XError.api(message) }
                return json
            }

            let message = Self.errorMessages(json).first ?? ((json as? [String: Any])?["__message"] as? String ?? "")
            log.error("\(operation, privacy: .public) failed: HTTP \(status) \(message, privacy: .public)")
            if status == 400, let range = message.range(of: "cannot be null:") {
                for name in message[range.upperBound...].split(separator: ",") {
                    extraFeatures[name.trimmingCharacters(in: .whitespaces)] = false
                }
                continue
            }
            if (status == 404 || status == 400), !refreshed {
                refreshed = true
                forceRefresh = true
                continue
            }
            throw XError.http(status, message)
        }
        throw XError.api("\(operation) failed after retries")
    }

    func rest(_ path: String) async throws -> Any {
        let request = apiRequest(url: URL(string: "https://x.com\(path)")!, method: "GET", body: nil,
                                 transactionPath: URL(string: "https://x.com\(path)")!.path(),
                                 generator: catalog?.transactionGenerator)
        let (json, status) = try await perform(request)
        guard (200..<300).contains(status) else { throw XError.http(status, (json as? [String: Any])?["__message"] as? String ?? "") }
        return json
    }

    /// v1.1 REST POST with a form body (follow, mute, block use these on x.com).
    func restPost(_ path: String, form: [String: String]) async throws -> Any {
        if Self.dryRun {
            log.notice("DRY RUN POST \(path, privacy: .public) \(form.description, privacy: .public)")
            return [String: Any]()
        }
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        let url = URL(string: "https://x.com\(path)")!
        var request = apiRequest(url: url, method: "POST", body: Data((components.percentEncodedQuery ?? "").utf8),
                                 transactionPath: url.path(), generator: catalog?.transactionGenerator)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (json, status) = try await perform(request)
        guard (200..<300).contains(status) else {
            throw XError.http(status, Self.errorMessages(json).first ?? ((json as? [String: Any])?["__message"] as? String ?? ""))
        }
        return json
    }

    // MARK: - Endpoints

    func viewer() async throws -> XUser {
        _ = try await currentCatalog()
        let settings = try await rest("/i/api/1.1/account/settings.json") as? [String: Any]
        guard let screenName = settings?["screen_name"] as? String else { throw XError.unauthorized }
        return try await user(screenName: screenName)
    }

    func user(screenName: String) async throws -> XUser {
        let json = try await graphQL("UserByScreenName", variables: [
            "screen_name": .string(screenName), "withGrokTranslatedBio": false,
        ])
        guard let result = (((json as? [String: Any])?["data"] as? [String: Any])?["user"] as? [String: Any])?["result"] as? [String: Any],
              let user = TimelineParser.user(from: result)
        else { throw XError.api("Couldn't find @\(screenName).") }
        return user
    }

    func homeTimeline(following: Bool, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "count": 20, "includePromotedContent": false, "latestControlAvailable": true,
            "requestContext": cursor == nil ? "launch" : "ptr", "withCommunity": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        if !following { variables["seenTweetIds"] = [] }
        let json = try await graphQL(following ? "HomeLatestTimeline" : "HomeTimeline", variables: variables, usePOST: true)
        return TimelineParser.page(from: json)
    }

    func tweetDetail(id: String, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "focalTweetId": .string(id), "with_rux_injections": false, "rankingMode": "Relevance",
            "includePromotedContent": false, "withCommunity": true, "withQuickPromoteEligibilityTweetFields": true,
            "withBirdwatchNotes": true, "withVoice": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor); variables["referrer"] = "tweet" }
        return TimelineParser.page(from: try await graphQL("TweetDetail", variables: variables))
    }

    func userTweets(userID: String, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "userId": .string(userID), "count": 20, "includePromotedContent": false,
            "withQuickPromoteEligibilityTweetFields": true, "withVoice": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("UserTweets", variables: variables))
    }

    func userReplies(userID: String, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "userId": .string(userID), "count": 20, "includePromotedContent": false, "withCommunity": true, "withVoice": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("UserTweetsAndReplies", variables: variables))
    }

    func userMedia(userID: String, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "userId": .string(userID), "count": 20, "includePromotedContent": false,
            "withClientEventToken": false, "withBirdwatchNotes": false, "withVoice": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("UserMedia", variables: variables))
    }

    func likes(userID: String, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "userId": .string(userID), "count": 20, "includePromotedContent": false,
            "withClientEventToken": false, "withBirdwatchNotes": false, "withVoice": true,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("Likes", variables: variables))
    }

    func deleteTweet(id: String) async throws {
        _ = try await graphQL("DeleteTweet", variables: ["tweet_id": .string(id), "dark_request": false])
    }

    func setPinned(_ pinned: Bool, tweetID: String) async throws {
        _ = try await graphQL(pinned ? "PinTweet" : "UnpinTweet", variables: ["tweet_id": .string(tweetID)])
    }

    func setFollowing(_ follow: Bool, userID: String) async throws {
        _ = try await restPost(follow ? "/i/api/1.1/friendships/create.json" : "/i/api/1.1/friendships/destroy.json", form: ["user_id": userID])
    }

    func setMuted(_ muted: Bool, userID: String) async throws {
        _ = try await restPost(muted ? "/i/api/1.1/mutes/users/create.json" : "/i/api/1.1/mutes/users/destroy.json", form: ["user_id": userID])
    }

    func setBlocked(_ blocked: Bool, userID: String) async throws {
        _ = try await restPost(blocked ? "/i/api/1.1/blocks/create.json" : "/i/api/1.1/blocks/destroy.json", form: ["user_id": userID])
    }

    func search(_ query: String, latest: Bool, cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = [
            "rawQuery": .string(query), "count": 20, "querySource": "typed_query", "product": latest ? "Latest" : "Top",
            "withGrokTranslatedBio": false,
        ]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("SearchTimeline", variables: variables))
    }

    func bookmarks(cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = ["count": 20, "includePromotedContent": false]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("Bookmarks", variables: variables))
    }

    func notifications(type: String = "All", cursor: String?) async throws -> FeedPage {
        var variables: [String: JSONValue] = ["timeline_type": .string(type), "count": 20]
        if let cursor { variables["cursor"] = .string(cursor) }
        return TimelineParser.page(from: try await graphQL("NotificationsTimeline", variables: variables))
    }

    func setLiked(_ liked: Bool, tweetID: String) async throws {
        _ = try await graphQL(liked ? "FavoriteTweet" : "UnfavoriteTweet", variables: ["tweet_id": .string(tweetID)])
    }

    func setReposted(_ reposted: Bool, tweetID: String) async throws {
        if reposted {
            _ = try await graphQL("CreateRetweet", variables: ["tweet_id": .string(tweetID), "dark_request": false])
        } else {
            _ = try await graphQL("DeleteRetweet", variables: ["source_tweet_id": .string(tweetID), "dark_request": false])
        }
    }

    func setBookmarked(_ bookmarked: Bool, tweetID: String) async throws {
        _ = try await graphQL(bookmarked ? "CreateBookmark" : "DeleteBookmark", variables: ["tweet_id": .string(tweetID)])
    }

    // MARK: - Media upload

    enum MediaCategory: String, Sendable {
        case image = "tweet_image", gif = "tweet_gif", video = "tweet_video"
    }

    /// Chunked upload to upload.x.com (INIT → APPEND… → FINALIZE → STATUS), the flow x.com uses.
    /// Returns the media ID to attach to a post.
    /// Debug: log posts instead of sending them (`--dry-run-posts`).
    nonisolated(unsafe) static var dryRun = false
    nonisolated(unsafe) static var dryRunAllowsUpload = false

    func uploadMedia(_ data: Data, mimeType: String, category: MediaCategory,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        if Self.dryRun, !Self.dryRunAllowsUpload {
            log.notice("DRY RUN upload \(data.count) bytes \(mimeType, privacy: .public)")
            progress?(1)
            return "dry-run-media"
        }
        let base = "https://upload.x.com/i/media/upload.json"
        func url(_ items: [String: String]) -> URL {
            var components = URLComponents(string: base)!
            components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.url!
        }

        let initJSON = try await uploadRequest(url(["command": "INIT", "total_bytes": "\(data.count)",
                                                    "media_type": mimeType, "media_category": category.rawValue]))
        guard let mediaID = (initJSON["media_id_string"] as? String) ?? (initJSON["media_id"] as? Int).map(String.init) else {
            throw XError.api("X didn't accept the upload.")
        }

        let chunkSize = 4 << 20
        var offset = 0, segment = 0
        while offset < data.count {
            let chunk = data[offset..<min(offset + chunkSize, data.count)]
            let boundary = "----GlassX\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(chunk)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            _ = try await uploadRequest(url(["command": "APPEND", "media_id": mediaID, "segment_index": "\(segment)"]),
                                        body: body, contentType: "multipart/form-data; boundary=\(boundary)")
            offset += chunk.count
            segment += 1
            progress?(Double(offset) / Double(data.count) * (category == .image ? 1 : 0.8))
        }

        var info = try await uploadRequest(url(["command": "FINALIZE", "media_id": mediaID]))["processing_info"] as? [String: Any]
        // Video and GIF are transcoded server-side; wait until X reports success.
        while let state = info?["state"] as? String, state == "pending" || state == "in_progress" {
            if let percent = info?["progress_percent"] as? Int { progress?(0.8 + Double(percent) / 500) }
            let wait = min(max(info?["check_after_secs"] as? Int ?? 1, 1), 10)
            try await Task.sleep(for: .seconds(wait))
            info = try await uploadRequest(url(["command": "STATUS", "media_id": mediaID]), method: "GET")["processing_info"] as? [String: Any]
        }
        if let state = info?["state"] as? String, state == "failed" {
            let message = (info?["error"] as? [String: Any])?["message"] as? String
            throw XError.api(message ?? "X couldn't process this media.")
        }
        progress?(1)
        return mediaID
    }

    private func uploadRequest(_ url: URL, method: String = "POST", body: Data? = nil, contentType: String? = nil) async throws -> [String: Any] {
        var request = apiRequest(url: url, method: method, body: body, transactionPath: url.path(), generator: nil)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if body == nil { request.setValue(nil, forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XError.http(0, "No response") }
        absorbCookies(from: http)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw XError.unauthorized }
            let json = try? JSONSerialization.jsonObject(with: data)
            throw XError.http(http.statusCode, Self.errorMessages(json).first ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    nonisolated(unsafe) private static var dryRunCounter = 0

    /// Creates a post and returns its ID (needed to chain thread replies).
    @discardableResult
    func post(text: String, replyTo: String?, mediaIDs: [String] = [], quoteURL: URL? = nil) async throws -> String {
        if Self.dryRun {
            try? await Task.sleep(for: .seconds(1.1))   // feels like a real round trip
            Self.dryRunCounter += 1
            log.notice("DRY RUN post \"\(text, privacy: .public)\" media=\(mediaIDs.count) reply=\(replyTo ?? "-", privacy: .public) quote=\(quoteURL?.absoluteString ?? "-", privacy: .public)")
            return "dry-run-\(Self.dryRunCounter)"
        }
        let entities: [JSONValue] = mediaIDs.map { ["media_id": .string($0), "tagged_users": []] }
        var variables: [String: JSONValue] = [
            "tweet_text": .string(text), "dark_request": false,
            "media": ["media_entities": .array(entities), "possibly_sensitive": false],
            "semantic_annotation_ids": [], "disallowed_reply_options": nil,
        ]
        if let replyTo { variables["reply"] = ["in_reply_to_tweet_id": .string(replyTo), "exclude_reply_user_ids": []] }
        if let quoteURL { variables["attachment_url"] = .string(quoteURL.absoluteString) }
        let json = try await graphQL("CreateTweet", variables: variables)
        let result = ((((json as? [String: Any])?["data"] as? [String: Any])?["create_tweet"] as? [String: Any])?["tweet_results"] as? [String: Any])?["result"] as? [String: Any]
        let unwrapped = result.flatMap(TimelineParser.unwrapTweet)
        guard let id = (unwrapped?["rest_id"] as? String) ?? ((unwrapped?["legacy"] as? [String: Any])?["id_str"] as? String) else {
            throw XError.api("X didn't confirm the post.")
        }
        return id
    }
}
