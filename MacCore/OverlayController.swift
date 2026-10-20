import AppKit
import SwiftUI
import Combine

extension NSScreen {
    var displayID: String { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? localizedName }
}

private final class DotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // This panel deliberately occupies the menu bar. AppKit's normal clamp would move it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class TrackingHost: NSHostingView<OverlayView> {
    var entered: () -> Void = {}
    var exited: () -> Void = {}
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let model = rootView.model
        let active = model.expanded || model.compactMusic || model.compactTimer || model.islandNotice != nil
        let rect = active ? bounds : NSRect(x: (bounds.width - 76) / 2,
                                            y: max(0, bounds.height - model.menuBarHeight),
                                            width: 76, height: min(bounds.height, 24))
        var options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited]
        if active { options.insert(.inVisibleRect) }
        let area = NSTrackingArea(rect: rect, options: options, owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayController {
    private let model: AppModel
    private let panel: DotPanel
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private var fileDragTimer: Timer?
    private var fileDragMonitor: Any?
    private var fileDrag = FileDragActivation(changeCount: NSPasteboard(name: .drag).changeCount)
    private var fileDragScreen: NSScreen?
    private var sessionActive = true

    init(model: AppModel) {
        self.model = model
        panel = DotPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.isMovable = false
        panel.animationBehavior = .none
        let host = TrackingHost(rootView: OverlayView(model: model))
        host.sizingOptions = []
        host.entered = { [weak self] in self?.pointerEntered() }
        host.exited = { [weak self] in self?.pointerExited() }
        panel.contentView = host
        model.revealOverlay = { [weak self] in self?.open(); self?.scheduleClose(after: 5) }
        model.revealTool = { [weak self] tab in self?.open(preferredTab: tab) }
        model.toggleOverlay = { [weak self] in self?.toggle() }
        model.closeOverlay = { [weak self] in self?.close() }
        model.$dotEnabled.combineLatest(model.$dotVisible).receive(on: RunLoop.main).sink { [weak self] _, _ in self?.reposition() }.store(in: &subscriptions)
        model.$preferredDisplay.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reposition() }.store(in: &subscriptions)
        model.$tab.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$dropChoiceActive.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$countdown.map(\.isRunning).removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$music.map { $0.playing && $0.hasTrack }.combineLatest(model.$musicConnected)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main).sink { [weak self] _, _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$toolContentHeights.removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$islandHovered.removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$islandNotice.map { $0?.id }.removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openWork?.cancel(); self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$tray.map(\.count).removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(animated: true) }.store(in: &subscriptions)
        model.$isPinned.dropFirst().receive(on: RunLoop.main).sink { [weak self] pinned in
            if !pinned { self?.scheduleClose(after: 0.65) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            self?.close(); self?.reposition()
        }.store(in: &subscriptions)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            if self.model.expanded, !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.model.expanded, event.type == .keyDown, event.keyCode == 53 { self.close(); return nil }
            if event.type == .leftMouseDown {
                if self.model.expanded, event.window !== self.panel { self.close() }
            }
            return event
        }
        fileDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.pollFileDrag() }
        startFileDragMonitoring()
        reposition()
    }

    private func startFileDragMonitoring() {
        fileDragTimer?.invalidate()
        fileDrag = FileDragActivation(changeCount: NSPasteboard(name: .drag).changeCount)
        // Drag sessions may consume mouse events, so this fallback does not depend on mouse-down delivery.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFileDrag() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        fileDragTimer = timer
    }

    private func pollFileDrag() {
        guard sessionActive else { return }
        let board = NSPasteboard(name: .drag)
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        guard mouseDown else {
            let wasActive = fileDrag.active
            _ = fileDrag.update(changeCount: board.changeCount, mouseDown: false, hasFiles: false, nearIsland: false)
            if wasActive, model.dropChoiceActive { scheduleClose(after: 0.65) }
            return
        }
        guard model.dotVisible, model.dotEnabled, !fileDrag.active else { return }
        guard let dragScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        let activationZone = OverlayLayout.fileDragActivationFrame(screen: dragScreen.frame, compactWidth: model.compactSize.width)
        guard activationZone.contains(NSEvent.mouseLocation) else { return }
        let hasURL = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasPaths = (board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String])?.isEmpty == false
        let hasPromise = NSFilePromiseReceiver.readableDraggedTypes.contains {
            board.types?.contains(NSPasteboard.PasteboardType($0)) == true
        }
        guard fileDrag.update(changeCount: board.changeCount, mouseDown: true,
                              hasFiles: hasURL || hasPaths || hasPromise,
                              nearIsland: true) else { return }
        fileDragScreen = dragScreen
        openWork?.cancel()
        closeWork?.cancel()
        model.tab = .files
        model.dropChoiceActive = true
        open(preferredTab: .files)
    }

    private var screen: NSScreen? {
        fileDragScreen ?? NSScreen.screens.first { $0.displayID == model.preferredDisplay } ?? NSScreen.screens.first
    }

    func reposition(animated: Bool = false) {
        resizeWork?.cancel()
        guard sessionActive, model.dotVisible, model.dotEnabled || model.expanded, let screen else { panel.orderOut(nil); return }
        panel.level = model.expanded ? .popUpMenu : .statusBar
        let barHeight = OverlayLayout.menuBarHeight(screen: screen.frame, visible: screen.visibleFrame)
        if model.menuBarHeight != barHeight { model.menuBarHeight = barHeight }
        if model.screenTopInset != screen.safeAreaInsets.top { model.screenTopInset = screen.safeAreaInsets.top }
        let size = model.overlayWindowSize
        let target = OverlayLayout.frame(in: screen.frame, visible: screen.visibleFrame, size: size)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Keep enough canvas for the SwiftUI spring; shrink the window after the shape settles.
            let canvas = CGSize(width: max(panel.frame.width, target.width), height: max(panel.frame.height, target.height))
            panel.setFrame(OverlayLayout.frame(in: screen.frame, visible: screen.visibleFrame, size: canvas), display: true)
            let work = DispatchWorkItem { [weak self] in self?.panel.setFrame(target, display: true) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } else { panel.setFrame(target, display: true) }
        panel.orderFrontRegardless()
    }

    func toggle() { model.expanded ? close() : open() }

    func open(preferredTab: PanelTab? = nil) {
        guard sessionActive, model.dotVisible else { return }
        openWork?.cancel()
        closeWork?.cancel()
        if let preferredTab { model.tab = preferredTab }
        guard !model.expanded else { return }
        resizeWork?.cancel()
        model.islandHovered = false
        model.hideMenuPanel()
        if preferredTab == nil {
            if model.compactTimer { model.tab = .timer }
            else if model.compactMusic { model.tab = .music }
        }
        guard let screen else { return }
        panel.level = .popUpMenu
        panel.setFrame(OverlayLayout.frame(in: screen.frame, visible: screen.visibleFrame, size: model.expandedSize), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.expanded = true
    }

    func close() {
        openWork?.cancel()
        closeWork?.cancel()
        fileDrag.dismiss(changeCount: NSPasteboard(name: .drag).changeCount)
        model.isPinned = false
        model.dropChoiceActive = false
        model.expanded = false
        fileDragScreen = nil
        panel.level = .statusBar
        model.islandHovered = false
        if let screen, model.compactMusic || model.islandNotice != nil {
            let compactFrame = OverlayLayout.frame(in: screen.frame, visible: screen.visibleFrame, size: model.overlayWindowSize)
            model.islandHovered = compactFrame.contains(NSEvent.mouseLocation)
        }
        panel.hasShadow = false
        panel.resignKey()
        reposition(animated: true)
    }

    private func pointerEntered() {
        closeWork?.cancel()
        openWork?.cancel()
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        guard !model.expanded else { return }
        if model.compactMusic || model.islandNotice != nil { model.islandHovered = true; return }
        openWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func pointerExited() {
        openWork?.cancel()
        model.islandHovered = false
        scheduleClose(after: 0.65)
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.isPinned else { return }
            if self.fileDrag.active && NSEvent.pressedMouseButtons & 1 != 0 { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if !active {
            fileDragTimer?.invalidate()
            fileDragTimer = nil
            close()
            panel.orderOut(nil)
        } else { startFileDragMonitoring(); reposition() }
    }

    func stop() {
        openWork?.cancel()
        closeWork?.cancel()
        resizeWork?.cancel()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        fileDragTimer?.invalidate()
        fileDragTimer = nil
        if let fileDragMonitor { NSEvent.removeMonitor(fileDragMonitor) }
        subscriptions.removeAll()
        panel.orderOut(nil)
    }
}
