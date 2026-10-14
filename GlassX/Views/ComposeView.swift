import SwiftUI
import UniformTypeIdentifiers

/// The composer: a chat-style prompt docked at the bottom of the window over a lightly dimmed feed.
///
/// Posting lifts the words out of the box and collapses it into a status pill (progress, then a
/// check). When "Space out my posts" queues the post instead, the pill becomes a ticket with a
/// winding clock that arcs up into the toolbar's queue button.
struct ComposerOverlay: View {
    enum Stage: Equatable { case editing, sending, sent, queued(Date) }

    var target: ComposeTarget
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var attachments: [PostAttachment] = []
    @State private var stage: Stage = .editing
    @State private var progress: Double?
    @State private var showingImporter = false
    @State private var isDropTargeted = false
    @State private var appeared = false
    @State private var exiting = false
    @State private var shakes = 0
    @State private var inlineError: String?
    @State private var pasteMonitor: Any?
    @State private var editorHeight: CGFloat = 26
    @FocusState private var focused: Bool

    // Send choreography
    @State private var textFrame: CGRect = .zero
    @State private var flyingText: String?
    @State private var flyAway = false
    @State private var arrowLaunched = false
    @State private var checkPulse = 0
    @State private var ticketX: CGFloat = 0
    @State private var ticketY: CGFloat = 0
    @State private var ticketScale: CGFloat = 1
    @State private var ticketOpacity: Double = 1
    @State private var canvasSize: CGSize = .zero
    @State private var toolbarInset: CGFloat = 52

    private let limit = 280
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var editing: Bool { stage == .editing }
    private var canPost: Bool { (!trimmed.isEmpty || !attachments.isEmpty) && editing }
    private var canAttachMore: Bool { attachments.count < 4 && !attachments.contains(where: \.isVideoLike) }
    private var willQueue: Bool { model.scheduler.wouldQueue(isReply: target.replyTo != nil) }
    private var shown: Bool { appeared && !exiting }

    var body: some View {
        GeometryReader { geometry in
            let width = min(660, geometry.size.width - 48)
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(shown && editing ? 0.3 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .allowsHitTesting(editing)

                container(width: width)
                    .padding(.bottom, 22)
                    .scaleEffect(ticketScale)
                    .offset(x: ticketX)
                    .offset(y: ticketY)
                    .opacity(ticketOpacity)
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

                if let flyingText {
                    // The words lift out of the box and dissolve upward as it collapses.
                    Text(flyingText)
                        .font(.system(size: 17))
                        .lineSpacing(3)
                        .foregroundStyle(.white)
                        .frame(width: textFrame.width, height: textFrame.height, alignment: .topLeading)
                        .scaleEffect(flyAway ? 0.94 : 1, anchor: .topLeading)
                        .blur(radius: flyAway ? 7 : 0)
                        .opacity(flyAway ? 0 : 1)
                        .position(x: textFrame.midX, y: textFrame.midY + (flyAway ? -110 : 0))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(.named("composer"))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarInset = max($0, 40) }
        }
        .onAppear {
            #if DEBUG
            if let i = CommandLine.arguments.firstIndex(of: "--compose-text"), let prefill = CommandLine.arguments[safe: i + 1], text.isEmpty {
                text = prefill
            }
            #endif
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.08)) { appeared = true }
            focused = true
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
            focused = true
        }
    }

    // MARK: Container

    /// The dock while editing; a compact status pill once sent or queued. One surface morphs between them.
    private func container(width: CGFloat) -> some View {
        ZStack {
            if editing {
                dock
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                statusPill
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(width: editing ? width : nil)
        .composerSurface(RoundedRectangle(cornerRadius: editing ? 28 : 25, style: .continuous))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.xBlue.opacity(0.8), lineWidth: 1.5)
            }
        }
        .animation(.smooth(duration: 0.22), value: editorHeight)
        .animation(.bouncy(duration: 0.35), value: attachments)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.compactMap { try? PostAttachment.load(from: $0) })
            return true
        } isTargeted: { isDropTargeted = $0 && editing }
    }

    private var dock: some View {
        VStack(spacing: 0) {
            if let reply = target.replyTo { replyChip(reply) }
            HStack(alignment: .top, spacing: 12) {
                Avatar(user: model.viewer, size: 32).padding(.top, 1)
                editor
            }
            .padding(.horizontal, 18)
            .padding(.top, target.replyTo == nil ? 18 : 12)
            .padding(.bottom, 10)

            if !attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, 18).padding(.leading, 44).padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                DockIconButton(symbol: "photo.on.rectangle.angled", enabled: canAttachMore) { showingImporter = true }
                    .help("Add media (⌘O)")
                    .accessibilityLabel("Add media")
                DockIconButton(symbol: "face.smiling", enabled: true) {
                    focused = true
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .help("Emoji")
                .accessibilityLabel("Emoji")
                Group {
                    if let inlineError {
                        Label(inlineError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                    } else if willQueue {
                        Label("Queues for \(model.scheduler.nextSlot().formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                            .foregroundStyle(Color.xGray)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, 4)
                .transition(.opacity)
                Spacer()
                CharacterRing(count: trimmed.count, limit: limit)
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .animation(.smooth, value: inlineError)
        }
        .background {
            Button("", action: { if canAttachMore { showingImporter = true } }).keyboardShortcut("o", modifiers: .command).hidden()
        }
    }

    private var sendButton: some View {
        Button(action: post) {
            ZStack {
                Circle().fill(Color.xBlue.opacity(canPost ? 1 : 0.3))
                Image(systemName: willQueue ? "clock" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(y: arrowLaunched ? -16 : 0)
                    .opacity(arrowLaunched ? 0 : 1)
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

    @ViewBuilder private var statusPill: some View {
        HStack(spacing: 10) {
            switch stage {
            case .sending:
                Avatar(user: model.viewer, size: 24)
                ProgressRing(value: progress ?? -1, color: .xBlue).frame(width: 15, height: 15)
                Text(progress.map { "Uploading \(Int($0 * 100))%" } ?? (target.replyTo == nil ? "Posting…" : "Replying…"))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .sent:
                ZStack {
                    Circle()
                        .stroke(Color.xBlue, lineWidth: 2)
                        .keyframeAnimator(initialValue: PulseValue(), trigger: checkPulse) { content, value in
                            content.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) { LinearKeyframe(2.4, duration: 0.6, timingCurve: .easeOut) }
                            KeyframeTrack(\.opacity) { LinearKeyframe(0.7, duration: 0.01); LinearKeyframe(0, duration: 0.6, timingCurve: .easeOut) }
                        }
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.xBlue)
                        .symbolEffect(.bounce, value: checkPulse)
                }
                .frame(width: 20, height: 20)
                Text(target.replyTo == nil ? "Posted" : "Reply sent")
            case .queued(let date):
                ClockGlyph().frame(width: 18, height: 18)
                Text("Scheduled for \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))")
            case .editing:
                EmptyView()
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.leading, stage == .sending ? 13 : 16)
        .padding(.trailing, 18)
        .frame(height: 50)
        .fixedSize()
    }

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

    /// A TextEditor that grows with its text (Return = new line, ⌘↩ = post).
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            Text(text.isEmpty ? " " : text + "\n")
                .font(.system(size: 17))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = min(max($0, 26), 300) }

            if text.isEmpty {
                RotatingPlaceholder(isReply: target.replyTo != nil, size: 17)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.system(size: 17))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .padding(.leading, -5)
                .frame(height: editorHeight)
                .onKeyPress(.escape) { close(); return .handled }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("composer")) } action: { textFrame = $0 }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment, large: attachments.count == 1) {
                        attachments.removeAll { $0.id == attachment.id }
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
        for attachment in new {
            if attachment.isVideoLike { attachments = [attachment] }
            else if canAttachMore { attachments.append(attachment) }
        }
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

    private func post() {
        guard canPost else {
            if editing, trimmed.isEmpty, attachments.isEmpty { shakes += 1 }
            return
        }
        let queues = willQueue
        let body = trimmed
        let files = attachments
        let hasMedia = !files.isEmpty
        inlineError = nil
        if queues { model.holdQueueBadge = true }

        // 1. The arrow launches and the words lift off.
        flyingText = body.isEmpty ? nil : body
        flyAway = false
        withAnimation(.snappy(duration: 0.18)) { arrowLaunched = true }
        withAnimation(.easeIn(duration: 0.45)) { flyAway = true }
        // 2. The dock collapses into a status pill (straight to the ticket when queueing).
        if !queues {
            withAnimation(.bouncy(duration: 0.5, extraBounce: 0.04)) { stage = .sending }
        }

        Task {
            let outcome = await model.post(text: body, replyTo: target.replyTo, attachments: files, announce: false) { value in
                Task { @MainActor in
                    if hasMedia { withAnimation(.smooth) { progress = value } }
                }
            }
            flyingText = nil
            switch outcome {
            case .sent:
                withAnimation(.bouncy(duration: 0.45, extraBounce: 0.1)) { stage = .sent }
                checkPulse += 1
                try? await Task.sleep(for: .seconds(1.15))
                close()
            case .queued(let date):
                withAnimation(.bouncy(duration: 0.5, extraBounce: 0.06)) { stage = .queued(date) }
                try? await Task.sleep(for: .seconds(1.2))
                flyIntoQueue()
                try? await Task.sleep(for: .seconds(0.5))
                model.holdQueueBadge = false   // the toolbar count bumps as the ticket lands
                try? await Task.sleep(for: .seconds(0.1))
                model.compose = nil
            case .failed:
                model.holdQueueBadge = false
                withAnimation(.bouncy(duration: 0.45)) {
                    stage = .editing
                    arrowLaunched = false
                    flyAway = false
                }
                progress = nil
                fail(model.banner ?? "Couldn't post")
                model.banner = nil
            }
        }
    }

    /// Arcs the ticket up into the toolbar's queue button: it rises fast and drifts right late.
    private func flyIntoQueue() {
        // Pill center sits 22pt + half its height above the bottom; the queue button is left of
        // Refresh / New Post / account in the toolbar, vertically centered in the toolbar inset.
        let targetX = (canvasSize.width - 212) - canvasSize.width / 2
        let targetY = -toolbarInset / 2 - (canvasSize.height - 22 - 25)
        withAnimation(.timingCurve(0.45, 0, 0.9, 0.6, duration: 0.55)) { ticketX = targetX }
        withAnimation(.timingCurve(0.1, 0.55, 0.3, 1, duration: 0.55)) { ticketY = targetY }
        withAnimation(.easeIn(duration: 0.55)) { ticketScale = 0.3 }
        withAnimation(.easeIn(duration: 0.2).delay(0.38)) { ticketOpacity = 0 }
    }

    private func runDemo(_ demo: String) {
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            for character in demo {
                text.append(character)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 26...58)))
            }
            try? await Task.sleep(for: .seconds(0.8))
            post()
        }
    }
}

// MARK: - Pieces

private struct PulseValue {
    var scale: CGFloat = 1
    var opacity: Double = 0
}

/// A small clock whose hands wind forward as it appears.
private struct ClockGlyph: View {
    @State private var wound = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.xBlue, lineWidth: 1.8)
            Capsule().fill(Color.xBlue).frame(width: 1.8, height: 6).offset(y: -3)
                .rotationEffect(.degrees(wound ? 360 : 0))
            Capsule().fill(Color.xBlue).frame(width: 1.8, height: 4.5).offset(y: -2.25)
                .rotationEffect(.degrees(wound ? 120 : 0))
            Circle().fill(Color.xBlue).frame(width: 3, height: 3)
        }
        .onAppear { withAnimation(.spring(duration: 1.0, bounce: 0.3)) { wound = true } }
    }
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
    var size: CGFloat = 17
    @State private var index = 0

    private var prompts: [String] {
        isReply ? ["Post your reply", "Add to the conversation…", "Say something nice…"]
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
