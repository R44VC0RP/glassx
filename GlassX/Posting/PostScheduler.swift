import Foundation
import Observation
import os
import SwiftUI

/// "Space out my posts": posts written in a burst are queued and sent one at a time, at least
/// `gap` apart (with a little jitter so it reads naturally), only inside the active hours.
///
/// X's web client has no server-side scheduling any more, so the queue lives on this Mac and
/// posts go out while GlassX is running. Anything that came due while the app was closed is
/// re-spaced from the moment it opens again rather than sent in a burst.
@MainActor @Observable
final class PostScheduler {
    struct QueuedPost: Codable, Identifiable, Hashable {
        struct StoredMedia: Codable, Hashable {
            var fileName: String
            var mimeType: String
            var category: String
        }

        var id = UUID()
        var text: String
        var replyToID: String?
        var replyToHandle: String?
        var media: [StoredMedia] = []
        var sendAt: Date
        var createdAt = Date.now
        var attempts = 0
        var lastError: String?
    }

    struct Settings {
        @AppStorage("pacing.enabled") var enabled = false
        @AppStorage("pacing.gapMinutes") var gapMinutes = 60
        @AppStorage("pacing.startHour") var startHour = 8
        @AppStorage("pacing.endHour") var endHour = 22
        @AppStorage("pacing.repliesImmediately") var repliesImmediately = true
    }

    private(set) var queue: [QueuedPost] = []
    private(set) var sendingID: UUID?
    private var settings = Settings()
    @ObservationIgnored @AppStorage("pacing.lastSentAt") private var lastSentAt: Double = 0
    private let log = Logger(subsystem: "com.ryanvogel.glassx", category: "pacing")
    private var loop: Task<Void, Never>?

    private static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "GlassX/Queue", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var queueFile: URL { directory.appending(path: "queue.json") }

    init() {
        if let data = try? Data(contentsOf: Self.queueFile),
           let saved = try? JSONDecoder().decode([QueuedPost].self, from: data) {
            queue = saved.sorted { $0.sendAt < $1.sendAt }
        }
    }

    var isEnabled: Bool { settings.enabled }
    private var gap: TimeInterval { TimeInterval(max(settings.gapMinutes, 1) * 60) }

    /// Whether a post written now would be queued instead of sent.
    func wouldQueue(isReply: Bool) -> Bool {
        guard settings.enabled, !(isReply && settings.repliesImmediately) else { return false }
        return nextSlot() > Date.now.addingTimeInterval(5)
    }

    /// When the next queued post would go out.
    func nextSlot(now: Date = .now) -> Date {
        let lastSent = Date(timeIntervalSince1970: lastSentAt)
        let latest = max(lastSent, queue.map(\.sendAt).max() ?? .distantPast)
        var slot = now
        if latest.addingTimeInterval(gap) > now {
            slot = latest.addingTimeInterval(gap * Double.random(in: 0.85...1.15))
        }
        return clampToActiveHours(slot)
    }

    private func clampToActiveHours(_ date: Date) -> Date {
        let start = settings.startHour, end = settings.endHour
        guard start != end else { return date }
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let inside = start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
        if inside { return date }
        var next = calendar.date(bySettingHour: start, minute: 0, second: 0, of: date) ?? date
        if next <= date { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
        return next.addingTimeInterval(Double.random(in: 0...600))
    }

    // MARK: Queue

    @discardableResult
    func enqueue(text: String, replyTo: XTweet?, attachments: [PostAttachment]) throws -> QueuedPost {
        let id = UUID()
        let folder = Self.directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var media: [QueuedPost.StoredMedia] = []
        for (index, attachment) in attachments.enumerated() {
            let name = "\(index).\(attachment.fileExtension)"
            try attachment.data.write(to: folder.appending(path: name))
            media.append(.init(fileName: name, mimeType: attachment.mimeType, category: attachment.category.rawValue))
        }
        let post = QueuedPost(id: id, text: text, replyToID: replyTo?.id, replyToHandle: replyTo?.author.screenName,
                              media: media, sendAt: nextSlot())
        queue.append(post)
        queue.sort { $0.sendAt < $1.sendAt }
        save()
        log.notice("Queued post for \(post.sendAt.formatted(date: .omitted, time: .shortened), privacy: .public) (\(self.queue.count) waiting)")
        return post
    }

    func remove(_ post: QueuedPost) {
        queue.removeAll { $0.id == post.id }
        try? FileManager.default.removeItem(at: Self.directory.appending(path: post.id.uuidString))
        save()
    }

    func clearAll() {
        for post in queue { try? FileManager.default.removeItem(at: Self.directory.appending(path: post.id.uuidString)) }
        queue = []
        save()
    }

    func sendNow(_ post: QueuedPost) {
        guard let index = queue.firstIndex(where: { $0.id == post.id }) else { return }
        queue[index].sendAt = .now
        queue.sort { $0.sendAt < $1.sendAt }
        save()
        kick()
    }

    func recordSent() { lastSentAt = Date.now.timeIntervalSince1970 }

    private func save() {
        if let data = try? JSONEncoder().encode(queue) { try? data.write(to: Self.queueFile, options: .atomic) }
    }

    // MARK: Sending

    private weak var model: AppModel?

    func start(model: AppModel) {
        self.model = model
        respaceOverdue()
        kick()
    }

    /// Posts that came due while GlassX was closed go out one by one from now, not all at once.
    private func respaceOverdue() {
        var previous: Date?
        for index in queue.indices {
            if let previous, queue[index].sendAt < previous.addingTimeInterval(gap * 0.85) {
                queue[index].sendAt = clampToActiveHours(previous.addingTimeInterval(gap * Double.random(in: 0.85...1.15)))
            }
            previous = queue[index].sendAt
        }
        save()
    }

    private func kick() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendDue()
                let next = self.queue.first?.sendAt ?? .distantFuture
                let wait = min(max(next.timeIntervalSinceNow, 5), 60)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func sendDue() async {
        guard sendingID == nil, let model, let client = model.client,
              let post = queue.first, post.sendAt <= .now else { return }
        sendingID = post.id
        defer { sendingID = nil }
        do {
            var mediaIDs: [String] = []
            for item in post.media {
                let data = try Data(contentsOf: Self.directory.appending(path: post.id.uuidString).appending(path: item.fileName))
                mediaIDs.append(try await client.uploadMedia(data, mimeType: item.mimeType,
                                                             category: XClient.MediaCategory(rawValue: item.category) ?? .image))
            }
            try await client.post(text: post.text, replyTo: post.replyToID, mediaIDs: mediaIDs)
            recordSent()
            remove(post)
            respaceOverdue()
            log.notice("Sent queued post (\(self.queue.count) left)")
            model.showNotice("Posted a queued post" + (queue.isEmpty ? "" : " · \(queue.count) more waiting"), symbol: "paperplane.fill")
        } catch {
            guard let index = queue.firstIndex(where: { $0.id == post.id }) else { return }
            queue[index].attempts += 1
            queue[index].lastError = error.localizedDescription
            // Back off: 2, 4, 8… minutes, and stop retrying automatically after 5 attempts.
            queue[index].sendAt = queue[index].attempts >= 5 ? .distantFuture
                : Date.now.addingTimeInterval(Double(1 << queue[index].attempts) * 60)
            queue.sort { $0.sendAt < $1.sendAt }
            save()
            log.error("Queued post failed: \(error.localizedDescription, privacy: .public)")
            model.report(error)
        }
    }
}
