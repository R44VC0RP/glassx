import SwiftUI
import UniformTypeIdentifiers

/// The composer: a chat-style prompt docked at the bottom of the window over a lightly dimmed feed.
///
/// Sending never lets the words leave the card: the card itself closes around them (its rounded
/// mask crops the text as it shrinks) and settles into a status pill. A queued post's pill then
/// flies into the toolbar's queue button.
struct ComposerOverlay: View {
    enum Stage: Equatable { case editing, sending, sent, queued(Date) }

    var target: ComposeTarget
    @Environment(AppModel.self) private var model
    @State private var parts: [ComposerPart] = [ComposerPart()]
    @FocusState private var focusedPart: UUID?
    @State private var hoveredPart: UUID?
    /// Thread send progress: how many parts have gone out.
    @State private var sentParts = 0
    @State private var totalParts = 1
    @State private var stage: Stage = .editing
    @State private var progress: Double?
    @State private var showingImporter = false
    @State private var isDropTargeted = false
    @State private var appeared = false
    @State private var exiting = false
    @State private var shakes = 0
    @State private var inlineError: String?
    @State private var pasteMonitor: Any?

    // Card morph
    @State private var collapsed = false
    @State private var dockVisible = true
    @State private var pillVisible = false
    @State private var dockHeight: CGFloat = 120
    // Exit
    @State private var dropAway = false
    @State private var flight: CGSize = .zero
    @State private var flightScale: CGFloat = 1
    @State private var flightOpacity: Double = 1
    @State private var pillCenter: CGPoint = .zero
    /// Queue exit: the pill folds into a clock circle before hopping to the toolbar.
    @State private var orb = false

    private let limit = 280
    private var editing: Bool { stage == .editing }
    private var activeIndex: Int { parts.firstIndex { $0.id == focusedPart } ?? parts.count - 1 }
    private var postableParts: [ComposerPart] { parts.filter { !$0.isEmpty } }
    private var canPost: Bool { !postableParts.isEmpty && editing }
    private var canAttachMore: Bool { parts[activeIndex].canAttachMore }
    private var willQueue: Bool { model.scheduler.wouldQueue(isReply: target.replyTo != nil) }
    private var shown: Bool { appeared && !exiting }
    private var isThread: Bool { totalParts > 1 }

    var body: some View {
        GeometryReader { geometry in
            let width = min(660, geometry.size.width - 48)
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(shown && !collapsed ? 0.3 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .allowsHitTesting(editing)

                card(width: width)
                    .padding(.bottom, 22)
                    .scaleEffect(flightScale)
                    .offset(flight)
                    .opacity(flightOpacity)
                    .scaleEffect(dropAway ? 0.92 : 1, anchor: .bottom)
                    .offset(y: dropAway ? 18 : 0)
                    .blur(radius: dropAway ? 4 : 0)
                    .opacity(dropAway ? 0 : 1)
                    .scaleEffect(shown ? 1 : (exiting ? 0.96 : 0.94), anchor: .bottom)
                    .offset(y: shown ? 0 : (exiting ? 26 : 40))
                    .blur(radius: shown ? 0 : 6)
                    .opacity(shown ? 1 : 0)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
                        content.offset(x: x)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(-9, duration: 0.05)
                            LinearKeyframe(8, duration: 0.07)
                            LinearKeyframe(-5, duration: 0.07)
                            LinearKeyframe(3, duration: 0.06)
                            SpringKeyframe(0, duration: 0.2)
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            #if DEBUG
            if let i = CommandLine.arguments.firstIndex(of: "--compose-text"), let prefill = CommandLine.arguments[safe: i + 1] {
                parts = prefill.components(separatedBy: "\n---\n").map { ComposerPart(text: $0) }
            }
            #endif
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.08)) { appeared = true }
            focusedPart = parts.last?.id
            installPasteMonitor()
            if let demo = target.demoText { runDemo(demo) }
        }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) } }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.image, .movie, .gif], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var loaded: [PostAttachment] = []
            for url in urls {
                do { loaded.append(try PostAttachment.load(from: url)) } catch { fail(error.localizedDescription) }
            }
            add(loaded)
            focusedPart = parts[safe: activeIndex]?.id
        }
    }

    // MARK: Card

    /// One surface. Expanded it holds the dock; collapsed it shrinks to the pill's size and its
    /// rounded mask crops whatever dock content is still fading out.
    private func card(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: collapsed ? 25 : 28, style: .continuous)
        let collapsedWidth = orb ? 50 : pillWidth
        return ZStack(alignment: .topLeading) {
            dock
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !collapsed { dockHeight = $0 } }
                .opacity(dockVisible ? 1 : 0)
                .blur(radius: dockVisible ? 0 : 3)
                .allowsHitTesting(editing)

            statusPill
                .fixedSize()
                .frame(width: collapsed ? collapsedWidth : width, height: collapsed ? 50 : dockHeight)
                .opacity(pillVisible ? 1 : 0)
                .scaleEffect(pillVisible ? 1 : 0.9)
                .allowsHitTesting(false)
        }
        .frame(width: collapsed ? collapsedWidth : width, height: collapsed ? 50 : dockHeight, alignment: .topLeading)
        .clipShape(shape)
        .composerSurface(shape)
        .overlay {
            if isDropTargeted {
                shape.strokeBorder(Color.xBlue.opacity(0.8), lineWidth: 1.5)
            }
        }
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .global)
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { pillCenter = $0 }
        .animation(.smooth(duration: 0.22), value: parts.map(\.height))
        .animation(.bouncy(duration: 0.35), value: parts.map(\.attachments.count))
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.compactMap { try? PostAttachment.load(from: $0) })
            return true
        } isTargeted: { isDropTargeted = $0 && editing }
    }

    private var dock: some View {
        VStack(spacing: 0) {
            if let reply = target.replyTo { replyChip(reply) }
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                partRow(index: index)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
            }

            HStack(spacing: 8) {
                DockIconButton(symbol: "photo.on.rectangle.angled", enabled: canAttachMore) { showingImporter = true }
                    .help("Add media (⌘O)")
                    .accessibilityLabel("Add media")
                DockIconButton(symbol: "face.smiling", enabled: true) {
                    focusedPart = parts[safe: activeIndex]?.id
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .help("Emoji")
                .accessibilityLabel("Emoji")
                DockIconButton(symbol: "plus.bubble", enabled: parts.count < 25) { addPart() }
                    .help("Add another post to the thread (⇧⌘↩)")
                    .accessibilityLabel("Add to thread")
                Group {
                    if let inlineError {
                        Label(inlineError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                    } else if willQueue {
                        Label("Queues for \(model.scheduler.nextSlot().formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                            .foregroundStyle(Color.xGray)
                    } else if parts.count > 1 {
                        Text("Thread · \(parts.count) posts").foregroundStyle(Color.xGray)
                            .contentTransition(.numericText(value: Double(parts.count)))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, 4)
                .transition(.opacity)
                Spacer()
                CharacterRing(count: parts[safe: activeIndex]?.trimmed.count ?? 0, limit: limit)
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .animation(.smooth, value: inlineError)
            .animation(.smooth, value: parts.count)
        }
        .background {
            Button("", action: { if canAttachMore { showingImporter = true } }).keyboardShortcut("o", modifiers: .command).hidden()
            Button("", action: addPart).keyboardShortcut(.return, modifiers: [.command, .shift]).hidden()
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: parts.map(\.id))
    }

    /// One post of the thread: avatar with a connecting line to the next, its editor, media and
    /// (for the first post) the quoted post.
    private func partRow(index: Int) -> some View {
        let part = parts[index]
        let isLast = index == parts.count - 1
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Avatar(user: model.viewer, size: 32)
                    .opacity(index == 0 || focusedPart == part.id ? 1 : 0.75)
                if !isLast {
                    Capsule().fill(Color.xLine).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 32)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 10) {
                editor(index: index)
                if !part.attachments.isEmpty {
                    attachmentStrip(index: index)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if index == 0, let quote = target.quote { QuotePreview(tweet: quote) }
            }
            .padding(.bottom, isLast ? 0 : 6)

            if parts.count > 1 {
                Button {
                    removePart(at: index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.xGray)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.07)))
                }
                .buttonStyle(PressScaleStyle())
                .opacity(hoveredPart == part.id || focusedPart == part.id ? 1 : 0)
                .help("Remove this post")
                .accessibilityLabel("Remove post \(index + 1)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, index == 0 ? (target.replyTo == nil ? 18 : 12) : 0)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onHover { hoveredPart = $0 ? part.id : (hoveredPart == part.id ? nil : hoveredPart) }
        .animation(.easeOut(duration: 0.15), value: hoveredPart)
    }

    private var sendButton: some View {
        Button(action: post) {
            ZStack {
                Circle().fill(Color.xBlue.opacity(canPost ? 1 : 0.3))
                Image(systemName: willQueue ? "clock" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 34, height: 34)
            .scaleEffect(canPost ? 1 : 0.92)
        }
        .buttonStyle(PressScaleStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canPost)
        .help(willQueue ? "Schedule (⌘↩)" : "Post (⌘↩)")
        .accessibilityLabel(willQueue ? "Schedule" : "Post")
        .animation(.bouncy(duration: 0.35), value: canPost)
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            StatusIcon(phase: iconPhase)
                .frame(width: 20, height: 20)
            if !orb {
                ZStack(alignment: .leading) {
                    Text(pillLabel)
                        .id(pillLabel)
                        .transition(.blurSlide)
                }
                .transition(.opacity)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, orb ? 15 : 18)
        .frame(height: 50, alignment: .leading)
    }

    private var iconPhase: StatusIcon.Phase {
        switch stage {
        case .sent: .done
        case .queued: .scheduled
        default: .working(progress)
        }
    }

    private var pillLabel: String {
        switch stage {
        case .sent:
            if isThread { return "Thread posted" }
            if target.replyTo != nil { return "Reply sent" }
            return target.quote == nil ? "Posted" : "Quote posted"
        case .queued(let date):
            let time = date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
            return isThread ? "Thread scheduled for \(time)" : "Scheduled for \(time)"
        default:
            if let progress { return "Uploading \(Int(progress * 100))%" }
            if willQueueLabel { return "Scheduling…" }
            if isThread { return "Posting \(min(sentParts + 1, totalParts)) of \(totalParts)…" }
            return target.replyTo == nil ? "Posting…" : "Replying…"
        }
    }

    /// Computed from the text itself so the card resizes in the same animation as the label swap.
    private var pillWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let text = (pillLabel as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 18 * 2 + 20 + 10
    }

    @State private var willQueueLabel = false

    private func replyChip(_ reply: XTweet) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.xBlue)
            Avatar(user: reply.author, size: 18)
            Text("@\(reply.author.screenName)").fontWeight(.semibold)
            Text(reply.text.replacingOccurrences(of: "\n", with: " "))
                .foregroundStyle(Color.xGray)
                .lineLimit(1)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(.white.opacity(0.06)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    /// A TextEditor that grows with its text (Return = new line, ⌘↩ = post, ⇧⌘↩ = add to thread,
    /// ⌫ in an empty follow-up post removes it).
    private func editor(index: Int) -> some View {
        let part = parts[index]
        return ZStack(alignment: .topLeading) {
            Text(part.text.isEmpty ? " " : part.text + "\n")
                .font(.system(size: 17))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if let i = parts.firstIndex(where: { $0.id == part.id }) { parts[i].height = min(max(height, 26), 300) }
                }

            if part.text.isEmpty {
                if index == 0 {
                    RotatingPlaceholder(isReply: target.replyTo != nil, isQuote: target.quote != nil, size: 17)
                        .allowsHitTesting(false)
                } else {
                    Text("Add another post")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.32))
                        .allowsHitTesting(false)
                }
            }

            TextEditor(text: Binding(
                get: { parts.first { $0.id == part.id }?.text ?? "" },
                set: { value in if let i = parts.firstIndex(where: { $0.id == part.id }) { parts[i].text = value } }
            ))
            .font(.system(size: 17))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focusedPart, equals: part.id)
            .padding(.leading, -5)
            .frame(height: part.height)
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.delete) {
                guard index > 0, part.text.isEmpty, part.attachments.isEmpty else { return .ignored }
                removePart(at: index)
                return .handled
            }
        }
    }

    private func attachmentStrip(index: Int) -> some View {
        let attachments = parts[index].attachments
        let partID = parts[index].id
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment, large: attachments.count == 1) {
                        if let i = parts.firstIndex(where: { $0.id == partID }) {
                            parts[i].attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    // MARK: Actions

    private func add(_ new: [PostAttachment]) {
        guard !new.isEmpty else { return }
        let index = activeIndex
        for attachment in new {
            if attachment.isVideoLike { parts[index].attachments = [attachment] }
            else if parts[index].canAttachMore { parts[index].attachments.append(attachment) }
        }
    }

    private func addPart() {
        guard editing, parts.count < 25 else { return }
        let new = ComposerPart()
        let insertAt = min(activeIndex + 1, parts.count)
        parts.insert(new, at: insertAt)
        DispatchQueue.main.async { focusedPart = new.id }
    }

    private func removePart(at index: Int) {
        guard parts.count > 1, parts.indices.contains(index) else { return }
        let focusAfter = parts[max(0, index - 1)].id
        parts.remove(at: index)
        focusedPart = focusAfter
    }

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

    private func fail(_ message: String) {
        inlineError = message
        shakes += 1
        Task {
            try? await Task.sleep(for: .seconds(4))
            if inlineError == message { inlineError = nil }
        }
    }

    private func close() {
        guard !exiting else { return }
        withAnimation(.easeIn(duration: 0.2)) { exiting = true }
        Task {
            try? await Task.sleep(for: .milliseconds(210))
            model.compose = nil
        }
    }

    /// Card → pill: the card closes around its content while the content fades, then the pill
    /// label fades in once there's room for it.
    private func collapse() {
        withAnimation(.spring(duration: 0.55, bounce: 0.1)) { collapsed = true }
        // Content stays visible while the card crops it, then hands off to the pill label.
        withAnimation(.easeIn(duration: 0.32)) { dockVisible = false }
        withAnimation(.smooth(duration: 0.28).delay(0.2)) { pillVisible = true }
    }

    private func expand() {
        withAnimation(.smooth(duration: 0.45)) { collapsed = false }
        withAnimation(.easeOut(duration: 0.15)) { pillVisible = false }
        withAnimation(.smooth(duration: 0.3).delay(0.2)) { dockVisible = true }
    }

    private func post() {
        guard canPost else {
            if editing, postableParts.isEmpty { shakes += 1 }
            return
        }
        let queues = willQueue
        let draft = PostDraft(parts: postableParts.map { .init(text: $0.trimmed, attachments: $0.attachments) },
                              replyTo: target.replyTo, quote: target.quote)
        let hasMedia = draft.parts.contains { !$0.attachments.isEmpty }
        inlineError = nil
        willQueueLabel = queues
        totalParts = draft.parts.count
        sentParts = 0
        stage = .sending
        collapse()

        Task {
            let started = Date.now
            let outcome = await model.post(draft, announce: false, progress: { value in
                Task { @MainActor in
                    if hasMedia { withAnimation(.smooth) { progress = value } }
                }
            }, partSent: { index in
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                    sentParts = index + 1
                    progress = nil
                }
            })
            // Keep "Posting…" on screen long enough to read before the result swaps in.
            let elapsed = Date.now.timeIntervalSince(started)
            if elapsed < 1.0 { try? await Task.sleep(for: .seconds(1.0 - elapsed)) }

            switch outcome {
            case .sent:
                withAnimation(.spring(duration: 0.5, bounce: 0.18)) { stage = .sent }
                try? await Task.sleep(for: .seconds(1.35))
                withAnimation(.smooth(duration: 0.45)) { dropAway = true }
                try? await Task.sleep(for: .seconds(0.46))
                model.compose = nil
            case .queued(let date):
                withAnimation(.spring(duration: 0.5, bounce: 0.18)) { stage = .queued(date) }
                try? await Task.sleep(for: .seconds(1.15))
                await flyIntoQueue()
                model.compose = nil
            case .failed:
                model.holdQueueBadge = false
                stage = .editing
                progress = nil
                expand()
                fail(model.banner ?? "Couldn't post")
                model.banner = nil
            }
        }
    }

    /// The pill folds into a clock circle, then hops into the toolbar queue button on a short arc.
    private func flyIntoQueue() async {
        withAnimation(.spring(duration: 0.4, bounce: 0.12)) { orb = true }
        try? await Task.sleep(for: .seconds(0.34))
        let target = model.queueButtonFrame
        let destination = target == .zero ? CGPoint(x: pillCenter.x + 400, y: 26) : CGPoint(x: target.minX + 14, y: target.midY)
        let dx = destination.x - pillCenter.x
        let dy = destination.y - pillCenter.y
        withAnimation(.timingCurve(0.55, 0, 0.75, 0.45, duration: 0.5)) { flight.width = dx }
        withAnimation(.timingCurve(0.2, 0.7, 0.35, 1, duration: 0.5)) { flight.height = dy }
        withAnimation(.timingCurve(0.4, 0, 0.8, 0.6, duration: 0.5)) { flightScale = 0.4 }
        withAnimation(.easeIn(duration: 0.14).delay(0.38)) { flightOpacity = 0 }
        try? await Task.sleep(for: .seconds(0.46))
        model.holdQueueBadge = false   // the button's count bumps as the clock lands
        try? await Task.sleep(for: .seconds(0.12))
    }

    private func runDemo(_ demo: String) {
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            for (index, chunk) in demo.components(separatedBy: "\n---\n").enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: .seconds(0.35))
                    addPart()
                    try? await Task.sleep(for: .seconds(0.35))
                }
                for character in chunk {
                    parts[parts.count - 1].text.append(character)
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 30...65)))
                }
            }
            try? await Task.sleep(for: .seconds(0.9))
            post()
        }
    }
}

// MARK: - Pieces

struct ComposerPart: Identifiable, Equatable {
    let id = UUID()
    var text = ""
    var attachments: [PostAttachment] = []
    var height: CGFloat = 26

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmed.isEmpty && attachments.isEmpty }
    /// Up to four photos, or a single GIF or video, like x.com.
    var canAttachMore: Bool { attachments.count < 4 && !attachments.contains(where: \.isVideoLike) }
}

/// The post being quoted, shown under the first part like x.com's composer.
private struct QuotePreview: View {
    var tweet: XTweet

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Avatar(user: tweet.author, size: 18)
                    Text(tweet.author.name).fontWeight(.semibold).lineLimit(1)
                    VerifiedBadge(user: tweet.author, size: 12)
                    Text("@\(tweet.author.screenName)").foregroundStyle(Color.xGray).lineLimit(1)
                }
                .font(.system(size: 13))
                if !tweet.text.isEmpty {
                    Text(tweet.text).font(.system(size: 13.5)).lineLimit(3).foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
            if let media = tweet.media.first {
                RemoteImage(url: media.previewURL, maxPixel: ImageSize.thumbnail)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(Color.xLine, lineWidth: 1))
    }
}

/// One icon that morphs through the whole send:
/// spinning arc (or upload progress) → the arc closes into a full ring → it fills blue and a
/// check draws itself in with a ripple; for a queued post the closed ring grows clock hands instead.
struct StatusIcon: View {
    enum Phase: Equatable { case working(Double?), done, scheduled }
    var phase: Phase

    @State private var ringClosed = false
    @State private var filled = false
    @State private var checkDrawn: CGFloat = 0
    @State private var handsIn = false
    @State private var ripple = false

    private var working: Bool { if case .working = phase { return true } else { return false } }
    private var arcEnd: CGFloat {
        if ringClosed { return 1 }
        if case .working(let value?) = phase { return max(0.06, value) }
        return 0.28
    }

    var body: some View {
        TimelineView(.animation(paused: !working || progressValue != nil)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360)
            ZStack {
                Circle().stroke(Color.xBlue.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: arcEnd)
                    .stroke(Color.xBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(progressValue != nil ? .degrees(-90) : (working ? angle : frozen))
                Circle()
                    .fill(Color.xBlue)
                    .scaleEffect(filled ? 1 : 0.3)
                    .opacity(filled ? 1 : 0)
                Checkmark()
                    .trim(from: 0, to: checkDrawn)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .padding(5.5)
                // Clock hands for scheduled posts.
                Group {
                    Capsule().fill(Color.xBlue).frame(width: 2, height: 6.5).offset(y: -3.25)
                        .rotationEffect(.degrees(handsIn ? 360 : 0))
                    Capsule().fill(Color.xBlue).frame(width: 2, height: 5).offset(y: -2.5)
                        .rotationEffect(.degrees(handsIn ? 120 : 0))
                    Circle().fill(Color.xBlue).frame(width: 3, height: 3)
                }
                .opacity(handsIn ? 1 : 0)
                .scaleEffect(handsIn ? 1 : 0.4)
                Circle()
                    .stroke(Color.xBlue, lineWidth: 1.5)
                    .scaleEffect(ripple ? 2.2 : 1)
                    .opacity(ripple ? 0 : (filled ? 0.6 : 0))
            }
            .onChange(of: working) { if !working { frozen = angle } }
        }
        .onChange(of: phase) { advance() }
        .onAppear { advance() }
    }

    @State private var frozen: Angle = .zero
    private var progressValue: Double? { if case .working(let value) = phase { return value } else { return nil } }

    private func advance() {
        switch phase {
        case .working:
            break
        case .done:
            withAnimation(.easeOut(duration: 0.24)) { ringClosed = true }
            withAnimation(.spring(duration: 0.42, bounce: 0.35).delay(0.16)) { filled = true }
            withAnimation(.easeOut(duration: 0.3).delay(0.28)) { checkDrawn = 1 }
            withAnimation(.easeOut(duration: 0.6).delay(0.3)) { ripple = true }
        case .scheduled:
            withAnimation(.easeOut(duration: 0.24)) { ringClosed = true }
            withAnimation(.spring(duration: 1.0, bounce: 0.3).delay(0.12)) { handsIn = true }
        }
    }
}

private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.maxY - rect.height * 0.14))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// Text swap: the old label lifts and blurs out while the new one rises in from below.
private struct BlurSlide: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .blur(radius: phase.isIdentity ? 0 : 5)
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: phase == .willAppear ? 9 : (phase == .didDisappear ? -9 : 0))
    }
}

private extension Transition where Self == BlurSlide {
    static var blurSlide: BlurSlide { BlurSlide() }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct DockIconButton: View {
    var symbol: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? Color.white.opacity(hovering ? 1 : 0.8) : .white.opacity(0.3))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(hovering && enabled ? 0.14 : 0.07)))
                .scaleEffect(hovering && enabled ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
    }
}

private struct ProgressRing: View {
    var value: Double
    var color: Color = .white
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: value < 0 ? 0.3 : max(0.05, value))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(value < 0 ? (spin ? 360 : 0) : -90))
                .animation(value < 0 ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .smooth, value: spin)
                .animation(.smooth, value: value)
        }
        .onAppear { spin = true }
    }
}

/// Cycles a few prompts while the field is empty, with a soft crossfade.
private struct RotatingPlaceholder: View {
    var isReply: Bool
    var isQuote = false
    var size: CGFloat = 17
    @State private var index = 0

    private var prompts: [String] {
        if isQuote { return ["Add a comment", "Your take?", "Why this matters…"] }
        return isReply ? ["Post your reply", "Add to the conversation…", "Say something nice…"]
                       : ["What's happening?", "Share an idea…", "Ship it.", "Hot take?"]
    }

    var body: some View {
        Text(prompts[index % prompts.count])
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(0.32))
            .id(index)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity.combined(with: .offset(y: -6))))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3.2))
                    withAnimation(.smooth(duration: 0.45)) { index += 1 }
                }
            }
    }
}

private struct AttachmentThumb: View {
    var attachment: PostAttachment
    var large: Bool
    var remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: large ? 220 : 96, height: large ? 140 : 96)
            .overlay {
                if let preview = attachment.preview {
                    Image(nsImage: preview).resizable().scaledToFill()
                } else {
                    Color.xPlaceholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if attachment.isVideoLike {
                    Text(attachment.category == .gif ? "GIF" : "Video")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.7)
                .accessibilityLabel("Remove attachment")
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.18), value: hovering)
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
            Circle().stroke(.white.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(remaining < 0 ? Color.red : remaining <= 20 ? .orange : .xBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if remaining <= 20 {
                Text("\(remaining)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining < 0 ? .red : .secondary)
                    .contentTransition(.numericText(value: Double(remaining)))
            }
        }
        .frame(width: 22, height: 22)
        .scaleEffect(remaining <= 20 ? 1.15 : 1)
        .animation(.bouncy(duration: 0.3), value: remaining <= 20)
        .animation(.snappy, value: count)
        .opacity(count == 0 ? 0 : 1)
        .help(remaining < 0 ? "Over the standard 280 limit (Premium accounts can post longer)" : "\(remaining) characters left")
    }
}

extension Color {
    /// X's dark card surface, used for the composer.
    static let composerSurface = Color(red: 22 / 255, green: 24 / 255, blue: 28 / 255)
}

extension View {
    /// An opaque dark surface with a soft light rim on the top edge.
    func composerSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(Color.composerSurface))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
    }
}
