import SwiftUI
import AppKit
import ServiceManagement
import Sparkle

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.settingsPage) {
                Section("MacCore") {
                    page(.general)
                    page(.island)
                }
                Section("도구별 설정") {
                    ForEach([SettingsPage.overview, .timer, .files, .clipboard, .music, .notifications, .favorites]) { page($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            Form {
                switch model.settingsPage {
                case .general:
                    Section("시작") {
                        Toggle("로그인할 때 MacCore 실행", isOn: Binding(get: { loginEnabled }, set: setLoginEnabled))
                        if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    }
                    Section("MacCore 정보") {
                        LabeledContent("지원", value: "M칩 Mac · macOS 14 이상")
                        LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "알 수 없음")
                        Button("업데이트 확인") { updater.checkForUpdates() }
                    }
                case .island:
                    Section("표시") {
                        Toggle("상단 중앙의 검정 점 표시", isOn: $model.dotEnabled)
                        Picker("표시할 화면", selection: $model.preferredDisplay) {
                            Text("주 디스플레이").tag("")
                            ForEach(NSScreen.screens, id: \.displayID) { screen in Text(screen.localizedName).tag(screen.displayID) }
                        }
                    }
                    Section("열기와 닫기") {
                        LabeledContent("빠르게 열기", value: "Control + Option + Space")
                        Text("검정 점은 마우스를 올리면 열립니다. 음악 바는 마우스를 올리면 살짝 커지고 클릭하면 상세 제어가 열립니다. 핀 버튼으로 패널을 고정할 수 있습니다.")
                            .foregroundStyle(.secondary)
                    }
                case .overview:
                    Section("잠자기 방지") {
                        Toggle("시스템 자동 잠자기 방지", isOn: Binding(get: { model.awakeUntil != nil }, set: model.setAwake))
                        if let until = model.awakeUntil {
                            LabeledContent("종료 시각", value: until.formatted(date: .omitted, time: .shortened))
                        }
                        Text("한 번 켜면 1시간 동안 유지됩니다. 화면 꺼짐과 덮개 닫힘은 기존 설정을 따릅니다.")
                            .foregroundStyle(.secondary)
                    }
                case .timer:
                    Section("완료 알림") {
                        Toggle("타이머 완료 소리", isOn: $model.soundEnabled)
                    }
                    Section("타이머 유지") {
                        Text("실행 중인 타이머는 MacCore를 다시 열어도 이어집니다. 시간 선택과 시작·일시 정지는 노치 패널에서 할 수 있습니다.")
                            .foregroundStyle(.secondary)
                    }
                case .files:
                    Section("파일 트레이") {
                        LabeledContent("보관 기간", value: "MacCore 실행 중")
                        LabeledContent("원본 파일", value: "기존 위치에 유지")
                    }
                    Section("스크린샷") {
                        Toggle("새 스크린샷 자동 감지", isOn: $model.screenshotDetectionEnabled)
                        Text("시스템이 파일로 저장한 새 스크린샷을 감지해 트레이에 추가합니다. Spotlight 검색이 꺼진 위치는 감지되지 않을 수 있습니다.")
                            .foregroundStyle(.secondary)
                        Text("MacCore에서 직접 찍은 영역 캡처는 임시로 보관됩니다. 필요한 이미지는 패널의 저장 버튼으로 보관하세요.")
                            .foregroundStyle(.secondary)
                    }
                case .clipboard:
                    Section("복사 알림") {
                        Toggle("복사할 때 노치에 알림 표시", isOn: $model.copyFeedbackEnabled)
                        Text("복사 기록을 꺼도 ‘복사됨’ 알림은 표시할 수 있습니다. 이때 복사한 내용은 읽거나 보관하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    Section("기록") {
                        Toggle("복사 기록 사용", isOn: Binding(get: { model.clipboardEnabled }, set: model.setClipboard))
                        Text("복사 기록은 이 Mac에 저장되어 앱을 다시 열어도 유지됩니다. 화면 잠금 중에는 기록을 멈춥니다.")
                            .foregroundStyle(.secondary)
                        Button("복사 기록 전체 삭제", role: .destructive) { model.clipboard.removeAll() }
                            .disabled(model.clipboard.isEmpty)
                    }
                    Section("기록 제외 앱") {
                        Text("앱의 번들 ID를 한 줄에 하나씩 입력하세요.").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.excludedApps).font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120)
                        Text("민감 정보 표시는 가능한 범위에서 제외합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                case .music:
                    Section("지금 재생 중") {
                        Toggle("재생 중인 음악·영상 자동 감지", isOn: Binding(get: { model.musicConnected }, set: { enabled in
                            if enabled { model.connectMusic() } else { model.disconnectMusic() }
                        }))
                        Text("macOS에 재생 정보를 제공하는 앱을 자동으로 따라갑니다. 여러 앱이 재생 중이면 시스템이 선택한 한 대상을 표시합니다.")
                            .foregroundStyle(.secondary)
                        if let error = model.music.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                case .notifications:
                    Section("다른 앱 알림") {
                        Toggle("알림 배너를 노치에도 표시", isOn: Binding(get: { model.notificationsEnabled }, set: model.setNotifications))
                        Text("손쉬운 사용 권한을 허용한 뒤 켜세요. 새로 표시되는 알림 배너만 읽으며 잠금 중에는 감지를 멈춥니다. 알림 내용은 저장하지 않습니다.")
                            .foregroundStyle(.secondary)
                        Button("손쉬운 사용 권한 설정 열기", action: NotificationMonitor.openPermissionSettings)
                        if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    Section("AI 작업 완료") {
                        Toggle("Codex · Claude Code · Antigravity 완료 알림", isOn: $model.aiCompletionNotificationsEnabled)
                        Text("각 도구가 macOS에 표시한 알림 배너를 감지합니다. 앱 자체 작업 상태를 직접 읽지는 않으므로 각 도구의 배너 알림과 손쉬운 사용 권한이 필요합니다. 알림 내용은 저장하지 않습니다.")
                            .foregroundStyle(.secondary)
                    }
                    Section("미리보기") {
                        Button("알림 모양 미리보기") {
                            model.closeOverlay()
                            model.showIslandNotice(IslandNotice(title: "알림 미리보기", detail: "메시지가 도착했습니다", symbol: "bell.fill", kind: .notification))
                        }
                        Text("시스템 알림을 이동하거나 지우지는 않습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                case .favorites:
                    Section("등록한 앱과 파일") {
                        ForEach(model.favorites) { favorite in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: favorite.url.path)).resizable().frame(width: 24, height: 24)
                                Button(favorite.name) { model.openFavorite(favorite) }.buttonStyle(.link)
                                Spacer()
                                Button("제거", role: .destructive) {
                                    model.favorites.removeAll { $0.id == favorite.id }
                                    model.saveFavorites()
                                }.accessibilityLabel("\(favorite.name) 즐겨찾기에서 제거")
                            }
                        }
                        Button("앱 또는 파일 추가…", action: model.addFavorite)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.settingsPage.rawValue)
        }
        .frame(minWidth: 780, minHeight: 580)
    }

    private func page(_ page: SettingsPage) -> some View {
        Label(page.rawValue, systemImage: page.symbol).tag(page)
    }

    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? "시스템 설정의 로그인 항목에서 승인이 필요합니다." : nil
        } catch { loginError = error.localizedDescription }
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
}
