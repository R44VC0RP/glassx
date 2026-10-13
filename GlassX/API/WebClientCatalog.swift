import Foundation

/// Everything the app learns from x.com's own web client: GraphQL query IDs, the feature flags
/// each operation expects, and the ingredients for `x-client-transaction-id`.
///
/// X rotates query IDs every few weeks, so nothing here is hard-coded except a fallback list.
struct CatalogSnapshot: Codable, Sendable {
    struct Operation: Codable, Sendable {
        var queryId: String
        var type: String
        var featureSwitches: [String]
        var fieldToggles: [String]
    }

    var operations: [String: Operation]
    var featureValues: [String: JSONValue]
    var transactionKeyBytes: [UInt8]?
    var transactionAnimationKey: String?
    var createdAt: Date

    var transactionGenerator: TransactionIDGenerator? {
        guard let bytes = transactionKeyBytes, let key = transactionAnimationKey else { return nil }
        return TransactionIDGenerator(keyBytes: bytes, animationKey: key)
    }

    /// Last-known IDs (October 2026), used only if the live catalog cannot be built.
    static let fallback = CatalogSnapshot(
        operations: [
            "TweetDetail": .init(queryId: "3BlMtudy4N-d78ch7zTLZQ", type: "query", featureSwitches: [], fieldToggles: []),
            "CreateTweet": .init(queryId: "wR5Z_lEibLvkew3tF9w-Sg", type: "mutation", featureSwitches: [], fieldToggles: []),
            "FavoriteTweet": .init(queryId: "lI07N6Otwv1PhnEgXILM7A", type: "mutation", featureSwitches: [], fieldToggles: []),
            "UnfavoriteTweet": .init(queryId: "ZYKSe-w7KEslx3JhSIk5LA", type: "mutation", featureSwitches: [], fieldToggles: []),
            "CreateRetweet": .init(queryId: "mbRO74GrOvSfRcJnlMapnQ", type: "mutation", featureSwitches: [], fieldToggles: []),
            "DeleteRetweet": .init(queryId: "ZyZigVsNiFO6v1dEks1eWg", type: "mutation", featureSwitches: [], fieldToggles: []),
            "CreateBookmark": .init(queryId: "aoDbu3RHznuiSkQ9aNM67Q", type: "mutation", featureSwitches: [], fieldToggles: []),
            "DeleteBookmark": .init(queryId: "Wlmlj2-xzyS1GN3a6cj-mQ", type: "mutation", featureSwitches: [], fieldToggles: []),
            "SearchTimeline": .init(queryId: "irezafrnzav4Ulf1vDkEBg", type: "query", featureSwitches: [], fieldToggles: []),
            "UserByScreenName": .init(queryId: "AMIBMjtxEEATh4z8V9GtRg", type: "query", featureSwitches: [], fieldToggles: []),
            "UserTweets": .init(queryId: "7_KBXBpG0zBPRN6UCIV0-w", type: "query", featureSwitches: [], fieldToggles: []),
        ],
        featureValues: [:],
        transactionKeyBytes: nil,
        transactionAnimationKey: nil,
        createdAt: .distantPast
    )
}

extension TransactionIDGenerator {
    init(keyBytes: [UInt8], animationKey: String) {
        self.keyBytes = keyBytes
        self.animationKey = animationKey
    }
}

enum CatalogBuilder {
    static let webClientBase = "https://abs.twimg.com/responsive-web/client-web/"
    /// Chunks that hold the operations the app uses but that are not in main.js.
    static let chunkKeywords = ["bundle.HomeTimeline", "bundle.Bookmarks", "bundle.Notifications"]

    static func build(fetch: @escaping @Sendable (URL) async throws -> String) async throws -> CatalogSnapshot {
        let html = try await fetch(URL(string: "https://x.com/i/jf/")!)
        let chunks = chunkURLs(in: html)

        var sources: [String] = []
        if let main = TransactionIDGenerator.firstMatch(#"(https://abs\.twimg\.com/responsive-web/client-web/main\.[a-z0-9]+\.js)"#, in: html),
           let url = URL(string: main) {
            sources.append(try await fetch(url))
        }

        let wanted = chunks.filter { name, _ in chunkKeywords.contains { name.contains($0) } }
        sources += await withTaskGroup(of: String?.self) { group in
            for (_, url) in wanted { group.addTask { try? await fetch(url) } }
            var results: [String] = []
            for await source in group { if let source { results.append(source) } }
            return results
        }

        var operations: [String: CatalogSnapshot.Operation] = [:]
        for source in sources {
            for (name, op) in parseOperations(source) where operations[name] == nil {
                operations[name] = op
            }
        }
        guard operations["HomeTimeline"] != nil || operations["TweetDetail"] != nil else {
            throw XError.catalog("Could not find X's API operations in the web client")
        }

        var generator: TransactionIDGenerator?
        if let ondemand = chunks.first(where: { $0.name == "ondemand.s" })?.url,
           let js = try? await fetch(ondemand) {
            generator = try? TransactionIDGenerator(homeHTML: html, ondemandJS: js)
        }

        return CatalogSnapshot(
            operations: operations,
            featureValues: featureValues(in: html),
            transactionKeyBytes: generator?.keyBytes,
            transactionAnimationKey: generator?.animationKey,
            createdAt: .now
        )
    }

    /// Resolves webpack chunk names to URLs using the runtime's `{id:"name"}` and `"."+({id:"hash"})` maps.
    static func chunkURLs(in html: String) -> [(name: String, url: URL)] {
        guard let anchor = html.range(of: "\"ondemand.s\"") else { return [] }
        guard let open = html.range(of: "({", options: .backwards, range: html.startIndex..<anchor.lowerBound),
              let close = html.range(of: "})", range: anchor.upperBound..<html.endIndex)
        else { return [] }
        let names = pairs(in: String(html[open.upperBound..<close.lowerBound]))

        let rest = String(html[close.upperBound...])
        guard let hashStart = rest.range(of: "\".\"+({"),
              let hashEnd = rest.range(of: "})", range: hashStart.upperBound..<rest.endIndex)
        else { return [] }
        let hashes = pairs(in: String(rest[hashStart.upperBound..<hashEnd.lowerBound]))

        return names.compactMap { id, name in
            guard let hash = hashes[id], let url = URL(string: "\(webClientBase)\(name).\(hash)a.js") else { return nil }
            return (name, url)
        }
    }

    private static func pairs(in text: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+):"([^"]+)""#) else { return [:] }
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        return result
    }

    static func parseOperations(_ source: String) -> [String: CatalogSnapshot.Operation] {
        let pattern = #"queryId:"([^"]+)",operationName:"([^"]+)",operationType:"(\w+)",metadata:\{featureSwitches:\[([^\]]*)\],fieldToggles:\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = source as NSString
        var result: [String: CatalogSnapshot.Operation] = [:]
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String { ns.substring(with: match.range(at: i)) }
            func list(_ s: String) -> [String] {
                s.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }.filter { !$0.isEmpty }
            }
            result[group(2)] = .init(queryId: group(1), type: group(3), featureSwitches: list(group(4)), fieldToggles: list(group(5)))
        }
        return result
    }

    /// Feature flag values from `window.__INITIAL_STATE__.featureSwitch` (user config overrides defaults).
    static func featureValues(in html: String) -> [String: JSONValue] {
        guard let start = html.range(of: "\"featureSwitch\":"),
              let object = balancedObject(in: html, from: start.upperBound),
              let data = object.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = decoded
        else { return [:] }

        var values: [String: JSONValue] = [:]
        for section in [root["defaultConfig"], root["user"]?["config"]] {
            guard case .object(let config)? = section else { continue }
            for (name, entry) in config {
                if let value = entry["value"] { values[name] = value }
            }
        }
        return values
    }

    /// Returns the JSON object starting at `index`, matching braces while respecting strings.
    private static func balancedObject(in text: String, from index: String.Index) -> String? {
        let utf8 = Array(text.utf8[index...].prefix(4_000_000))
        guard utf8.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for (offset, byte) in utf8.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return String(decoding: utf8[0...offset], as: UTF8.self) }
            default: break
            }
        }
        return nil
    }
}
