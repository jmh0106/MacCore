import AppKit
import ApplicationServices

@MainActor
final class ScreenshotMonitor {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var onScreenshot: ((URL) -> Void)?

    func start(onScreenshot: @escaping (URL) -> Void) {
        stop()
        self.onScreenshot = onScreenshot
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", Date() as NSDate)
        query.notificationBatchingInterval = 0.3
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.receive(notification) }
            })
        }
        query.start()
    }

    private func receive(_ notification: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let items: [NSMetadataItem]
        if notification.name == .NSMetadataQueryDidFinishGathering {
            items = query.results.compactMap { $0 as? NSMetadataItem }
        } else {
            items = ((notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? [])
                + ((notification.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? [])
        }
        for item in items {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            onScreenshot?(URL(fileURLWithPath: path))
        }
    }

    func stop() {
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onScreenshot = nil
    }
}

@MainActor
final class NotificationMonitor {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var workspaceObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var visible = Set<String>()
    private var onNotice: ((IslandNotice) -> Void)?
    private(set) var error: String?

    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(onNotice: @escaping (IslandNotice) -> Void) -> Bool {
        stop()
        error = nil
        guard Self.hasAccess else { error = "손쉬운 사용 권한을 허용한 뒤 다시 켜 주세요."; return false }
        self.onNotice = onNotice
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { [weak self] event in
                guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.notificationcenterui" else { return }
                MainActor.assumeIsolated { self?.attach(to: app) }
            }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
            attach(to: app)
            return observer != nil
        }
        return true
    }

    private func attach(to app: NSRunningApplication) {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        application = nil
        visible.removeAll()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var created: AXObserver?
        let result = AXObserverCreate(app.processIdentifier, { _, _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<NotificationMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.scheduleRead() }
        }, &created)
        guard result == .success, let created else { error = "알림 배너 감지를 시작하지 못했습니다."; return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let names = [kAXWindowCreatedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification]
        let registered = names.map { AXObserverAddNotification(created, element, $0 as CFString, context) }
        guard registered.contains(.success) else { error = "이 macOS에서 알림 배너 변경을 감지하지 못했습니다."; return }
        observer = created
        application = element
        visible = Set(notices().map(\.0))
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func scheduleRead() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, Self.hasAccess else { self?.stop(); return }
            let current = self.notices()
            for (key, notice) in current where !self.visible.contains(key) { self.onNotice?(notice) }
            self.visible = Set(current.map(\.0))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func notices() -> [(String, IslandNotice)] {
        guard let application else { return [] }
        var result: [(String, IslandNotice)] = []
        var queue = (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        while !queue.isEmpty, visited < 256, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue.removeFirst()
            visited += 1
            let subrole = string(element, kAXSubroleAttribute)
            if ["AXNotificationCenterBanner", "AXNotificationCenterAlert"].contains(subrole), let notice = notice(from: element) {
                result.append(("\(CFHash(element)):\(notice.title):\(notice.detail)", notice))
            } else {
                queue.append(contentsOf: children(element).prefix(64))
            }
        }
        return result
    }

    private func notice(from banner: AXUIElement) -> IslandNotice? {
        let description = string(banner, "AXAttributedDescription")
        let appName = description.components(separatedBy: ", ").first ?? "알림"
        var fields: [String: String] = [:]
        var texts: [String] = []
        var queue = children(banner)
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        while !queue.isEmpty, visited < 96, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == kAXStaticTextRole {
                let text = string(element, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    texts.append(text)
                    fields[string(element, kAXIdentifierAttribute)] = text
                }
            }
            queue.append(contentsOf: children(element).prefix(32))
        }
        let title = fields["title"] ?? texts.first ?? appName
        guard !title.isEmpty else { return nil }
        let detail = [fields["subtitle"], fields["body"]].compactMap { $0 }.joined(separator: " ")
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }
        return IslandNotice(title: String(title.prefix(140)), detail: String((detail.isEmpty ? (texts.dropFirst().joined(separator: " ")) : detail).prefix(240)),
                            symbol: "bell.fill", kind: .notification, image: app?.icon, appBundleID: app?.bundleIdentifier,
                            sourceAppName: appName)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        let value = attribute(element, name)
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string ?? ""
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        application = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        visible.removeAll()
        onNotice = nil
    }
}
