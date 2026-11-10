import AppKit
import MediaRemoteAdapter
import Combine
import IOKit.pwr_mgt
import UniformTypeIdentifiers
import CryptoKit

enum PanelTab: String, CaseIterable, Identifiable {
    case timer = "타이머", files = "파일", clipboard = "복사 기록", music = "음악"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .timer: "timer"
        case .files: "tray"
        case .clipboard: "clipboard"
        case .music: "music.note"
        }
    }
}

enum TimerMode: String, CaseIterable, Identifiable {
    case timer = "타이머", stopwatch = "스톱워치", pomodoro = "포모도로"
    var id: String { rawValue }
}

struct TrayFile: Identifiable {
    let id = UUID()
    let url: URL
    var temporary = false
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}

struct ClipboardItem: Identifiable, Codable {
    enum Payload: Codable { case text(String), textFile(URL, Int), image(Data), imageFile(URL, Int), files([URL]), filesFile(URL, Int) }
    var id = UUID()
    var date = Date()
    var payload: Payload
    let contentKey: Data
    var pinned = false

    init?(payload: Payload) {
        self.payload = payload
        var hash = SHA256()
        switch payload {
        case .text(let text):
            hash.update(data: Data("text:".utf8))
            hash.update(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
        case .files(let urls):
            hash.update(data: Data("files:".utf8))
            let paths = Set(urls.map { $0.standardizedFileURL.absoluteString }).sorted()
            hash.update(data: Data(paths.joined(separator: "\0").utf8))
        case .image(let data):
            // Compare decoded pixels so PNG/TIFF copies of the same image share one record.
            guard let decodedImage = NSImage(data: data) else { return nil }
            if let image = decodedImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let space = CGColorSpace(name: CGColorSpace.sRGB),
               let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
               let pixels = bitmap.data {
                bitmap.setBlendMode(.copy)
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                hash.update(data: Data("image:rgba:\(image.width)x\(image.height):".utf8))
                withExtendedLifetime(bitmap) {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: bitmap.bytesPerRow * image.height))
                }
            } else {
                hash.update(data: Data("image:encoded:".utf8))
                hash.update(data: data)
            }
        case .imageFile, .textFile, .filesFile:
            return nil
        }
        contentKey = Data(hash.finalize())
    }
    var title: String {
        switch payload {
        case .text, .textFile: return String((text ?? "").prefix(160)).replacingOccurrences(of: "\n", with: " ")
        case .image, .imageFile: return "복사한 이미지"
        case .files, .filesFile: return (files ?? []).map(\.lastPathComponent).joined(separator: ", ")
        }
    }
    var imageURL: URL? {
        if case .imageFile(let url, _) = payload { return url }
        return nil
    }
    var storedURL: URL? {
        switch payload {
        case .textFile(let url, _), .imageFile(let url, _), .filesFile(let url, _): url
        default: nil
        }
    }
    var text: String? {
        switch payload {
        case .text(let value): value
        case .textFile(let url, _): try? String(contentsOf: url, encoding: .utf8)
        default: nil
        }
    }
    var files: [URL]? {
        switch payload {
        case .files(let urls): urls
        case .filesFile(let url, _): (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([URL].self, from: $0) }
        default: nil
        }
    }
    var image: NSImage? {
        switch payload {
        case .image(let data): NSImage(data: data)
        case .imageFile(let url, _): NSImage(contentsOf: url)
        default: nil
        }
    }
    var searchableText: String {
        text ?? title
    }
    var symbol: String {
        switch payload { case .text, .textFile: "text.alignleft"; case .image, .imageFile: "photo"; case .files, .filesFile: "doc.on.doc" }
    }
    var size: Int {
        switch payload {
        case .text(let text): text.utf8.count
        case .textFile(_, let size), .filesFile(_, let size): size
        case .image(let data): data.count
        case .imageFile(_, let size): size
        case .files(let urls): urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        }
    }
    static let imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacCore-Clipboard", isDirectory: true)
}

struct Favorite: Identifiable, Codable {
    var id = UUID()
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct IslandNotice: Identifiable {
    enum Kind { case clipboard, screenshot, notification, system, power }
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let kind: Kind
    var target: PanelTab?
    var image: NSImage?
    var appBundleID: String?
    var sourceAppName: String?
    var width: CGFloat {
        switch kind {
        case .clipboard: 336
        case .screenshot: 372
        case .notification, .power: 320
        case .system: 360
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "일반", island = "노치", overview = "상태", timer = "타이머"
    case files = "파일", clipboard = "복사 기록", music = "음악", notifications = "알림", favorites = "즐겨찾기"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .island: "capsule"
        case .overview: "waveform.path.ecg"
        case .timer: PanelTab.timer.symbol
        case .files: PanelTab.files.symbol
        case .clipboard: PanelTab.clipboard.symbol
        case .music: PanelTab.music.symbol
        case .notifications: "bell.badge"
        case .favorites: "star"
        }
    }
    init(tool: PanelTab) {
        switch tool {
        case .timer: self = .timer
        case .files: self = .files
        case .clipboard: self = .clipboard
        case .music: self = .music
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: PanelTab = .timer
    @Published var settingsPage: SettingsPage = .general
    @Published var expanded = false
    @Published var dropChoiceActive = false
    @Published var islandHovered = false
    @Published var islandNotice: IslandNotice?
    @Published var isPinned = false
    @Published var dotVisible = true
    @Published var dotEnabled = UserDefaults.standard.object(forKey: "dotEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dotEnabled, forKey: "dotEnabled") }
    }
    @Published var snapshot = SystemSnapshot()
    let aiUsage = AIUsageStore()
    @Published var countdown = Countdown()
    @Published var remaining: TimeInterval = 25 * 60
    @Published var timerSeconds = 25 * 60
    @Published var timerMode: TimerMode = .timer
    @Published var stopwatchElapsed: TimeInterval = 0
    @Published var stopwatchRunning = false
    @Published var pomodoroOnBreak = false
    @Published var pomodoroCycles = 0
    @Published var pomodoroFocusMinutes = 25 {
        didSet { UserDefaults.standard.set(pomodoroFocusMinutes, forKey: "pomodoroFocusMinutes") }
    }
    @Published var pomodoroBreakMinutes = 5 {
        didSet { UserDefaults.standard.set(pomodoroBreakMinutes, forKey: "pomodoroBreakMinutes") }
    }
    @Published var pomodoroSessionCount = 4 {
        didSet { UserDefaults.standard.set(pomodoroSessionCount, forKey: "pomodoroSessionCount") }
    }
    @Published var menuBarHeight: CGFloat = 24
    @Published var screenTopInset: CGFloat = 0
    @Published var tray: [TrayFile] = []
    @Published var clipboard: [ClipboardItem] = [] {
        didSet {
            if let clipboardDirectory {
                guard clipboardStorageReady else { return }
                do {
                    try FileManager.default.createDirectory(at: clipboardDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try JSONEncoder().encode(clipboard).write(to: clipboardDirectory.appendingPathComponent("index.json"), options: .atomic)
                } catch {
                    notify("복사 기록을 저장하지 못했습니다")
                    return
                }
            }
            let retained = Set(clipboard.compactMap(\.storedURL))
            for url in Set(oldValue.compactMap(\.storedURL)).subtracting(retained) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    @Published var clipboardEnabled = false {
        didSet { clipboardPreferences.set(clipboardEnabled, forKey: "clipboardEnabled") }
    }
    @Published var copyFeedbackEnabled = UserDefaults.standard.object(forKey: "copyFeedback") as? Bool ?? true {
        didSet { UserDefaults.standard.set(copyFeedbackEnabled, forKey: "copyFeedback"); restartClipboardMonitoring() }
    }
    @Published var screenshotDetectionEnabled = UserDefaults.standard.object(forKey: "screenshotDetection") as? Bool ?? true {
        didSet { UserDefaults.standard.set(screenshotDetectionEnabled, forKey: "screenshotDetection"); updateScreenshotMonitoring() }
    }
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationBanners") {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationBanners") }
    }
    @Published var aiCompletionNotificationsEnabled = UserDefaults.standard.bool(forKey: "aiCompletionNotifications") {
        didSet {
            UserDefaults.standard.set(aiCompletionNotificationsEnabled, forKey: "aiCompletionNotifications")
            if monitoringStarted { updateNotificationMonitoring() }
        }
    }
    @Published var notificationError: String?
    @Published var awakeUntil: Date?
    @Published private(set) var scrollReversed = SystemQuickControls.scrollReversed
    @Published private(set) var fastInputEnabled = false
    @Published private(set) var alertSoundsMuted = false
    @Published var message: String?
    @Published var capturing = false
    @Published var favorites: [Favorite] = []
    @Published var music = MusicState()
    @Published var musicConnected = false
    @Published var musicBusy = false
    @Published var toolContentHeights: [PanelTab: CGFloat] = [:]
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "timerSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "timerSound") }
    }
    @Published var excludedApps = UserDefaults.standard.string(forKey: "excludedApps") ?? "com.1password.1password\ncom.agilebits.onepassword7\ncom.bitwarden.desktop\norg.keepassxc.keepassxc" {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps") }
    }
    @Published var preferredDisplay = UserDefaults.standard.string(forKey: "display") ?? "" {
        didSet { UserDefaults.standard.set(preferredDisplay, forKey: "display") }
    }

    var showSettings: () -> Void = {}
    var toggleOverlay: () -> Void = {}
    var revealOverlay: () -> Void = {}
    var revealTool: (PanelTab) -> Void = { _ in }
    var closeOverlay: () -> Void = {}
    var hideMenuPanel: () -> Void = {}
    var startKeyboardCleaning: () -> Void = {}
    var startMonitorCleaning: () -> Void = {}
    var compactTimer: Bool { countdown.isRunning }
    var pomodoroActive: Bool { countdownIsPomodoro }
    var compactMusic: Bool { musicConnected && music.playing && music.hasTrack && !compactTimer }
    var compactSize: CGSize {
        OverlayLayout.compactSize(menuBarHeight: menuBarHeight, music: compactMusic, timer: compactTimer,
                                  noticeWidth: islandNotice?.width, hovered: islandHovered)
    }
    var overlayWindowSize: CGSize {
        if expanded { return expandedSize }
        if !compactMusic && !compactTimer && islandNotice == nil {
            return CGSize(width: 200, height: menuBarHeight + 44)
        }
        return compactSize
    }
    var expandedSize: CGSize {
        if tab == .files && dropChoiceActive { return CGSize(width: 296, height: screenTopInset + 136) }
        let fallbackHeight: CGFloat
        switch tab {
        case .timer: fallbackHeight = 372
        case .music: fallbackHeight = 284
        case .files: fallbackHeight = tray.isEmpty ? 300 : 420
        case .clipboard: fallbackHeight = 350
        }
        return CGSize(width: 360, height: (toolContentHeights[tab] ?? fallbackHeight) + screenTopInset)
    }
    private var timer: Timer?
    private var stopwatchStartedAt: TimeInterval?
    private var stopwatchAccumulated: TimeInterval = 0
    private var countdownIsPomodoro = false
    private let monitor = SystemMonitor()
    private let fastInputSwitcher = FastInputSwitcher()
    private var ticks = 0
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var assertionID: IOPMAssertionID = 0
    private var toastWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    private var clipboardTimer: Timer?
    private var monitoringStarted = false
    private var feedbackActive = true
    private let clipboardPreferences: UserDefaults
    private let clipboardDirectory: URL?
    private var clipboardStorageReady = true
    private let screenshotMonitor = ScreenshotMonitor()
    private let notificationMonitor = NotificationMonitor()
    var mediaController: MediaController?
    var musicTrack: TrackInfo.Payload?

    init(startMonitoring: Bool = true, clipboardPreferences: UserDefaults = .standard, clipboardDirectory: URL? = nil) {
        self.clipboardPreferences = clipboardPreferences
        self.clipboardDirectory = clipboardDirectory ?? (startMonitoring ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("MacCore/ClipboardHistory", isDirectory: true) : nil)
        clipboardEnabled = clipboardPreferences.bool(forKey: "clipboardEnabled")
        pomodoroFocusMinutes = min(180, max(1, UserDefaults.standard.object(forKey: "pomodoroFocusMinutes") as? Int ?? 25))
        pomodoroBreakMinutes = min(30, max(1, UserDefaults.standard.object(forKey: "pomodoroBreakMinutes") as? Int ?? 5))
        pomodoroSessionCount = min(12, max(1, UserDefaults.standard.object(forKey: "pomodoroSessionCount") as? Int ?? 4))
        if let directory = self.clipboardDirectory {
            let index = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: index.path) {
                do {
                    let saved = try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: index))
                    clipboard = saved.filter { item in
                        guard let url = item.storedURL, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                              UUID(uuidString: url.lastPathComponent) != nil else { return false }
                        return FileManager.default.fileExists(atPath: url.path)
                    }
                }
                catch { clipboardStorageReady = false; message = "저장된 복사 기록을 읽지 못했습니다" }
            }
        }
        guard startMonitoring else { return }
        fastInputSwitcher.onError = { [weak self] in self?.notify($0) }
        do {
            if UserDefaults.standard.bool(forKey: "fastInputEnabled") {
                try fastInputSwitcher.enable()
                fastInputEnabled = true
            } else { try fastInputSwitcher.disable() }
        } catch { notify(error.localizedDescription) }
        refreshQuickControlStates()
        monitoringStarted = true
        restartClipboardMonitoring()
        updateScreenshotMonitoring()
        if notificationsEnabled || aiCompletionNotificationsEnabled { updateNotificationMonitoring() }
        connectMusic()
        if let data = UserDefaults.standard.data(forKey: "favorites"),
           let saved = try? JSONDecoder().decode([Favorite].self, from: data) { favorites = saved }
        else {
            favorites = ["/System/Applications/System Settings.app", "/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Downloads"]
                .map { Favorite(url: URL(fileURLWithPath: $0)) }
        }
        restoreTimer()
        snapshot = monitor.sample()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker.tolerance = 0.05
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        if countdown.isRunning { alignTimerTick() }
    }

    private func tick() {
        ticks += 1
        consumeAICompletionSignals()
        let nextRemaining = countdown.remaining(at: ContinuousTime.now)
        if remaining != nextRemaining { remaining = nextRemaining }
        if stopwatchRunning, let stopwatchStartedAt {
            stopwatchElapsed = stopwatchAccumulated + ContinuousTime.now - stopwatchStartedAt
        }
        if countdown.finishIfNeeded(at: ContinuousTime.now) {
            persistTimer()
            if soundEnabled { NSSound.beep() }
            if countdownIsPomodoro {
                let next = PomodoroCycle.next(isOnBreak: pomodoroOnBreak,
                                              completedSessions: pomodoroCycles,
                                              sessionCount: pomodoroSessionCount)
                pomodoroOnBreak = next.isOnBreak
                pomodoroCycles = next.completedSessions
                if next.finished {
                    finishPomodoro()
                } else {
                    let seconds = pomodoroOnBreak ? TimeInterval(pomodoroBreakMinutes * 60) : PomodoroCycle.focusDuration(minutes: pomodoroFocusMinutes)
                    timerSeconds = Int(seconds)
                    countdown.start(seconds: seconds, at: ContinuousTime.now)
                    remaining = seconds
                    persistTimer()
                    showIslandNotice(IslandNotice(title: pomodoroOnBreak ? "휴식 시간" : "집중 시간", detail: "포모도로", symbol: "timer", kind: .system, target: .timer))
                }
            } else {
                countdownIsPomodoro = false
                tab = .timer
                showIslandNotice(IslandNotice(title: "타이머 완료", detail: "타이머", symbol: "timer", kind: .system, target: .timer))
            }
        }
        if let awakeUntil, awakeUntil <= Date() { setAwake(false) }
        if fastInputEnabled && ticks % 5 == 0 { fastInputSwitcher.refreshKeyboards() }
        if ticks % (expanded ? 2 : 5) == 0 {
            let previous = snapshot
            snapshot = monitor.sample()
            if previous.onAC != snapshot.onAC, snapshot.battery != nil {
                showIslandNotice(IslandNotice(title: snapshot.onAC ? "전원이 연결되었습니다" : "배터리를 사용합니다",
                                              detail: "전원", symbol: "bolt.fill", kind: .power))
            }
        }
        updateMusicPosition()
    }

    func notify(_ text: String, reveal: Bool = false) {
        toastWork?.cancel()
        message = text
        if reveal { revealOverlay() }
        else if !expanded { showIslandNotice(IslandNotice(title: text, detail: "MacCore", symbol: "info.circle", kind: .system)) }
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func showIslandNotice(_ notice: IslandNotice, duration: TimeInterval = 3.2) {
        guard feedbackActive else { return }
        noticeWork?.cancel()
        islandNotice = notice
        scheduleNoticeDismiss(id: notice.id, after: duration)
    }

    func receiveAICompletion(provider: String) {
        guard aiCompletionNotificationsEnabled,
              let provider = AICompletionClassifier.normalizedProvider(provider) else { return }
        showIslandNotice(IslandNotice(title: "AI 작업 완료", detail: provider, symbol: "checkmark.circle.fill", kind: .notification), duration: 5)
    }

    private func consumeAICompletionSignals() {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/MacCore/AI Completion Signals")
        for (name, provider) in [("codex", "Codex"), ("claude-code", "Claude Code"), ("antigravity", "Antigravity")] {
            let file = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            try? FileManager.default.removeItem(at: file)
            guard String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == name else { continue }
            receiveAICompletion(provider: provider)
        }
    }

    private func scheduleNoticeDismiss(id: UUID, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.islandNotice?.id == id else { return }
            if self.islandHovered { self.scheduleNoticeDismiss(id: id, after: 1); return }
            self.islandNotice = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func openIslandNotice() {
        guard let notice = islandNotice else { return }
        noticeWork?.cancel()
        islandNotice = nil
        if let target = notice.target { revealTool(target) }
        else if let bundleID = notice.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(url)
        }
    }

    private func restartClipboardMonitoring() {
        clipboardTimer?.invalidate()
        guard monitoringStarted, feedbackActive, clipboardEnabled || copyFeedbackEnabled else { clipboardTimer = nil; return }
        let poller = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClipboard(source: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
        }
        poller.tolerance = 0.05
        RunLoop.main.add(poller, forMode: .common)
        clipboardTimer = poller
    }

    private func updateScreenshotMonitoring() {
        screenshotMonitor.stop()
        guard monitoringStarted, feedbackActive, screenshotDetectionEnabled else { return }
        screenshotMonitor.start { [weak self] url in self?.receiveScreenshot(url) }
    }

    func receiveScreenshot(_ url: URL, temporary: Bool = false) {
        guard feedbackActive, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        if let index = tray.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            if temporary { tray[index].temporary = true }
            return
        }
        tray.append(TrayFile(url: url, temporary: temporary))
        showIslandNotice(IslandNotice(title: "스크린샷 감지됨", detail: "파일 트레이", symbol: "viewfinder", kind: .screenshot,
                                      target: .files))
    }

    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        updateNotificationMonitoring()
    }

    private func updateNotificationMonitoring() {
        notificationMonitor.stop()
        notificationError = nil
        guard (notificationsEnabled || aiCompletionNotificationsEnabled), feedbackActive else { return }
        guard notificationMonitor.start(onNotice: { [weak self] notice in
            guard let self else { return }
            if self.aiCompletionNotificationsEnabled,
               let provider = AICompletionClassifier.provider(appName: notice.sourceAppName ?? "", bundleID: notice.appBundleID,
                                                               title: notice.title, detail: notice.detail) {
                self.showIslandNotice(IslandNotice(title: "AI 작업 완료", detail: provider, symbol: "checkmark.circle.fill",
                                                   kind: .notification, image: notice.image, appBundleID: notice.appBundleID,
                                                   sourceAppName: notice.sourceAppName), duration: 5)
            } else if self.notificationsEnabled {
                self.showIslandNotice(notice, duration: 5)
            }
        }) else {
            notificationError = notificationMonitor.error ?? "알림 배너 감지를 시작하지 못했습니다."
            return
        }
    }

    func setFeedbackActive(_ active: Bool) {
        if active { lastClipboardChange = NSPasteboard.general.changeCount }
        feedbackActive = active
        islandHovered = false
        islandNotice = nil
        noticeWork?.cancel()
        restartClipboardMonitoring()
        updateScreenshotMonitoring()
        if !active { notificationMonitor.stop() }
        else if notificationsEnabled || aiCompletionNotificationsEnabled { updateNotificationMonitoring() }
    }

    func startTimer() {
        countdownIsPomodoro = false
        countdown.start(seconds: Double(timerSeconds), at: ContinuousTime.now)
        remaining = countdown.remaining(at: ContinuousTime.now)
        alignTimerTick()
        persistTimer()
    }
    func selectTimerSeconds(_ value: Int) {
        guard !countdown.isRunning else { return }
        timerSeconds = min(86399, max(1, value))
        let seconds = Double(timerSeconds)
        countdown.restore(duration: seconds, remaining: seconds, running: false, at: ContinuousTime.now)
        remaining = seconds
        persistTimer()
    }
    func selectPomodoroFocusMinutes(_ value: Int) {
        guard !pomodoroActive else { return }
        pomodoroFocusMinutes = min(180, max(1, value))
    }
    func pauseTimer() { countdown.pause(at: ContinuousTime.now); remaining = countdown.paused; persistTimer() }
    func resumeTimer() { countdown.resume(at: ContinuousTime.now); alignTimerTick(); persistTimer() }
    func resetTimer() { countdownIsPomodoro = false; countdown.reset(); remaining = countdown.paused; persistTimer() }

    func startPomodoro() {
        if !countdownIsPomodoro && remaining <= 0 {
            pomodoroCycles = 0
            pomodoroOnBreak = false
        }
        countdownIsPomodoro = true
        let seconds = pomodoroOnBreak ? TimeInterval(pomodoroBreakMinutes * 60) : PomodoroCycle.focusDuration(minutes: pomodoroFocusMinutes)
        timerSeconds = Int(seconds)
        countdown.start(seconds: seconds, at: ContinuousTime.now)
        remaining = seconds
        alignTimerTick()
        persistTimer()
    }
    func resetPomodoro() {
        countdownIsPomodoro = false
        pomodoroOnBreak = false
        pomodoroCycles = 0
        let focusDuration = PomodoroCycle.focusDuration(minutes: pomodoroFocusMinutes)
        countdown.restore(duration: focusDuration, remaining: focusDuration, running: false, at: ContinuousTime.now)
        timerSeconds = Int(focusDuration)
        remaining = countdown.paused
        persistTimer()
    }
    private func finishPomodoro() {
        countdownIsPomodoro = false
        pomodoroOnBreak = false
        remaining = 0
        tab = .timer
        showIslandNotice(IslandNotice(title: "포모도로 완료", detail: "\(pomodoroCycles)회 세션", symbol: "timer", kind: .system, target: .timer))
    }
    private func alignTimerTick() { timer?.fireDate = Date(timeIntervalSinceNow: 1) }
    func startStopwatch() {
        guard !stopwatchRunning else { return }
        stopwatchStartedAt = ContinuousTime.now
        stopwatchRunning = true
    }
    func pauseStopwatch() {
        guard stopwatchRunning else { return }
        stopwatchAccumulated += ContinuousTime.now - (stopwatchStartedAt ?? ContinuousTime.now)
        stopwatchElapsed = stopwatchAccumulated
        stopwatchStartedAt = nil
        stopwatchRunning = false
    }
    func resetStopwatch() {
        stopwatchStartedAt = nil
        stopwatchAccumulated = 0
        stopwatchElapsed = 0
        stopwatchRunning = false
    }

    private func persistTimer() {
        let defaults = UserDefaults.standard
        defaults.set(countdown.duration, forKey: "timerDuration")
        defaults.set(countdown.remaining(at: ContinuousTime.now), forKey: "timerRemaining")
        if countdown.isRunning {
            defaults.set(Date().addingTimeInterval(countdown.remaining(at: ContinuousTime.now)), forKey: "timerDeadline")
        } else { defaults.removeObject(forKey: "timerDeadline") }
    }

    private func restoreTimer() {
        let defaults = UserDefaults.standard
        let duration = defaults.double(forKey: "timerDuration")
        guard duration.isFinite, duration > 0, duration <= 24 * 3600 else { return }
        timerSeconds = Int(duration)
        if let deadline = defaults.object(forKey: "timerDeadline") as? Date {
            let left = max(0, deadline.timeIntervalSinceNow)
            countdown.restore(duration: duration, remaining: left, running: true, at: ContinuousTime.now)
            if left == 0 { message = "앱이 닫힌 동안 타이머가 종료되었습니다" }
        } else {
            let left = min(duration, max(0, defaults.double(forKey: "timerRemaining")))
            countdown.restore(duration: duration, remaining: left, running: false, at: ContinuousTime.now)
        }
        remaining = countdown.remaining(at: ContinuousTime.now)
    }

    func setAwake(_ enabled: Bool) {
        if enabled, assertionID == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacCore 잠자기 방지 (1시간)" as CFString, &assertionID)
            if result != kIOReturnSuccess { assertionID = 0; notify("잠자기 방지를 켜지 못했습니다"); return }
            awakeUntil = Date().addingTimeInterval(3600)
        } else if !enabled {
            if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
            awakeUntil = nil
        }
    }

    func toggleScrollDirection() {
        do {
            try SystemQuickControls.setScrollReversed(!SystemQuickControls.scrollReversed)
            scrollReversed = SystemQuickControls.scrollReversed
            notify(scrollReversed ? "스크롤 방향을 반전했어요" : "자연스러운 스크롤로 바꿨어요")
        } catch {
            notify("스크롤 방향을 바꾸지 못했습니다")
        }
    }

    func refreshQuickControlStates() {
        scrollReversed = SystemQuickControls.scrollReversed
        if let volume = try? SystemQuickControls.alertVolume() { alertSoundsMuted = volume == 0 }
    }

    func toggleFastInput() {
        do {
            if fastInputEnabled { try fastInputSwitcher.disable() }
            else { try fastInputSwitcher.enable() }
            fastInputEnabled = fastInputSwitcher.isEnabled
            UserDefaults.standard.set(fastInputEnabled, forKey: "fastInputEnabled")
        } catch { notify(error.localizedDescription) }
    }

    func toggleAlertSounds() {
        do {
            let current = try SystemQuickControls.alertVolume()
            let target: Int
            if current > 0 {
                UserDefaults.standard.set(current, forKey: "alertVolumeBeforeMute")
                target = 0
            } else {
                target = max(1, UserDefaults.standard.object(forKey: "alertVolumeBeforeMute") as? Int ?? 50)
            }
            try SystemQuickControls.setAlertVolume(target)
            let updated = try SystemQuickControls.alertVolume()
            alertSoundsMuted = updated == 0
            if (updated == 0) != (target == 0) { notify("알림 음량 변경이 적용되지 않았습니다") }
        } catch { notify(error.localizedDescription) }
    }

    func addFiles(_ urls: [URL], temporary: Bool = false) {
        var missing = 0
        for url in urls {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            guard !tray.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            tray.append(TrayFile(url: url, temporary: temporary))
        }
        tab = .files
        if missing > 0 { notify("접근할 수 없는 파일 \(missing)개는 추가하지 않았습니다") }
    }

    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let fromDropChoice = dropChoiceActive
        let accepted = loadDroppedFiles(providers) { [weak self] urls in self?.addFiles(urls) }
        if accepted {
            dropChoiceActive = false
            tab = .files
            if fromDropChoice { closeOverlay() } else { revealOverlay() }
        }
        return accepted
    }

    func receiveAirDrop(_ providers: [NSItemProvider]) -> Bool {
        let fromDropChoice = dropChoiceActive
        let accepted = loadDroppedFiles(providers) { [weak self] urls in
            guard let self else { return }
            if fromDropChoice { self.dropChoiceActive = false; self.closeOverlay() }
            if !urls.isEmpty { self.shareFiles(urls) }
        }
        return accepted
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.filter {
            $0 != "com.apple.NSFilePromiseItemMetaData" && $0 != "com.apple.pasteboard.promised-file-content-type"
        }
        let supported = providers.compactMap { provider -> (NSItemProvider, String?)? in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return (provider, nil) }
            guard let type = provider.registeredTypeIdentifiers.first(where: { promiseTypes.contains($0) }) else { return nil }
            return (provider, type)
        }
        guard !supported.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        for (provider, promiseType) in supported {
            group.enter()
            if let promiseType {
                provider.loadFileRepresentation(forTypeIdentifier: promiseType) { [weak self] temporaryURL, error in
                    let localURL: URL?
                    if let temporaryURL {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacCore-DroppedFiles", isDirectory: true)
                        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(temporaryURL.lastPathComponent)")
                        do {
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: temporaryURL, to: destination)
                            localURL = destination
                        } catch { localURL = nil }
                    } else { localURL = nil }
                    DispatchQueue.main.async {
                        if let localURL { urls.append(localURL) }
                        else { self?.notify(error?.localizedDescription ?? "이 파일을 불러올 수 없습니다") }
                        group.leave()
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = item as? URL }
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        else { self?.notify(error?.localizedDescription ?? "이 파일을 불러올 수 없습니다") }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { completion(urls) }
        return true
    }

    func chooseAirDropFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "AirDrop으로 공유"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { shareFiles(panel.urls) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "트레이에 추가"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func shareFiles(_ urls: [URL]) {
        let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard valid.count == urls.count, !valid.isEmpty else { notify("원본 파일을 찾을 수 없습니다"); return }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: valid) else {
            notify("현재 AirDrop 공유를 사용할 수 없습니다"); return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: valid)
    }

    func captureScreenshot() {
        guard !capturing else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacCore-Captures", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { notify("캡처 폴더를 만들지 못했습니다: \(error.localizedDescription)"); return }
        let url = directory.appendingPathComponent("스크린샷-\(UUID().uuidString.prefix(8)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.standardError = FileHandle.nullDevice
        capturing = true
        dotVisible = false
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                self.dotVisible = true
                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    self.receiveScreenshot(url, temporary: true)
                } else if process.terminationStatus != 0 {
                    self.notify("캡처가 취소되었거나 화면 기록 권한이 없습니다")
                }
            }
        }
        do { try process.run() }
        catch { capturing = false; dotVisible = true; notify("캡처를 시작하지 못했습니다") }
    }

    func saveCapture(_ file: TrayFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.url.lastPathComponent
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: file.url)
            try data.write(to: destination, options: .atomic)
            notify("스크린샷을 저장했습니다")
        } catch { notify("저장하지 못했습니다: \(error.localizedDescription)") }
    }

    func copyFile(_ file: TrayFile) {
        guard file.exists else { notify("원본 파일을 찾을 수 없습니다"); return }
        let board = NSPasteboard.general
        if file.temporary, let image = NSImage(contentsOf: file.url) {
            board.clearContents()
            board.writeObjects([image])
        } else { board.clearContents(); board.writeObjects([file.url as NSURL]) }
        lastClipboardChange = board.changeCount
        showCopyNotice()
    }

    func removeFile(_ file: TrayFile) {
        // Removing a tray reference never removes the user's original file.
        tray.removeAll { $0.id == file.id }
    }

    func setClipboard(_ enabled: Bool) {
        lastClipboardChange = NSPasteboard.general.changeCount
        clipboardEnabled = enabled
        restartClipboardMonitoring()
    }

    func recordClipboard(from board: NSPasteboard = .general, source: String? = nil) {
        guard feedbackActive else { return }
        guard board.changeCount != lastClipboardChange else { return }
        lastClipboardChange = board.changeCount
        guard ClipboardPolicy.mayRecord(source: source,
            excludedApps: excludedApps, types: board.types?.map(\.rawValue) ?? []) else { return }
        if copyFeedbackEnabled { showCopyNotice() }
        guard clipboardEnabled else { return }
        guard clipboardStorageReady else { notify("저장된 복사 기록을 읽지 못해 기록을 중지했습니다"); return }
        let payload: ClipboardItem.Payload
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            payload = .files(urls)
        } else if let data = board.data(forType: .png) ?? board.data(forType: .tiff), data.count <= 5 * 1024 * 1024 {
            payload = .image(data)
        }
        else if let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 100_000 { payload = .text(text) }
        else { return }
        guard let incoming = ClipboardItem(payload: payload) else { return }
        let existing = clipboard.first { $0.contentKey == incoming.contentKey && $0.pinned }
            ?? clipboard.first { $0.contentKey == incoming.contentKey }
        var item = existing ?? incoming
        if existing == nil {
            do {
                let directory = clipboardDirectory ?? ClipboardItem.imageDirectory
                let data: Data
                switch item.payload {
                case .text(let text): data = Data(text.utf8)
                case .image(let image): data = image
                case .files(let urls): data = try JSONEncoder().encode(urls)
                default: return
                }
                if clipboardDirectory != nil || item.image != nil {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let url = directory.appendingPathComponent(UUID().uuidString)
                    try data.write(to: url, options: .atomic)
                    switch item.payload {
                    case .text: item.payload = .textFile(url, data.count)
                    case .image: item.payload = .imageFile(url, data.count)
                    case .files: item.payload = .filesFile(url, data.count)
                    default: break
                    }
                }
            } catch { notify("복사 기록을 저장하지 못했습니다"); return }
        }
        item.date = Date()
        var updated = clipboard.filter { $0.contentKey != incoming.contentKey }
        updated.insert(item, at: 0)
        updated.removeAll { !$0.pinned && $0.date < Date().addingTimeInterval(-7 * 86400) }
        while updated.count > 100 || updated.reduce(0, { $0 + $1.size }) > 32 * 1024 * 1024 {
            guard let index = updated.lastIndex(where: { !$0.pinned }) else { break }
            updated.remove(at: index)
        }
        clipboard = updated
        if existing == nil, let url = item.storedURL, !updated.contains(where: { $0.id == item.id }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func copyClipboard(_ item: ClipboardItem) {
        let board = NSPasteboard.general
        switch item.payload {
        case .text, .textFile:
            guard let text = item.text else { notify("복사 기록을 읽지 못했습니다"); return }
            board.clearContents(); board.setString(text, forType: .string)
        case .image, .imageFile:
            guard let image = item.image else { notify("복사 기록을 읽지 못했습니다"); return }
            board.clearContents(); board.writeObjects([image])
        case .files, .filesFile:
            guard let urls = item.files else { notify("복사 기록을 읽지 못했습니다"); return }
            board.clearContents(); board.writeObjects(urls.map { $0 as NSURL })
        }
        lastClipboardChange = board.changeCount
        showCopyNotice()
    }

    private func showCopyNotice() {
        guard copyFeedbackEnabled else { return }
        showIslandNotice(IslandNotice(title: "복사됨", detail: "클립보드", symbol: "doc.on.clipboard", kind: .clipboard,
                                      target: .clipboard))
    }

    func addFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "즐겨찾기에 추가"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls where !favorites.contains(where: { $0.url == url }) { favorites.append(Favorite(url: url)) }
            saveFavorites()
        }
    }
    func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: "favorites") }
    }
    func openFavorite(_ favorite: Favorite) {
        if !NSWorkspace.shared.open(favorite.url) { notify("이 항목을 열 수 없습니다") }
    }

    func stop() {
        try? fastInputSwitcher.disable()
        setFeedbackActive(false)
        disconnectMusic()
        persistTimer()
        setAwake(false)
        timer?.invalidate()
        timer = nil
    }
}
