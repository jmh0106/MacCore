import AppKit
import SwiftUI

// Offscreen layout and settings checks with an isolated clipboard preference store.
@main enum DesignChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let suite = "MacCore.DesignChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(startMonitoring: false, clipboardPreferences: preferences)
        assert(!model.clipboardEnabled)
        model.setClipboard(true)
        assert(AppModel(startMonitoring: false, clipboardPreferences: preferences).clipboardEnabled,
               "Clipboard recording must stay enabled after relaunch")
        model.setFeedbackActive(false)
        assert(model.clipboardEnabled && preferences.bool(forKey: "clipboardEnabled"),
               "Locking must pause monitoring without disabling the saved preference")
        model.setFeedbackActive(true)

        var menuHeight: CGFloat = 0
        let host = NSHostingView(rootView: MenuPopoverView(model: model) { menuHeight = $0 })
        host.sizingOptions = []
        let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 340, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assert(menuHeight > 200 && menuHeight < 600, "Menu should fit its selected dashboard and quick actions")
        let loadingHeight = menuHeight
        panel.setContentSize(CGSize(width: 340, height: 650))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assert(menuHeight == loadingHeight, "A taller parent must not add blank space to menu content")
        let anchor = CGRect(x: 800, y: 876, width: 24, height: 24)
        let visible = CGRect(x: 0, y: 50, width: 1440, height: 826)
        let small = OverlayLayout.menuPanelFrame(anchor: anchor, visible: visible, size: CGSize(width: 340, height: loadingHeight))
        let large = OverlayLayout.menuPanelFrame(anchor: anchor, visible: visible, size: CGSize(width: 340, height: loadingHeight + 150))
        assert(small.maxY == large.maxY && large.minY < small.minY, "Menu growth must stay anchored at the top")

        model.expanded = true
        model.tab = .timer
        let overlay = NSHostingView(rootView: OverlayView(model: model).transaction { $0.disablesAnimations = true })
        overlay.sizingOptions = []
        let toolPanel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 360, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        toolPanel.contentView = overlay
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let timerHeight = model.toolContentHeights[.timer] ?? 0
        assert(timerHeight > 300 && timerHeight < 400, "Timer should fit its controls without the old bottom gap")
        toolPanel.setContentSize(CGSize(width: 360, height: 500))
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assert(model.toolContentHeights[.timer] == timerHeight, "Tool measurement must not depend on canvas height")
        let image = NSImage(size: CGSize(width: 160, height: 100), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.systemMint.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 50, dy: 20)).fill()
            return true
        }
        model.clipboard = [ClipboardItem(payload: .image(image.tiffRepresentation!)), ClipboardItem(payload: .text("확인용 복사 기록"))]
        model.tab = .clipboard
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let twoRowsHeight = model.toolContentHeights[.clipboard] ?? 0
        assert(twoRowsHeight > 200 && twoRowsHeight < 500)
        if let path = CommandLine.arguments.dropFirst().first {
            toolPanel.setContentSize(model.expandedSize)
            overlay.layoutSubtreeIfNeeded()
            if let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
                overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Preview encoding failed") }
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
        model.clipboard.removeLast()
        overlay.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert((model.toolContentHeights[.clipboard] ?? 0) < twoRowsHeight,
               "Deleting a record should shrink the list and panel instead of leaving blank space")
        model.setClipboard(false)
        assert(!AppModel(startMonitoring: false, clipboardPreferences: preferences).clipboardEnabled)
        print("PASS: menu and timer intrinsic height, top-anchored growth, clipboard image/deletion layout, preference persistence and lock pause")
    }
}
