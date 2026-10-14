import SwiftUI

/// A paginated feed backed by one of the client's timeline endpoints.
@MainActor @Observable
final class FeedModel {
    typealias Loader = @Sendable (XClient, String?) async throws -> FeedPage

    var items: [FeedItem] = []
    var isLoading = false
    var hasLoaded = false
    var error: String?
    private(set) var reachedEnd = false
    private var cursor: String?
    private var loadedToken: UUID?
    private let loader: Loader

    init(loader: @escaping Loader) { self.loader = loader }

    func reset() {
        items = []
        cursor = nil
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
            withAnimation(.smooth) {
                items = page.items
                hasLoaded = true
            }
            cursor = page.bottomCursor
            reachedEnd = page.bottomCursor == nil || page.items.isEmpty
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case XError.unauthorized = error { model.report(error) }
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    func loadMore(_ model: AppModel) async {
        guard !isLoading, !reachedEnd, let cursor, let client = model.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await loader(client, cursor)
            let known = Set(items.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                ForEach(feed.items) { item in
                    FeedItemView(item: item)
                    if !item.connectsBelow { Hairline() }
                }
                footer
            }
            .scrollTargetLayout()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
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
        .onAppear { feed.loadIfNeeded(model) }
        .onChange(of: model.refreshToken) { feed.loadIfNeeded(model) }
    }

    @ViewBuilder private var footer: some View {
        if feed.hasLoaded, !feed.items.isEmpty, !feed.reachedEnd {
            ProgressView()
                .padding(24)
                .frame(maxWidth: .infinity)
                .onAppear { Task { await feed.loadMore(model) } }
        } else {
            Color.clear.frame(height: 40)
        }
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
