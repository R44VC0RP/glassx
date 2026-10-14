import AVFoundation
import Combine
import SwiftUI

/// Muted, looping autoplay for videos and GIFs in the feed.
///
/// A player only exists while the media is at least half on screen, and is torn down when it
/// scrolls away, so a long feed never holds more than a couple of decoders.
struct InlineVideo: View {
    var media: XMedia
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isVisible = false
    @State private var isPlaying = false
    @State private var isMuted = true
    @State private var remaining: Int?

    private var url: URL? { media.inlineVideoURL ?? media.videoURL }

    var body: some View {
        ZStack {
            Color.clear
            if let player {
                PlayerLayerView(player: player)
                    .opacity(isPlaying ? 1 : 0)
                    .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                        withAnimation(.easeOut(duration: 0.2)) { isPlaying = status == .playing }
                    }
                    .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                        guard media.kind == .video, let item = player.currentItem else { return }
                        let total = item.duration.seconds, now = item.currentTime().seconds
                        if total.isFinite, now.isFinite { remaining = max(0, Int(total - now)) }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .overlay(alignment: .bottomLeading) { label.padding(10) }
        .overlay(alignment: .bottomTrailing) {
            if media.kind == .video {
                Button {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .circle)
                .padding(10)
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            }
        }
        .overlay {
            if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.tint(.black.opacity(0.45)), in: .circle)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            isVisible = visible
            update()
        }
        .onChange(of: scenePhase) { update() }
        .onDisappear { teardown() }
    }

    private var label: some View {
        Text(labelText)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
            .allowsHitTesting(false)
    }

    private var labelText: String {
        if media.kind == .gif { return "GIF" }
        let seconds = remaining ?? (media.durationMillis.map { $0 / 1000 } ?? 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func update() {
        let shouldPlay = isVisible && scenePhase != .background
        if shouldPlay {
            if player == nil, let url {
                let queue = AVQueuePlayer()
                queue.isMuted = isMuted
                queue.preventsDisplaySleepDuringVideoPlayback = false
                queue.automaticallyWaitsToMinimizeStalling = true
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                player = queue
            }
            player?.play()
        } else if !isVisible {
            teardown()
        } else {
            player?.pause()
        }
    }

    private func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
    }
}

/// Hosts an `AVPlayerLayer` with aspect-fill and no controls.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}
