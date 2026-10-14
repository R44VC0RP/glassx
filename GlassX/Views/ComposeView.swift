import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    var target: ComposeTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attachments: [PostAttachment] = []
    @State private var isPosting = false
    @State private var progress: Double?
    @State private var showingImporter = false
    @State private var isDropTargeted = false
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    private let limit = 280
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPost: Bool { (!trimmed.isEmpty || !attachments.isEmpty) && !isPosting }
    /// Up to four photos, or a single GIF or video, like x.com.
    private var canAttachMore: Bool { attachments.count < 4 && !attachments.contains(where: \.isVideoLike) }
    private var willQueue: Bool { model.scheduler.wouldQueue(isReply: target.replyTo != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reply = target.replyTo {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Avatar(user: reply.author, size: 40)
                        Capsule().fill(Color.xLine).frame(width: 2).frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        AuthorLine(user: reply.author, date: reply.createdAt)
                        TweetText(tweet: reply, size: 14, lineLimit: 6)
                        Text("Replying to ").foregroundStyle(Color.xGray) + Text("@\(reply.author.screenName)").foregroundStyle(Color.xBlue)
                    }
                    .font(.system(size: 13))
                    .padding(.bottom, 12)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Avatar(user: model.viewer, size: 40)
                VStack(alignment: .leading, spacing: 12) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(target.replyTo == nil ? "What's happening?" : "Post your reply")
                                .font(.system(size: 19))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.system(size: 19))
                            .scrollIndicators(.never)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .frame(minHeight: attachments.isEmpty ? 120 : 64)
                            .padding(.leading, -5)
                    }
                    if !attachments.isEmpty { attachmentStrip }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.xBlue, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.compactMap { try? PostAttachment.load(from: $0) })
            return true
        } isTargeted: { isDropTargeted = $0 }
        .padding(.top, 18)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .padding(14)
            .accessibilityLabel("Close")
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image, .movie, .gif], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var loaded: [PostAttachment] = []
            for url in urls {
                do { loaded.append(try PostAttachment.load(from: url)) } catch { model.report(error) }
            }
            add(loaded)
        }
        .onAppear {
            focused = true
            installPasteMonitor()
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                            .frame(width: attachments.count == 1 ? 240 : 112, height: attachments.count == 1 ? 160 : 112)
                            .overlay {
                                if let preview = attachment.preview {
                                    Image(nsImage: preview).resizable().scaledToFill()
                                } else {
                                    Color.xPlaceholder
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.xLine, lineWidth: 1))
                            .overlay(alignment: .bottomLeading) {
                                if attachment.isVideoLike {
                                    Text(attachment.category == .gif ? "GIF" : "Video")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
                                        .padding(6)
                                }
                            }
                        Button {
                            withAnimation(.snappy) { attachments.removeAll { $0.id == attachment.id } }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .circle)
                        .padding(6)
                        .accessibilityLabel("Remove attachment")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canAttachMore ? Color.xBlue : Color.xGray)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAttachMore || isPosting)
            .help("Add photos or a video (or paste / drop them)")
            .accessibilityLabel("Add media")

            Spacer()
            if willQueue, !isPosting {
                Label("Next slot \(model.scheduler.nextSlot().formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.xGray)
                    .help("Space out my posts is on — this post will be queued")
            }
            CharacterRing(count: trimmed.count, limit: limit)
            Button {
                post()
            } label: {
                Group {
                    if let progress, isPosting {
                        Text("Uploading \(Int(progress * 100))%").monospacedDigit()
                    } else if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(willQueue ? "Schedule" : (target.replyTo == nil ? "Post" : "Reply"))
                    }
                }
                .fontWeight(.semibold)
                .frame(minWidth: 52)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canPost)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func add(_ new: [PostAttachment]) {
        guard !new.isEmpty else { return }
        withAnimation(.snappy) {
            for attachment in new {
                if attachment.isVideoLike {
                    // A GIF or video replaces everything else.
                    attachments = [attachment]
                } else if canAttachMore {
                    attachments.append(attachment)
                }
            }
        }
    }

    /// ⌘V with an image or media file on the clipboard attaches it instead of pasting text.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let pasted = PostAttachment.fromPasteboard(.general)
            else { return event }
            add(pasted)
            return nil
        }
    }

    private func post() {
        guard canPost else { return }
        isPosting = true
        let hasMedia = !attachments.isEmpty
        Task {
            let outcome = await model.post(text: trimmed, replyTo: target.replyTo, attachments: attachments) { value in
                Task { @MainActor in if hasMedia { progress = value } }
            }
            isPosting = false
            progress = nil
            if case .failed = outcome { return }
            dismiss()
        }
    }
}

/// X's character-count ring; turns amber near the limit and red past it.
private struct CharacterRing: View {
    var count: Int
    var limit: Int

    var body: some View {
        let progress = min(Double(count) / Double(limit), 1)
        let remaining = limit - count
        ZStack {
            Circle().stroke(Color.xLine, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(remaining < 0 ? Color.red : remaining <= 20 ? .orange : .xBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if remaining <= 20 {
                Text("\(remaining)").font(.caption2.monospacedDigit()).foregroundStyle(remaining < 0 ? .red : .secondary)
            }
        }
        .frame(width: 26, height: 26)
        .animation(.snappy, value: count)
        .opacity(count == 0 ? 0 : 1)
        .help(remaining < 0 ? "Over the standard 280 limit (Premium accounts can post longer)" : "\(remaining) characters left")
    }
}
