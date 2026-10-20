import AppKit
import MediaRemoteAdapter

@main enum NowPlayingChecks {
    @MainActor static func main() {
        let model = AppModel(startMonitoring: false)
        for tool in PanelTab.allCases {
            assert(SettingsPage(tool: tool).rawValue == tool.rawValue)
        }
        model.tab = .music
        model.settingsPage = .clipboard
        assert(model.tab == .music, "Browsing settings must not switch the island's active tool")
        let youtube = TrackInfo.Payload(title: "A song on YouTube", artist: "Artist", isPlaying: true,
            durationMicros: 240_000_000, applicationName: "Safari", bundleIdentifier: "com.apple.Safari")
        let spotify = TrackInfo.Payload(title: "A song on YouTube", artist: "Artist", isPlaying: true,
            applicationName: "Spotify", bundleIdentifier: "com.spotify.client")
        model.musicConnected = true
        model.music = MusicState(payload: youtube)
        assert(model.music.title == "A song on YouTube" && model.music.sourceName == "Safari")
        assert(model.music.duration == 240 && model.compactMusic)
        let safariMedia = MusicState(payload: TrackInfo.Payload(title: "Browser song", applicationName: "Safari Graphics and Media"))
        assert(safariMedia.sourceName == "Safari" && safariMedia.sourceBundleID == "com.apple.Safari")
        let firstID = model.music.trackID
        model.music = MusicState(payload: spotify)
        assert(model.music.sourceBundleID == "com.spotify.client" && model.music.trackID != firstID)
        assert(model.compactMusic, "Live or unknown-duration media must still appear")
        model.music.playing = false
        assert(!model.compactMusic, "Paused media must not animate in the menu bar")
        model.music = MusicState(payload: TrackInfo.Payload(title: "   ", isPlaying: true))
        assert(!model.music.hasTrack && !model.compactMusic)
        model.music = MusicState(payload: TrackInfo.Payload(title: "Live", durationMicros: .infinity, applicationName: "Player"))
        assert(model.music.duration == 0 && model.music.artist == "Player")
        model.disconnectMusic()
        assert(!model.musicConnected && !model.music.hasTrack && model.mediaController == nil)
        print("PASS: browser metadata, source switching, live media, pause, invalid data and disconnect")
    }
}
