import AVKit
import SwiftUI

struct MediaGallery: Codable, Hashable {
    var items: [XMedia]
    var index: Int
}

/// X-style media grid: 1 full, 2 side by side, 3 as one large + two stacked, 4 as a 2×2 grid.
struct MediaGrid: View {
    var media: [XMedia]
    var maxHeight: CGFloat = 510
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if media.count == 1, let item = media.first {
                // Cap the width so tall images stop at maxHeight and the frame hugs the image.
                let ratio = max(item.aspectRatio, 0.75)
                cell(item, index: 0)
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: maxHeight * ratio)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.xLine, lineWidth: 1))
            } else {
                grid
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.xLine, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var grid: some View {
        let spacing: CGFloat = 2
        switch media.count {
        case 2:
            HStack(spacing: spacing) { cell(media[0], index: 0); cell(media[1], index: 1) }
        case 3:
            HStack(spacing: spacing) {
                cell(media[0], index: 0)
                VStack(spacing: spacing) { cell(media[1], index: 1); cell(media[2], index: 2) }
            }
        default:
            VStack(spacing: spacing) {
                HStack(spacing: spacing) { cell(media[0], index: 0); cell(media[1], index: 1) }
                HStack(spacing: spacing) { cell(media[2], index: 2); cell(media[safe: 3] ?? media[2], index: 3) }
            }
        }
    }

    private func cell(_ item: XMedia, index: Int) -> some View {
        Button {
            openWindow(value: MediaGallery(items: media, index: min(index, media.count - 1)))
        } label: {
            Color.clear
                .overlay {
                    RemoteImage(url: item.previewURL, maxPixel: ImageSize.media)
                }
                .clipped()
                .overlay {
                    if item.kind != .photo {
                        if item.videoURL != nil { InlineVideo(media: item) } else { VideoBadge(media: item) }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.altText ?? (item.kind == .photo ? "Image" : "Video"))
    }
}

private struct VideoBadge: View {
    var media: XMedia

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .circle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
                .padding(10)
        }
    }

    private var label: String {
        if media.kind == .gif { return "GIF" }
        guard let ms = media.durationMillis else { return "Video" }
        let seconds = ms / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Link preview card.
struct LinkCardView: View {
    var card: XLinkCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button { openURL(card.url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image = card.imageURL {
                    Color.clear
                        .aspectRatio(1.91, contentMode: .fit)
                        .overlay {
                            RemoteImage(url: image, maxPixel: ImageSize.media)
                        }
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.domain).font(.caption).foregroundStyle(Color.xGray)
                    Text(card.title).font(.system(size: 14)).lineLimit(2)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.xLine, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// Separate window for photos and videos, with keyboard navigation.
struct MediaViewer: View {
    @Binding var gallery: MediaGallery?
    @State private var index = 0
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = current {
                Group {
                    if item.kind == .photo {
                        RemoteImage(url: item.fullSizeURL, maxPixel: ImageSize.full, contentMode: .fit)
                    } else if let player {
                        VideoPlayer(player: player)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.id)
            }
            if let items = gallery?.items, items.count > 1 {
                HStack {
                    navButton("chevron.left", disabled: index == 0) { index -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer()
                    navButton("chevron.right", disabled: index >= items.count - 1) { index += 1 }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(current?.altText ?? "Media")
        .onAppear { index = gallery?.index ?? 0; preparePlayer() }
        .onChange(of: index) { preparePlayer() }
        .onDisappear { player?.pause() }
    }

    private var current: XMedia? {
        guard let items = gallery?.items, items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func preparePlayer() {
        player?.pause()
        guard let item = current, item.kind != .photo, let url = item.videoURL else { player = nil; return }
        let newPlayer = AVPlayer(url: url)
        if item.kind == .gif {
            newPlayer.isMuted = true
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: newPlayer.currentItem, queue: .main) { _ in
                newPlayer.seek(to: .zero)
                newPlayer.play()
            }
        }
        newPlayer.play()
        player = newPlayer
    }

    private func navButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(disabled)
        .opacity(disabled ? 0 : 1)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
