import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("pacing.enabled") private var pacingEnabled = false
    @AppStorage("pacing.gapMinutes") private var gapMinutes = 60
    @AppStorage("pacing.startHour") private var startHour = 8
    @AppStorage("pacing.endHour") private var endHour = 22
    @AppStorage("pacing.repliesImmediately") private var repliesImmediately = true

    private let gaps = [15, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Space out my posts", isOn: $pacingEnabled)
                Text("Post as many times as you like. GlassX queues them and sends one at a time, spread through the day, with a little randomness so they feel natural.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SwiftUI.Section("Pacing") {
                Picker("At least", selection: $gapMinutes) {
                    ForEach(gaps, id: \.self) { minutes in
                        Text(minutes < 60 ? "\(minutes) minutes apart" : minutes % 60 == 0 ? "\(minutes / 60) hour\(minutes == 60 ? "" : "s") apart" : "\(minutes / 60)½ hours apart")
                            .tag(minutes)
                    }
                }
                Picker("Only post from", selection: $startHour) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Picker("Until", selection: $endHour) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Toggle("Send replies right away", isOn: $repliesImmediately)
            }
            .disabled(!pacingEnabled)

            SwiftUI.Section("Queue") {
                if model.scheduler.queue.isEmpty {
                    Text("Nothing queued").foregroundStyle(.secondary)
                } else {
                    ForEach(model.scheduler.queue) { post in QueueRow(post: post) }
                }
                Text("Queued posts are sent while GlassX is open. If it was closed when a post came due, the queue picks up again, still spaced out, when you reopen it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 520)
    }

    private func hourLabel(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}

/// One queued post with its send time and Send Now / Delete.
struct QueueRow: View {
    var post: PostScheduler.QueuedPost
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if model.scheduler.sendingID == post.id {
                        ProgressView().controlSize(.mini)
                        Text("Sending…")
                    } else if post.sendAt == .distantFuture {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Paused after errors")
                    } else {
                        Image(systemName: "clock")
                        Text(post.sendAt.formatted(date: Calendar.current.isDateInToday(post.sendAt) ? .omitted : .abbreviated, time: .shortened))
                    }
                    if let handle = post.replyToHandle { Text("· reply to @\(handle)") }
                    if !post.media.isEmpty {
                        Image(systemName: "photo")
                        Text("\(post.media.count)")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Text(post.text.isEmpty ? "(media only)" : post.text)
                    .lineLimit(3)
                    .font(.callout)
                if let error = post.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Send Now") { model.scheduler.sendNow(post) }
                .controlSize(.small)
                .disabled(model.scheduler.sendingID != nil)
            Button(role: .destructive) {
                withAnimation { model.scheduler.remove(post) }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete from queue")
        }
    }
}

/// Toolbar clock pill showing how many posts are waiting; opens the queue.
struct QueueToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let count = model.visibleQueueCount
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock").symbolEffect(.bounce, value: count)
                Text("\(count) queued")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .keyframeAnimator(initialValue: CGFloat(1), trigger: count) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.22, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
        }
        .animation(.snappy, value: count)
        .help("Queued posts")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Queued posts").font(.headline)
                ForEach(model.scheduler.queue) { post in
                    QueueRow(post: post)
                    if post.id != model.scheduler.queue.last?.id { Divider() }
                }
                SettingsLink { Text("Pacing settings…") }
                    .buttonStyle(.link)
            }
            .padding(16)
            .frame(width: 400)
        }
    }
}
