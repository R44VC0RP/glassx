import SwiftUI

struct ComposeView: View {
    var target: ComposeTarget
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isPosting = false
    @FocusState private var focused: Bool

    private let limit = 280
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reply = target.replyTo {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 4) {
                        Avatar(user: reply.author, size: 40)
                        Capsule().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        AuthorLine(user: reply.author, date: reply.createdAt)
                        TweetText(tweet: reply, size: 14, lineLimit: 6)
                        Text("Replying to ").foregroundStyle(.secondary) + Text("@\(reply.author.screenName)").foregroundStyle(Color.xBlue)
                    }
                    .font(.system(size: 13))
                    .padding(.bottom, 12)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Avatar(user: model.viewer, size: 40)
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
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 120)
                        .padding(.leading, -5)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Spacer()
                CharacterRing(count: trimmed.count, limit: limit)
                Button {
                    post()
                } label: {
                    if isPosting { ProgressView().controlSize(.small).frame(width: 44) } else { Text(target.replyTo == nil ? "Post" : "Reply").fontWeight(.semibold).frame(minWidth: 44) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(trimmed.isEmpty || isPosting)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .onAppear { focused = true }
    }

    private func post() {
        guard !trimmed.isEmpty else { return }
        isPosting = true
        Task {
            let ok = await model.post(text: trimmed, replyTo: target.replyTo)
            isPosting = false
            if ok { dismiss() }
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
            Circle().stroke(.quaternary, lineWidth: 2.5)
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
