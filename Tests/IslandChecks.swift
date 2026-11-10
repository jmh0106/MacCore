import AppKit
import SwiftUI
import MediaRemoteAdapter

@main enum IslandChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let suite = "MacCore.IslandChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startMonitoring: false, clipboardPreferences: preferences)
        var countdown = Countdown()
        countdown.start(seconds: 120, at: 0)
        assert(Countdown.display(countdown.remaining(at: 0.99)) == "02:00")
        assert(Countdown.display(countdown.remaining(at: 1.01)) == "01:59", "Countdown display should cross each second boundary once")
        let directory = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        model.menuBarHeight = 30
        model.screenTopInset = 30
        assert(model.overlayWindowSize == CGSize(width: 200, height: 74), "File drags should activate in the area around the idle island")
        model.tab = .files
        model.dropChoiceActive = true
        assert(model.expandedSize == CGSize(width: 296, height: 166), "The drag destination chooser should stay compact below the menu bar")
        model.expanded = true
        try render(model, directory, "drop-choice")
        model.dropChoiceActive = false
        model.expanded = false
        model.tab = .timer
        model.musicConnected = true
        model.music = MusicState(payload: TrackInfo.Payload(title: "Vancouver", artist: "BIG Naughty (서동현)", isPlaying: true,
            durationMicros: 240_000_000, applicationName: "Design preview"))
        assert(model.compactSize == CGSize(width: 272, height: 30))
        assert(OverlayLayout.compactSize(menuBarHeight: 30, music: true, timer: false, noticeWidth: 336, hovered: false) == CGSize(width: 272, height: 61))
        assert(OverlayLayout.compactSize(menuBarHeight: 30, music: false, timer: true, noticeWidth: 336, hovered: false) == CGSize(width: 240, height: 61))
        assert(OverlayLayout.compactSize(menuBarHeight: 30, music: false, timer: false, noticeWidth: 540, hovered: false) == CGSize(width: 540, height: 30))
        let artwork = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor.systemCyan.setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            return true
        }
        model.music.artwork = artwork
        try render(model, directory, "music")
        model.islandHovered = true
        assert(model.compactSize == CGSize(width: 290, height: 36) && !model.expanded)
        try render(model, directory, "music-hover")
        model.islandHovered = false

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("fixture", forType: .string)
        while board.changeCount == NSPasteboard.general.changeCount { board.clearContents(); board.setString("fixture", forType: .string) }
        model.recordClipboard(from: board, source: "test.editor")
        assert(model.clipboard.isEmpty, "Feedback must not enable history or store clipboard contents")
        if model.copyFeedbackEnabled { assert(model.islandNotice?.kind == .clipboard) }
        model.showIslandNotice(IslandNotice(title: "복사됨", detail: "클립보드", symbol: "doc.on.clipboard", kind: .clipboard, target: .clipboard))
        assert(model.compactSize == CGSize(width: 272, height: 61), "Feedback should stack below the active song at about twice its height")
        try render(model, directory, "copied")
        model.islandNotice = nil
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("private fixture", forType: .string)
        model.recordClipboard(from: board, source: "test.editor")
        assert(model.islandNotice == nil && model.clipboard.isEmpty)

        model.setClipboard(true)
        func copyText(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
            model.recordClipboard(from: board, source: "test.editor")
        }
        copyText("first")
        let firstID = model.clipboard[0].id
        model.clipboard[0].pinned = true
        for _ in 0..<5 { copyText("first") }
        assert(model.clipboard.count == 1 && model.clipboard[0].id == firstID,
               "Repeated copy shortcuts must not append duplicate text")
        copyText("second")
        copyText("first")
        assert(model.clipboard.count == 2 && model.clipboard[0].id == firstID && model.clipboard[0].pinned,
               "Copying an older value must promote its existing record and preserve its pin")
        copyText("first ")
        assert(model.clipboard.count == 3, "Meaningful whitespace must not be discarded")
        copyText("caf\u{00e9}")
        copyText("cafe\u{0301}")
        assert(model.clipboard.count == 4, "Equivalent Unicode text should share a record")

        model.clipboard.removeAll()
        func fixtureBitmap() -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 12,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let pixels = bitmap.bitmapData!
            for y in 0..<12 { for x in 0..<20 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 32; pixels[offset + 1] = 96; pixels[offset + 2] = 192; pixels[offset + 3] = 255
            } }
            return bitmap
        }
        let bitmap = fixtureBitmap()
        let png = bitmap.representation(using: .png, properties: [:])!
        let tiff = bitmap.representation(using: .tiff, properties: [:])!
        assert(ClipboardItem(payload: .image(Data([0, 1, 2]))) == nil,
               "Undecodable clipboard images must still be rejected")
        board.clearContents()
        board.setData(png, forType: .png)
        model.recordClipboard(from: board, source: "test.editor")
        let imageID = model.clipboard[0].id
        guard let imageURL = model.clipboard[0].imageURL else { fatalError("Clipboard image should be file-backed") }
        assert(FileManager.default.fileExists(atPath: imageURL.path), "Clipboard image bytes should be stored outside app memory")
        copyText("between images")
        board.clearContents()
        board.setData(tiff, forType: .tiff)
        model.recordClipboard(from: board, source: "test.editor")
        assert(model.clipboard.count == 2 && model.clipboard[0].id == imageID,
               "The same pixels copied as PNG and TIFF must share a record across intervening copies")
        assert(model.clipboard[0].imageURL == imageURL, "Deduplicating an image must retain its existing cache file")
        let changedBitmap = fixtureBitmap()
        changedBitmap.bitmapData![0] = 255; changedBitmap.bitmapData![1] = 0; changedBitmap.bitmapData![2] = 0
        let changedPNG = changedBitmap.representation(using: .png, properties: [:])!
        assert(changedPNG != png, "Distinct-image fixture must encode different pixels")
        board.clearContents()
        board.setData(changedPNG, forType: .png)
        model.recordClipboard(from: board, source: "test.editor")
        assert(model.clipboard.count == 3, "Images that differ by a pixel must stay distinct")
        guard let changedImageURL = model.clipboard[0].imageURL else { fatalError("Distinct image should also be file-backed") }

        model.clipboard.removeAll()
        assert(!FileManager.default.fileExists(atPath: imageURL.path)
            && !FileManager.default.fileExists(atPath: changedImageURL.path), "Deleting clipboard history must remove cached image files")
        let fileA = URL(fileURLWithPath: "/tmp/MacCore-clipboard-a.txt")
        let fileB = URL(fileURLWithPath: "/tmp/MacCore-clipboard-b.txt")
        board.clearContents()
        board.writeObjects([fileA as NSURL, fileB as NSURL])
        model.recordClipboard(from: board, source: "test.editor")
        let filesID = model.clipboard[0].id
        board.clearContents()
        board.writeObjects([fileB as NSURL, fileA as NSURL])
        model.recordClipboard(from: board, source: "test.editor")
        assert(model.clipboard.count == 1 && model.clipboard[0].id == filesID,
               "The same file selection in a different order must not create duplicates")
        model.clipboard.removeAll()
        model.setClipboard(false)

        let screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("MacCore-check-\(UUID().uuidString).png")
        try Data().write(to: screenshot)
        defer { try? FileManager.default.removeItem(at: screenshot) }
        model.receiveScreenshot(screenshot)
        assert(model.tray.count == 1 && model.islandNotice?.kind == .screenshot)
        try render(model, directory, "screenshot")
        model.islandNotice = nil
        model.receiveScreenshot(screenshot, temporary: true)
        assert(model.tray.count == 1 && model.tray[0].temporary && model.islandNotice == nil,
               "Our capture and metadata event must not duplicate or lose the unsaved-capture warning")
        var opened: PanelTab?
        model.revealTool = { opened = $0 }
        model.showIslandNotice(IslandNotice(title: "스크린샷 감지됨", detail: "파일 트레이", symbol: "viewfinder", kind: .screenshot, target: .files))
        model.openIslandNotice()
        assert(opened == .files && model.islandNotice == nil, "Notice clicks must open Files even while music plays")

        model.showIslandNotice(IslandNotice(title: "알림 미리보기", detail: "메시지가 도착했습니다", symbol: "bell.fill", kind: .notification))
        try render(model, directory, "notification-preview")
        model.showIslandNotice(IslandNotice(title: "old", detail: "", symbol: "bell", kind: .system), duration: 0.01)
        model.showIslandNotice(IslandNotice(title: "new", detail: "", symbol: "bell", kind: .system), duration: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        assert(model.islandNotice?.title == "new", "An old dismissal must not erase the next notice")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(model.islandNotice == nil && model.compactSize.width == 272, "Music must return when the notice expires")
        model.setFeedbackActive(false)
        model.showIslandNotice(IslandNotice(title: "locked", detail: "", symbol: "lock", kind: .system))
        assert(model.islandNotice == nil)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let path = IslandSurface(radius: 8 + 20 * fraction, attachment: fraction)
                .path(in: CGRect(x: 0, y: 0, width: 16 + 364 * fraction, height: 16 + 300 * fraction))
            assert(abs(path.boundingRect.minY) < 0.01, "The morph must stay attached to the screen's top edge")
        }
        print("PASS: compact sizing, clipboard privacy and text/image/file deduplication, pin preservation, capture deduplication, notices and lock")
    }

    @MainActor private static func render(_ model: AppModel, _ directory: URL?, _ name: String) throws {
        guard let directory else { return }
        let size = model.expanded ? model.expandedSize : model.compactSize
        let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 3
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Failed to render \(name)")
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
