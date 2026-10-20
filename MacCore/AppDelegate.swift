import AppKit
import SwiftUI
import Carbon

@main
enum MacCoreEntry {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Xcode and local build paths can bypass LaunchServices' usual single-instance behavior.
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) + [.current]
            let first = running.filter { !$0.isTerminated }.min { lhs, rhs in
                let left = lhs.launchDate ?? .distantFuture, right = rhs.launchDate ?? .distantFuture
                return left == right ? lhs.processIdentifier < rhs.processIdentifier : left < right
            }
            if let first, first.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                first.activate()
                return
            }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    var overlay: OverlayController?
    private var statusItem: NSStatusItem!
    private let menuPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var menuOutsideMonitor: Any?
    private var menuLocalMonitor: Any?
    private var settings: NSWindow?
    private var cleaningWindow: NSWindow?
    private var cleaningMode: CleaningMode?
    private var cleaningKeyboardMonitor: Any?
    private var cleaningWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var menuContentHeight: CGFloat = 360

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.showSettings = { [weak self] in self?.showSettings() }
        model.hideMenuPanel = { [weak self] in self?.menuPanel.orderOut(nil) }
        model.startKeyboardCleaning = { [weak self] in self?.showCleaning(.keyboard) }
        model.startMonitorCleaning = { [weak self] in self?.showCleaning(.monitor) }
        overlay = OverlayController(model: model)
        buildMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "MacCore")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.toolTip = "MacCore · Control + Option + Space"
        menuPanel.isOpaque = false
        menuPanel.backgroundColor = .clear
        menuPanel.hasShadow = true
        menuPanel.level = .popUpMenu
        menuPanel.hidesOnDeactivate = false
        menuPanel.isReleasedWhenClosed = false
        let menuHost = NSHostingView(rootView: MenuPopoverView(model: model) { [weak self] height in
            guard let self, height.isFinite, height > 0, self.menuContentHeight != height else { return }
            self.menuContentHeight = height
            if self.menuPanel.isVisible { self.positionMenuPanel(animated: true) }
        })
        menuHost.sizingOptions = []
        menuPanel.contentView = menuHost
        menuOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.menuPanel.isVisible, !self.menuPanel.frame.contains(NSEvent.mouseLocation) else { return }
            self.menuPanel.orderOut(nil)
        }
        menuLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.menuPanel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.menuPanel.orderOut(nil); return nil }
            if event.type == .leftMouseDown, event.window !== self.menuPanel { self.menuPanel.orderOut(nil) }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuPanel.orderOut(nil) }
        })
        registerHotKey()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockSession() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlockSession() }
        })
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(lockSession), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(unlockSession), name: .init("com.apple.screenIsUnlocked"), object: nil)
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showSettings()
        }
    }

    @objc private func lockSession() {
        model.setFeedbackActive(false)
        menuPanel.orderOut(nil)
        overlay?.setSessionActive(false)
    }
    @objc private func unlockSession() {
        model.setFeedbackActive(true)
        overlay?.setSessionActive(true)
    }

    @objc private func togglePopover() {
        if menuPanel.isVisible { menuPanel.orderOut(nil); return }
        guard statusItem.button?.window?.screen != nil else { return }
        model.refreshQuickControlStates()
        overlay?.close()
        positionMenuPanel(animated: false)
        menuPanel.orderFrontRegardless()
    }

    private func positionMenuPanel(animated: Bool) {
        guard let button = statusItem.button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = OverlayLayout.menuPanelFrame(anchor: anchor, visible: screen.visibleFrame, size: CGSize(width: 340, height: menuContentHeight))
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                menuPanel.animator().setFrame(frame, display: true)
            }
        } else { menuPanel.setFrame(frame, display: true) }
    }

    @objc private func showSettings() {
        menuPanel.orderOut(nil)
        overlay?.close()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "MacCore 설정"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.setFrameAutosaveName("MacCore.Settings")
            window.center()
            settings = window
        }
        NSApp.setActivationPolicy(.regular)
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === cleaningWindow {
            cleaningWork?.cancel()
            cleaningWork = nil
            if let cleaningKeyboardMonitor { NSEvent.removeMonitor(cleaningKeyboardMonitor) }
            cleaningKeyboardMonitor = nil
            cleaningWindow = nil
            cleaningMode = nil
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settings?.isVisible != true { NSApp.setActivationPolicy(.accessory) }
        }
    }

    private func showCleaning(_ mode: CleaningMode) {
        menuPanel.orderOut(nil)
        overlay?.close()
        cleaningWindow?.close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let deadline = Date().addingTimeInterval(30)
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.delegate = self
        window.contentView = NSHostingView(rootView: CleaningModeView(mode: mode, deadline: deadline) { [weak self] in
            self?.cleaningWindow?.close()
        })
        cleaningMode = mode
        cleaningWindow = window
        if mode == .keyboard {
            cleaningKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self, self.cleaningMode == .keyboard, self.cleaningWindow?.isKeyWindow == true else { return event }
                return nil
            }
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let work = DispatchWorkItem { [weak window] in window?.close() }
        cleaningWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.tray.contains(where: \.temporary) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "임시 캡처를 확인하셨나요?"
        alert.informativeText = "임시 캡처는 트레이에서 다시 복원되지 않습니다. 필요한 이미지는 종료 전에 저장해 주세요."
        alert.addButton(withTitle: "돌아가기")
        alert.addButton(withTitle: "종료")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.tab = .files
            model.revealOverlay()
            model.isPinned = true
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaningWork?.cancel()
        if let cleaningKeyboardMonitor { NSEvent.removeMonitor(cleaningKeyboardMonitor) }
        overlay?.stop()
        if let menuOutsideMonitor { NSEvent.removeMonitor(menuOutsideMonitor) }
        if let menuLocalMonitor { NSEvent.removeMonitor(menuLocalMonitor) }
        model.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }

    private func buildMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        main.addItem(applicationItem)
        let application = NSMenu()
        let about = NSMenuItem(title: "MacCore에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(about)
        application.addItem(.separator())
        let statusItem = NSMenuItem(title: "시스템 상태 열기", action: #selector(togglePopover), keyEquivalent: "1")
        statusItem.target = self
        application.addItem(statusItem)
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        application.addItem(settingsItem)
        application.addItem(.separator())
        application.addItem(withTitle: "MacCore 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = application
        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "편집")
        for (title, action, key) in [("실행 취소", "undo:", "z"), ("오려두기", "cut:", "x"), ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func registerHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4D434F52, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { delegate.overlay?.toggle() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let identifier = EventHotKeyID(signature: 0x4D434F52, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.notify("빠른 열기 단축키가 다른 앱에서 사용 중입니다. 메뉴 막대를 이용해 주세요.") }
    }
}

private enum CleaningMode {
    case keyboard, monitor
}

private struct CleaningModeView: View {
    let mode: CleaningMode
    let deadline: Date
    let onClose: () -> Void
    @State private var selectedColor = 0
    private let colors: [Color] = [.black, .white, .red, .green, .blue]

    var body: some View {
        ZStack {
            (mode == .monitor ? colors[selectedColor] : .black).ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: mode == .keyboard ? "keyboard" : "display")
                    .font(.system(size: 38, weight: .light))
                Text(mode == .keyboard ? "키보드 청소 모드" : "모니터 청소 모드")
                    .font(.system(size: 20, weight: .semibold))
                Text(mode == .keyboard ? "키 입력은 잠시 차단됩니다" : "색상을 바꿔가며 화면을 닦으세요")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                if mode == .monitor {
                    HStack(spacing: 12) {
                        ForEach(colors.indices, id: \.self) { index in
                            Button { selectedColor = index } label: {
                                Circle().fill(colors[index]).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: selectedColor == index ? 2 : 0.5))
                                    .contentShape(Circle())
                            }.buttonStyle(.plain).accessibilityLabel("화면 색상 \(index + 1)")
                        }
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("마우스로 완료를 누르세요 · \(max(0, Int(deadline.timeIntervalSince(context.date))))초 후 자동 종료")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                }
                Button("완료", action: onClose)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 28).frame(height: 44).background(.white, in: Capsule())
                    .buttonStyle(.plain).padding(.bottom, 26)
            }
            .foregroundStyle(.white)
            .padding(30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}
