import AppKit
import MediaRemoteAdapter

struct MusicState {
    var title = "재생 중인 미디어가 없습니다"
    var artist = "지금 재생 중"
    var sourceName = ""
    var sourceBundleID = ""
    var playing = false
    var position: Double = 0
    var duration: Double = 0
    var trackID = ""
    var artwork: NSImage?
    var artworkTint: NSColor?
    var error: String?
    var hasTrack: Bool { !trackID.isEmpty }

    init() {}

    init(payload: TrackInfo.Payload, previous: MusicState? = nil) {
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        self.title = title
        sourceName = payload.applicationName ?? "미디어 플레이어"
        sourceBundleID = payload.bundleIdentifier ?? ""
        // Recent Safari versions report the media subprocess as the player.
        if sourceName == "Safari Graphics and Media" {
            sourceName = "Safari"
            sourceBundleID = "com.apple.Safari"
        }
        artist = payload.artist.flatMap { $0.isEmpty ? nil : $0 } ?? sourceName
        playing = payload.isPlaying == true
        let seconds = (payload.durationMicros ?? 0) / 1_000_000
        duration = seconds.isFinite ? max(0, seconds) : 0
        trackID = sourceBundleID + ":" + payload.uniqueIdentifier
        if let image = payload.artwork, image.size.width <= 4096, image.size.height <= 4096 {
            artwork = image
            artworkTint = previous?.trackID == trackID ? previous?.artworkTint : nil
            if artworkTint == nil { artworkTint = Self.tint(from: image) }
        }
    }

    private static func tint(from image: NSImage) -> NSColor? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var bestHue: CGFloat = 0, bestSaturation: CGFloat = 0, bestBrightness: CGFloat = 0
        var bestScore: CGFloat = 0
        for y in 1..<7 { for x in 1..<7 {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let score = saturation * brightness
            if saturation > 0.2 && score > bestScore {
                bestHue = hue; bestSaturation = saturation; bestBrightness = brightness; bestScore = score
            }
        } }
        guard bestScore > 0 else { return nil }
        return NSColor(hue: bestHue, saturation: max(0.55, bestSaturation),
                       brightness: min(0.98, max(0.72, bestBrightness)), alpha: 1)
    }
}

extension AppModel {
    func connectMusic() {
        disconnectMusic()
        let controller = MediaController()
        mediaController = controller
        musicConnected = true
        musicBusy = true
        controller.onTrackInfoReceived = { [weak self, weak controller] info in
            Task { @MainActor in
                guard let self, let controller, self.mediaController === controller else { return }
                self.musicBusy = false
                self.musicTrack = info?.payload
                self.music = info.map { MusicState(payload: $0.payload, previous: self.music) } ?? MusicState()
                self.updateMusicPosition()
            }
        }
        controller.onListenerTerminated = { [weak self, weak controller] in
            Task { @MainActor in
                guard let self, let controller, self.mediaController === controller else { return }
                self.disconnectMusic()
                self.music.error = "재생 정보 감지가 중단되었습니다. 다시 감지해 주세요."
            }
        }
        controller.onDecodingError = { [weak self, weak controller] _, _ in
            Task { @MainActor in
                guard let self, let controller, self.mediaController === controller else { return }
                self.musicBusy = false
                self.music.error = "이 플레이어의 재생 정보를 읽지 못했습니다."
            }
        }
        controller.startListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak controller] in
            guard let self, let controller, self.mediaController === controller, self.musicBusy else { return }
            self.disconnectMusic()
            self.music.error = "재생 정보에 응답이 없습니다. 다시 감지해 주세요."
        }
    }

    func disconnectMusic() {
        musicConnected = false
        musicBusy = false
        mediaController?.onTrackInfoReceived = nil
        mediaController?.onListenerTerminated = nil
        mediaController?.onDecodingError = nil
        mediaController?.stopListening()
        mediaController = nil
        musicTrack = nil
        music = MusicState()
    }

    func updateMusicPosition() {
        guard musicConnected, music.hasTrack, let track = musicTrack else { return }
        music.position = NowPlayingTiming.position(
            elapsed: track.elapsedTimeMicros.map { $0 / 1_000_000 },
            timestamp: track.timestampEpochMicros.map { $0 / 1_000_000 },
            rate: track.playbackRate, playing: music.playing, duration: music.duration)
    }

    func musicCommand(_ command: String) {
        guard musicConnected, music.hasTrack else { return }
        switch command {
        case "playpause": mediaController?.togglePlayPause()
        case "next track": mediaController?.nextTrack()
        case "previous track": mediaController?.previousTrack()
        default: break
        }
    }

    func seekMusic(_ position: Double) {
        guard musicConnected, music.hasTrack, music.duration > 0, position.isFinite else { return }
        mediaController?.setTime(seconds: min(music.duration, max(0, position)))
    }

    func openMusicSource() {
        guard !music.sourceBundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: music.sourceBundleID) else { return }
        NSWorkspace.shared.open(url)
    }
}
