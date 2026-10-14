import SwiftUI

extension Color {
    static let xBlue = Color(red: 29 / 255, green: 155 / 255, blue: 240 / 255)
    static let xPink = Color(red: 249 / 255, green: 24 / 255, blue: 128 / 255)
    static let xGreen = Color(red: 0, green: 186 / 255, blue: 124 / 255)
    /// X's "Lights out" divider and thread-line color.
    static let xLine = Color(red: 47 / 255, green: 51 / 255, blue: 54 / 255)
    /// X's secondary text gray.
    static let xGray = Color(red: 113 / 255, green: 118 / 255, blue: 123 / 255)
    static let xPlaceholder = Color.white.opacity(0.06)
}

/// A one-pixel divider in X's line color.
struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(Color.xLine).frame(height: 1 / scale)
    }
}

private struct ShowsReplyContextKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// "Replying to @…" is redundant inside a thread, where the reply line already shows it.
    var showsReplyContext: Bool {
        get { self[ShowsReplyContextKey.self] }
        set { self[ShowsReplyContextKey.self] = newValue }
    }
}

extension Date {
    /// "42s", "5m", "3h", "Oct 4", "Oct 4, 2024" — the way X labels posts.
    var timelineLabel: String {
        let seconds = -timeIntervalSinceNow
        switch seconds {
        case ..<60: return "\(Int(max(seconds, 1)))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default:
            if Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) {
                return formatted(.dateTime.month(.abbreviated).day())
            }
            return formatted(.dateTime.month(.abbreviated).day().year())
        }
    }
}

extension Int {
    var compact: String { formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
}

struct Avatar: View {
    var user: XUser?
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: user?.hasSquareAvatar == true ? size * 0.22 : size / 2, style: .continuous)
        RemoteImage(url: user?.avatarURL(forSize: size), maxPixel: size > 56 ? ImageSize.largeAvatar : ImageSize.avatar)
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// Overlapping avatars, first on top, each cut out of the next with a black ring.
/// Hovering fans the stack out so every face is visible.
struct AvatarStack: View {
    var users: [XUser]
    var size: CGFloat = 32
    var onTap: (XUser) -> Void = { _ in }
    @State private var expanded = false

    var body: some View {
        HStack(spacing: expanded ? 4 : -size * 0.3) {
            ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                Avatar(user: user, size: size)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: user.hasSquareAvatar ? size * 0.26 : size, style: .continuous)
                            .fill(Color.black)
                    )
                    .zIndex(Double(users.count - index))
                    .onTapGesture { onTap(user) }
                    .pointerStyle(.link)
                    .help("\(user.name) · @\(user.screenName)")
            }
        }
        .padding(-2)
        .onHover { hovering in withAnimation(.snappy(duration: 0.25)) { expanded = hovering } }
    }
}

struct VerifiedBadge: View {
    var user: XUser
    var size: CGFloat = 14

    var body: some View {
        if user.isVerified || user.verifiedType != nil {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size))
                .foregroundStyle(color)
                .accessibilityLabel("Verified")
        }
    }

    private var color: Color {
        switch user.verifiedType {
        case "Business": .yellow
        case "Government": .gray
        default: .xBlue
        }
    }
}

struct AuthorLine: View {
    var user: XUser
    var date: Date?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text(user.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            VerifiedBadge(user: user, size: compact ? 12 : 14)
            if user.isProtected {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Color.xGray)
            }
            Text("@\(user.screenName)")
                .foregroundStyle(Color.xGray)
                .lineLimit(1)
            if let date {
                Text("·").foregroundStyle(Color.xGray)
                Text(date.timelineLabel)
                    .foregroundStyle(Color.xGray)
                    .fixedSize()
                    .help(date.formatted(date: .complete, time: .shortened))
            }
        }
        .font(.system(size: compact ? 13 : 14))
    }
}

/// Reply / repost / like / bookmark button with an animated count.
struct EngagementButton: View {
    var symbol: String
    var activeSymbol: String? = nil
    var count: Int?
    var isActive = false
    var activeColor: Color = .xBlue
    var label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isActive ? (activeSymbol ?? symbol) : symbol)
                    .symbolEffect(.bounce, value: isActive)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(activeColor.opacity(hovering ? 0.14 : 0))
                    }
                if let count, count > 0 {
                    Text(count.compact)
                        .contentTransition(.numericText(value: Double(count)))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(isActive || hovering ? activeColor : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
        .accessibilityLabel(label)
    }
}

/// A floating Liquid Glass message pill.
struct GlassBanner: View {
    var text: String
    var systemImage = "exclamationmark.triangle.fill"
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(systemImage.hasPrefix("exclamationmark") ? Color.orange : Color.xBlue)
            Text(text).font(.callout).lineLimit(3)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption.bold()) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.xGray)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 8)
        .frame(maxWidth: 560)
    }
}

/// X-style text tabs with a sliding blue underline. Lives in the content layer (no glass),
/// pinned under the toolbar with `safeAreaBar` so the feed blurs beneath it.
struct FeedTabs<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(Value, String)]
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let selected = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = value }
                } label: {
                    VStack(spacing: 0) {
                        Text(title)
                            .font(.system(size: 15, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? Color.white : Color.xGray)
                            .frame(maxHeight: .infinity)
                        ZStack {
                            if selected {
                                Capsule()
                                    .fill(Color.xBlue)
                                    .frame(width: 56, height: 4)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { Hairline() }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }
}

/// The readable column width X uses for its timeline.
struct TimelineColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }
}
