import SwiftUI

extension Color {
    static let xBlue = Color(red: 29 / 255, green: 155 / 255, blue: 240 / 255)
    static let xPink = Color(red: 249 / 255, green: 24 / 255, blue: 128 / 255)
    static let xGreen = Color(red: 0, green: 186 / 255, blue: 124 / 255)
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
        AsyncImage(url: size > 56 ? user?.largeAvatarURL : user?.avatarURL.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "_normal.", with: "_bigger.")) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
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
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text("@\(user.screenName)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let date {
                Text("·").foregroundStyle(.secondary)
                Text(date.timelineLabel)
                    .foregroundStyle(.secondary)
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
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(3)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption.bold()) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 8)
        .frame(maxWidth: 560)
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
