import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let fileDropTypes = [UTType.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.compactMap { UTType($0) }

private struct MinuteSnapBehavior: ScrollTargetBehavior {
    let spacing: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard spacing > 0 else { return }
        let maxOffset = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = min(maxOffset, max(0, (target.rect.origin.x / spacing).rounded() * spacing))
    }
}

struct TimerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rulerMinute: Int? = 25
    @State private var rulerDragStartMinute: Int?
    @State private var rulerHovered = false
    @State private var wheelMonitor: Any?
    @State private var wheelRemainder: CGFloat = 0
    private let tickSpacing: CGFloat = 12
    private var inProgress: Bool { model.countdown.isRunning || model.remaining < model.countdown.duration }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(TimerMode.allCases) { mode in
                    Button { model.timerMode = mode } label: {
                        Text(mode.rawValue).font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .foregroundStyle(model.timerMode == mode ? .white : .secondary)
                            .background(model.timerMode == mode ? .white.opacity(0.12) : .clear, in: Capsule())
                    }
                }
            }
            VStack(spacing: 6) {
                Text(displayTime)
                    .font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: model.timerMode != .stopwatch))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: displayTime)
                Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }.frame(height: 76)

            if model.timerMode == .timer || model.timerMode == .pomodoro {
                ruler
                if model.timerMode == .pomodoro { pomodoroSettings }
            } else {
                Text("시작한 뒤에도 계속 측정합니다")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 76)
            }

            HStack(spacing: 12) {
                Button(action: resetAction) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44).background(.white.opacity(0.09), in: Circle()).contentShape(Rectangle())
                }.accessibilityLabel("초기화")
                Button(action: toggleAction) {
                    Label(primaryTitle, systemImage: primarySymbol)
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(.black).background(.orange, in: Capsule()).contentShape(Rectangle())
                }
            }
        }.buttonStyle(PanelButtonStyle()).padding(.vertical, 4)
            .onAppear {
                installWheelMonitor()
                rulerMinute = model.timerMode == .pomodoro ? model.pomodoroFocusMinutes : max(1, model.timerSeconds / 60)
            }
            .onDisappear(perform: removeWheelMonitor)
            .onChange(of: model.timerMode) { _, mode in
                rulerMinute = mode == .pomodoro ? model.pomodoroFocusMinutes : max(1, model.timerSeconds / 60)
            }
    }

    private var ruler: some View {
        GeometryReader { geometry in
            let phaseIsActive = model.timerMode == .pomodoro ? model.pomodoroActive : inProgress
            if phaseIsActive {
                let duration = max(60, model.countdown.duration)
                let durationMinutes = max(1, Int(ceil(duration / 60)))
                let inset: CGFloat = 16
                let travel = max(0, geometry.size.width - inset * 2)
                let spacing = travel / CGFloat(durationMinutes)
                let labelStride = max(5, Int(ceil(32 / max(spacing, 1) / 5)) * 5)
                ZStack(alignment: .topLeading) {
                    ForEach(0...durationMinutes, id: \.self) { minute in
                        let x = inset + spacing * CGFloat(minute)
                        VStack(spacing: 7) {
                            Capsule().fill(minute % 5 == 0 ? Color.orange : Color.orange.opacity(0.58))
                                .frame(width: min(3, max(1, spacing * 0.4)), height: minute % 5 == 0 ? 30 : 19)
                            Text(minute % labelStride == 0 || minute == durationMinutes ? "\(minute)" : " ")
                                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.orange.opacity(0.8))
                                .frame(width: 28).fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(width: max(28, spacing), height: 58)
                        .position(x: x, y: 29)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.countdown.isRunning)) { _ in
                        let remaining = phaseIsActive ? min(duration, model.countdown.remaining(at: ContinuousTime.now)) : duration
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .position(x: inset + travel * remaining / duration, y: 66)
                    }
                }
            } else {
                VStack(spacing: 2) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(1...180, id: \.self) { minute in
                            minuteTick(minute).id(minute)
                        }
                    }
                    .overlay(alignment: .leading) {
                        // Keep the zero mark visible without making it a selectable scroll target.
                        minuteTick(0).offset(x: -tickSpacing).allowsHitTesting(false)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, max(0, (geometry.size.width - tickSpacing) / 2))
                }
                .scrollPosition(id: $rulerMinute, anchor: .center)
                .scrollTargetBehavior(MinuteSnapBehavior(spacing: tickSpacing))
                .scrollIndicators(.hidden)
                .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let start = rulerDragStartMinute ?? rulerMinute ?? max(1, model.timerSeconds / 60)
                    rulerDragStartMinute = start
                    rulerMinute = min(180, max(1, start + Int((value.translation.width / tickSpacing).rounded())))
                }.onEnded { _ in
                    rulerDragStartMinute = nil
                })
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .contentShape(Rectangle())
                .onHover { rulerHovered = $0 }
                .onAppear { rulerMinute = model.timerMode == .pomodoro ? model.pomodoroFocusMinutes : max(1, model.timerSeconds / 60) }
                .onChange(of: rulerMinute) { _, minute in
                    guard let minute else { return }
                    guard minute > 0 else { rulerMinute = 1; return }
                    if model.timerMode == .pomodoro {
                        model.selectPomodoroFocusMinutes(minute)
                    } else {
                        guard !model.countdown.isRunning, minute * 60 != model.timerSeconds else { return }
                        model.selectTimerSeconds(minute * 60)
                    }
                }
                .frame(height: 58)
                Image(systemName: "triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                }
            }
        }.frame(height: 70)
    }

    private func minuteTick(_ minute: Int) -> some View {
        VStack(spacing: 7) {
            Capsule().fill(minute % 5 == 0 ? Color.orange : Color.orange.opacity(0.58))
                .frame(width: 3, height: minute % 5 == 0 ? 30 : 19)
            Text(minute % 5 == 0 ? "\(minute)" : " ")
                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.orange.opacity(0.8))
                .frame(width: 28).fixedSize(horizontal: true, vertical: false)
        }.frame(width: tickSpacing, height: 58)
    }

    private var pomodoroSettings: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(1...30, id: \.self) { minutes in
                    Button("\(minutes)분") { model.pomodoroBreakMinutes = minutes }
                }
            } label: {
                pomodoroSetting(title: "휴식 시간", value: "\(model.pomodoroBreakMinutes)분")
            }.accessibilityLabel("휴식 시간, \(model.pomodoroBreakMinutes)분")

            Menu {
                ForEach(1...12, id: \.self) { count in
                    Button("\(count)회") { model.pomodoroSessionCount = count }
                }
            } label: {
                pomodoroSetting(title: "총 세션 수", value: "\(model.pomodoroSessionCount)회")
            }.accessibilityLabel("총 세션 수, \(model.pomodoroSessionCount)회")
        }
    }

    private func pomodoroSetting(title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
            guard let model, rulerHovered,
                  (model.timerMode == .pomodoro ? !model.pomodoroActive : !model.countdown.isRunning),
                  !event.hasPreciseScrollingDeltas else { return event }
            let delta = event.scrollingDeltaY == 0 ? -event.scrollingDeltaX : event.scrollingDeltaY
            wheelRemainder += delta
            let steps = Int(wheelRemainder)
            guard steps != 0 else { return nil }
            wheelRemainder -= CGFloat(steps)
            let minute = min(180, max(1, (rulerMinute ?? model.timerSeconds / 60) + steps))
            rulerMinute = minute
            if model.timerMode == .pomodoro { model.selectPomodoroFocusMinutes(minute) }
            else { model.selectTimerSeconds(minute * 60) }
            return nil
        }
    }

    private func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
        wheelRemainder = 0
    }

    private var displayTime: String {
        switch model.timerMode {
        case .timer: inProgress ? Countdown.display(model.remaining) : Countdown.display(Double((rulerMinute ?? model.timerSeconds / 60) * 60))
        case .stopwatch: Countdown.display(model.stopwatchElapsed)
        case .pomodoro: model.pomodoroActive ? Countdown.display(model.remaining) :
            (model.pomodoroCycles >= model.pomodoroSessionCount ? "00:00" : Countdown.display(Double(model.pomodoroOnBreak ? model.pomodoroBreakMinutes * 60 : model.pomodoroFocusMinutes * 60)))
        }
    }
    private var statusText: String {
        if model.timerMode == .stopwatch { return model.stopwatchRunning ? "측정 중" : "스톱워치" }
        if model.timerMode == .pomodoro {
            if !model.pomodoroActive && model.pomodoroCycles >= model.pomodoroSessionCount { return "포모도로 완료" }
            if model.pomodoroActive {
                let session = min(model.pomodoroSessionCount, model.pomodoroCycles + (model.pomodoroOnBreak ? 0 : 1))
                return "\(model.pomodoroOnBreak ? "휴식" : "집중") · \(session)/\(model.pomodoroSessionCount)회"
            }
            return "공부 시간 설정 · 총 \(model.pomodoroSessionCount)회"
        }
        return model.countdown.isRunning ? "남은 시간" : (model.remaining == 0 ? "타이머 완료" : (inProgress ? "일시 정지됨" : "드래그해서 시간 설정"))
    }
    private var primaryTitle: String {
        if model.timerMode == .stopwatch { return model.stopwatchRunning ? "일시 정지" : "시작" }
        if model.timerMode == .pomodoro {
            if model.pomodoroActive && model.countdown.isRunning { return "일시 정지" }
            if model.pomodoroActive && model.remaining > 0 { return "계속" }
            return "시작"
        }
        return model.countdown.isRunning ? "일시 정지" : (inProgress && model.remaining > 0 ? "계속" : "시작")
    }
    private var primarySymbol: String { primaryTitle == "일시 정지" ? "pause.fill" : "play.fill" }
    private var toggleAction: () -> Void {
        switch model.timerMode {
        case .timer: return { if model.countdown.isRunning { model.pauseTimer() } else if inProgress && model.remaining > 0 { model.resumeTimer() } else { model.startTimer() } }
        case .stopwatch: return { model.stopwatchRunning ? model.pauseStopwatch() : model.startStopwatch() }
        case .pomodoro: return {
            if model.pomodoroActive && model.countdown.isRunning { model.pauseTimer() }
            else if model.pomodoroActive && model.remaining > 0 { model.resumeTimer() }
            else { model.startPomodoro() }
        }
        }
    }
    private var resetAction: () -> Void {
        switch model.timerMode {
        case .timer: return model.resetTimer
        case .stopwatch: return model.resetStopwatch
        case .pomodoro: return model.resetPomodoro
        }
    }
}

struct FilesView: View {
    @ObservedObject var model: AppModel
    @State private var trayTargeted = false
    @State private var airDropTargeted = false
    @State private var listHeight: CGFloat = 58
    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                dropZone("AirDrop", symbol: "airplay.audio", hint: "클릭 또는 끌어다 놓기", targeted: airDropTargeted, action: model.chooseAirDropFiles)
                    .onDrop(of: fileDropTypes, isTargeted: $airDropTargeted, perform: model.receiveAirDrop)
                dropZone("트레이", symbol: "tray.and.arrow.down", hint: "잠시 담아두기", targeted: trayTargeted, action: model.chooseFiles)
                    .onDrop(of: fileDropTypes, isTargeted: $trayTargeted, perform: model.receiveDrop)
            }
            if model.tray.isEmpty {
                Text("원본을 그대로 두고, 원하는 앱으로 옮기세요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.tray) { file in
                            HStack(spacing: 10) {
                                if file.temporary, let image = NSImage(contentsOf: file.url) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                                } else {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(file.exists ? (file.temporary ? "임시 캡처 · 저장 가능" : "원본 참조") : "원본을 찾을 수 없음")
                                        .font(.system(size: 9)).foregroundStyle(file.exists ? Color.secondary : .orange)
                                }
                                Spacer(minLength: 0)
                                Button { model.copyFile(file) } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 30).contentShape(Rectangle()) }
                                    .help("복사").accessibilityLabel("\(file.url.lastPathComponent) 복사")
                                Menu {
                                    Button("열기") { if !NSWorkspace.shared.open(file.url) { model.notify("파일을 열 수 없습니다") } }
                                    Button("AirDrop") { model.shareFiles([file.url]) }
                                    if file.temporary { Button("다른 이름으로 저장") { model.saveCapture(file) } }
                                    Button("트레이에서 제거") { model.removeFile(file) }
                                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 30).contentShape(Rectangle()) }
                                    .menuStyle(.borderlessButton).frame(width: 18)
                            }.padding(9).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                                .onDrag { NSItemProvider(object: file.url as NSURL) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { listHeight = $0 }
                }.frame(height: min(170, max(1, listHeight)))
            }
            HStack {
                Text("\(model.tray.count)개 보관 중").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.captureScreenshot) {
                    Label("영역 캡처", systemImage: "viewfinder").font(.system(size: 10))
                        .padding(.horizontal, 10).frame(height: 28).background(.primary.opacity(0.06), in: Capsule()).contentShape(Rectangle())
                }.disabled(model.capturing)
            }
        }.buttonStyle(PanelButtonStyle())
    }
    private func dropZone(_ title: String, symbol: String, hint: String, targeted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 23, weight: .light))
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(hint).font(.system(size: 8)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).frame(height: 112)
                .background(targeted ? Color.blue.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(targeted ? Color.blue : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
                .contentShape(Rectangle())
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var listHeight: CGFloat = 64
    var body: some View {
        VStack(spacing: 12) {
            Toggle("복사 기록", isOn: Binding(get: { model.clipboardEnabled }, set: model.setClipboard))
                .toggleStyle(.switch).controlSize(.small)
            if !model.clipboardEnabled {
                Label("켜진 동안 복사한 내용만 기록합니다.\n기록은 앱을 종료하면 지워집니다.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("복사한 내용 검색", text: $search).textFieldStyle(.roundedBorder)
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clipboard").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "아직 복사 기록이 없습니다" : "검색 결과가 없습니다").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            HStack(spacing: 9) {
                                Button { model.copyClipboard(item) } label: {
                                    HStack(spacing: 10) {
                                        if case .image(let data) = item.payload, let image = NSImage(data: data) {
                                            Image(nsImage: image).resizable().scaledToFit()
                                                .frame(width: 64, height: 48)
                                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18)
                                        }
                                        Text(item.title).font(.system(size: 12)).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(PanelButtonStyle()).help("다시 복사")
                                Button {
                                    if let i = model.clipboard.firstIndex(where: { $0.id == item.id }) { model.clipboard[i].pinned.toggle() }
                                } label: { Image(systemName: item.pinned ? "pin.fill" : "pin").frame(width: 28, height: 32).contentShape(Rectangle()) }
                                    .buttonStyle(PanelButtonStyle()).foregroundStyle(item.pinned ? .orange : .secondary).accessibilityLabel("기록 고정 전환")
                                Button(role: .destructive) { model.clipboard.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "trash").frame(width: 28, height: 32).contentShape(Rectangle())
                                }.buttonStyle(PanelButtonStyle()).foregroundStyle(.secondary)
                                    .help("기록 삭제").accessibilityLabel("\(item.title) 기록 삭제")
                            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .contextMenu { Button("기록 삭제", role: .destructive) { model.clipboard.removeAll { $0.id == item.id } } }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { listHeight = $0 }
                }.frame(height: min(230, max(1, listHeight)))
            }
            HStack {
                Text("\(model.clipboard.count)개 · 기기 내 메모리 보관").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("전체 삭제", role: .destructive) { model.clipboard.removeAll() }.controlSize(.small).disabled(model.clipboard.isEmpty)
            }
        }
    }
    private var items: [ClipboardItem] {
        model.clipboard.filter { search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.date > $1.date }
    }
}

struct MusicView: View {
    @ObservedObject var model: AppModel
    var geometry: Namespace.ID? = nil
    @Namespace private var localGeometry
    @State private var position = 0.0
    @State private var scrubbing = false
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 13) {
                ArtworkView(image: model.music.artwork, size: 58)
                    .matchedGeometryEffect(id: "music-artwork", in: geometry ?? localGeometry)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.music.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(model.music.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if model.music.hasTrack {
                        Text(model.music.sourceName).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .matchedGeometryEffect(id: "music-label", in: geometry ?? localGeometry)
                PlaybackIndicator(playing: model.music.playing)
                    .foregroundStyle(model.music.artworkTint.map { Color(nsColor: $0) } ?? Color.white.opacity(0.8))
            }
            if model.musicConnected && model.music.hasTrack {
                if model.music.duration > 0 { VStack(spacing: 3) {
                    Slider(value: $position, in: 0...max(1, model.music.duration), onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { model.seekMusic(position) }
                    }).controlSize(.mini).tint(.white).disabled(model.music.duration <= 0).accessibilityLabel("재생 위치")
                    HStack {
                        Text(Countdown.display(position)); Spacer(); Text(Countdown.display(model.music.duration))
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                } }
                HStack(spacing: 0) {
                    playbackButton("backward.fill", title: "이전 곡") { model.musicCommand("previous track") }
                    Spacer(minLength: 4)
                    playbackButton(model.music.playing ? "pause.fill" : "play.fill", title: model.music.playing ? "일시 정지" : "재생", size: 28) { model.musicCommand("playpause") }
                    Spacer(minLength: 4)
                    playbackButton("forward.fill", title: "다음 곡") { model.musicCommand("next track") }
                    Spacer(minLength: 4)
                    Menu {
                        Button("재생 앱 열기", action: model.openMusicSource).disabled(model.music.sourceBundleID.isEmpty)
                        Button("자동 감지 끄기", action: model.disconnectMusic)
                    } label: { Image(systemName: "ellipsis").frame(width: 28, height: 42).contentShape(Rectangle()) }
                        .menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel("음악 더 보기")
                }
            } else {
                Text(model.music.error ?? (model.musicConnected ? "음악이나 영상을 재생하면 자동으로 표시합니다.\nmacOS에 재생 정보를 제공하는 앱을 지원합니다." : "자동 감지를 켜면 현재 재생 중인 미디어를 표시합니다."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                Button(action: model.connectMusic) {
                    Text(model.musicBusy ? "감지 중…" : (model.musicConnected ? "다시 감지" : "자동 감지 켜기")).font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(.black).background(.white, in: Capsule()).contentShape(Rectangle())
                }.disabled(model.musicBusy)
            }
        }
        .buttonStyle(PanelButtonStyle()).padding(.vertical, 6)
        .onAppear { position = model.music.position }
        .onChange(of: model.music.position) { _, value in if !scrubbing { position = value } }
    }
    private func playbackButton(_ symbol: String, title: String, size: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 48, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(title)
    }
}

struct PanelContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            switch model.tab {
            case .overview: CompactSystemView(model: model)
            case .timer: TimerView(model: model)
            case .files: FilesView(model: model)
            case .clipboard: ClipboardView(model: model)
            case .music: MusicView(model: model)
            }
        }
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false
    @State private var airDropDropTargeted = false
    @State private var trayDropTargeted = false
    @Namespace private var musicGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var activity: Bool { model.compactTimer || model.compactMusic || model.islandNotice != nil }
    private var faceSize: CGSize {
        if model.expanded { return model.expandedSize }
        return activity ? model.compactSize : CGSize(width: 76, height: 24)
    }
    private func receiveIslandDrop(_ providers: [NSItemProvider]) -> Bool {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
        let frame = OverlayLayout.frame(in: screen.frame, visible: screen.visibleFrame, size: model.overlayWindowSize)
        guard frame.contains(location) else { return false }
        guard model.dropChoiceActive else { return model.receiveDrop(providers) }
        return location.x < frame.midX ? model.receiveAirDrop(providers) : model.receiveDrop(providers)
    }
    private var stackedNotice: Bool { model.islandNotice != nil && (model.compactTimer || model.compactMusic) }
    private var compactActivityContent: some View {
        HStack(spacing: 9) {
            if model.compactTimer {
                Image(systemName: "timer").foregroundStyle(.orange)
                Spacer(minLength: 0)
                Text(Countdown.display(model.remaining)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: Countdown.display(model.remaining))
            } else {
                ArtworkView(image: model.music.artwork, size: 20)
                    .matchedGeometryEffect(id: "music-artwork", in: musicGeometry)
                VStack(spacing: 1) {
                    Text(model.music.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    Text(model.music.artist).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }.frame(maxWidth: .infinity).matchedGeometryEffect(id: "music-label", in: musicGeometry)
                PlaybackIndicator(playing: model.music.playing).frame(width: 20)
                    .foregroundStyle(model.music.artworkTint.map { Color(nsColor: $0) } ?? .cyan)
            }
        }.padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }
    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if model.expanded {
                    if model.dropChoiceActive {
                        VStack(spacing: 9) {
                            HStack {
                                Text("파일 보내기").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                Spacer()
                                Button { model.dropChoiceActive = false; model.closeOverlay() } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                        .frame(width: 24, height: 24).contentShape(Rectangle())
                                }.foregroundStyle(.secondary).accessibilityLabel("닫기")
                            }
                            HStack(spacing: 8) {
                                Button { model.dropChoiceActive = false; model.closeOverlay(); model.chooseAirDropFiles() } label: {
                                    VStack(spacing: 5) {
                                        Image(systemName: "airplay.audio").font(.system(size: 20, weight: .light))
                                        Text("AirDrop").font(.system(size: 11, weight: .semibold))
                                        Text("여기에 놓아 공유").font(.system(size: 8)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity).frame(height: 74)
                                        .background(airDropDropTargeted ? Color.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(airDropDropTargeted ? Color.blue : Color.white.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
                                        .contentShape(Rectangle())
                                }.onDrop(of: fileDropTypes, isTargeted: $airDropDropTargeted, perform: model.receiveAirDrop)
                                Button { model.dropChoiceActive = false; model.closeOverlay(); model.chooseFiles() } label: {
                                    VStack(spacing: 5) {
                                        Image(systemName: "tray.and.arrow.down").font(.system(size: 20, weight: .light))
                                        Text("트레이").font(.system(size: 11, weight: .semibold))
                                        Text("여기에 놓아 보관").font(.system(size: 8)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity).frame(height: 74)
                                        .background(trayDropTargeted ? Color.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(trayDropTargeted ? Color.blue : Color.white.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [4, 4])).allowsHitTesting(false) }
                                        .contentShape(Rectangle())
                                }.onDrop(of: fileDropTypes, isTargeted: $trayDropTargeted, perform: model.receiveDrop)
                            }
                        }
                    .padding(.horizontal, 14).padding(.top, model.screenTopInset + 6).padding(.bottom, 14)
                        .transition(.opacity)
                    } else {
                    VStack(spacing: 14) {
                        HStack {
                            if let notice = model.islandNotice {
                                Button(action: model.openIslandNotice) {
                                    Label(notice.title, systemImage: notice.symbol).lineLimit(1)
                                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            } else {
                                Text(model.tab == .music ? "지금 재생 중" : model.tab.rawValue)
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.isPinned.toggle() } label: {
                                Image(systemName: model.isPinned ? "pin.fill" : "pin").font(.system(size: 11))
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.foregroundStyle(model.isPinned ? .orange : .secondary).accessibilityLabel("패널 고정 전환")
                            Button { model.settingsPage = SettingsPage(tool: model.tab); model.showSettings() } label: {
                                Image(systemName: "gearshape").font(.system(size: 10))
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.foregroundStyle(.secondary).accessibilityLabel("도구 설정 열기")
                        }
                        HStack(spacing: 4) {
                            ForEach(PanelTab.allCases) { tab in
                                Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { model.tab = tab } } label: {
                                    Image(systemName: tab.symbol).font(.system(size: 13, weight: .medium))
                                        .frame(maxWidth: .infinity).frame(height: 30)
                                        .background(model.tab == tab ? Color.white.opacity(0.1) : .clear, in: Capsule())
                                        .contentShape(Rectangle())
                                }.foregroundStyle(model.tab == tab ? .white : .secondary)
                                    .help(tab.rawValue).accessibilityLabel(tab.rawValue)
                            }
                        }
                        Group {
                            if model.tab == .overview { CompactSystemView(model: model) }
                            else if model.tab == .music { MusicView(model: model, geometry: musicGeometry) }
                            else { PanelContent(model: model) }
                        }.frame(maxWidth: .infinity, alignment: .top)
                        if let message = model.message {
                            Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                        }

                    }
                    .padding(.horizontal, 22).padding(.top, model.screenTopInset + 6).padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { measuredHeight in
                        let height = measuredHeight - model.screenTopInset
                        if height > 0, model.toolContentHeights[model.tab] != height { model.toolContentHeights[model.tab] = height }
                    }
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                } else if let notice = model.islandNotice, stackedNotice {
                    VStack(spacing: 0) {
                        Button(action: model.revealOverlay) {
                            compactActivityContent.frame(width: faceSize.width, height: 30)
                        }.accessibilityLabel(model.compactTimer ? "타이머 열기" : "음악 플레이어 열기")
                        Rectangle().fill(.white.opacity(0.1)).frame(width: faceSize.width - 40, height: 1)
                        Button(action: model.openIslandNotice) {
                            IslandNoticeView(notice: notice, stacked: true).frame(width: faceSize.width, height: 30).contentShape(Rectangle())
                        }.accessibilityLabel("\(notice.title), \(notice.detail)")
                            .id(notice.id).transition(.opacity)
                    }.frame(width: faceSize.width, height: faceSize.height)
                } else if let notice = model.islandNotice {
                    Button(action: model.openIslandNotice) {
                        IslandNoticeView(notice: notice).frame(width: faceSize.width, height: faceSize.height).contentShape(Rectangle())
                    }.accessibilityLabel("\(notice.title), \(notice.detail)")
                        .id(notice.id).transition(.opacity)
                } else if activity {
                    Button(action: model.revealOverlay) {
                        compactActivityContent.frame(width: faceSize.width, height: faceSize.height)
                    }.accessibilityLabel(model.compactTimer ? "타이머 열기" : "음악 플레이어 열기")
                } else {
                    Button(action: model.revealOverlay) {
                        Image(systemName: "circle.hexagongrid")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: faceSize.width, height: faceSize.height)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("MacCore 열기")
                }
            }
            .modifier(IslandMorph(width: faceSize.width, height: faceSize.height,
                                  radius: model.expanded ? 28 : (activity ? 11 : 12),
                                  topInset: model.expanded || activity ? 0 : (model.menuBarHeight - faceSize.height) / 2,
                                  attachment: model.expanded || activity ? 1 : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.48, dampingFraction: 0.84), value: model.expanded)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: activity)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: model.toolContentHeights)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.76), value: model.islandHovered)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.86), value: model.islandNotice?.id)
        .buttonStyle(PanelButtonStyle())
        .onDrop(of: fileDropTypes, isTargeted: $dropTargeted, perform: receiveIslandDrop)
        .onChange(of: dropTargeted) { _, value in
            if value { model.dropChoiceActive = true; model.revealTool(.files) }
        }
        .preferredColorScheme(.dark)
    }
}

private enum MenuQuickAction: String, CaseIterable, Identifiable {
    case sleep, reverseScroll, fastInput, muteAlerts, keyboardCleaning, monitorCleaning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleep: "잠자기 방지"
        case .reverseScroll: "스크롤 반전"
        case .fastInput: "빠른 한영키"
        case .muteAlerts: "알림음 끄기"
        case .keyboardCleaning: "키보드 청소"
        case .monitorCleaning: "모니터 청소"
        }
    }
    var symbol: String {
        switch self {
        case .sleep: "cup.and.saucer"
        case .reverseScroll: "arrow.up.and.down"
        case .fastInput: "character.bubble"
        case .muteAlerts: "bell.slash"
        case .keyboardCleaning: "keyboard"
        case .monitorCleaning: "display"
        }
    }
}

private struct MenuQuickActionsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("menuQuickActions") private var savedActions = ""
    @State private var editing = false
    @State private var appPaths = UserDefaults.standard.stringArray(forKey: "menuQuickApps") ?? []

    private var actions: [MenuQuickAction] {
        savedActions.split(separator: ",").compactMap { MenuQuickAction(rawValue: String($0)) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(editing ? "기능 선택" : "빠른 실행")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(editing ? "완료" : "편집") { editing.toggle() }
                    .font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.75))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(appPaths, id: \.self) { path in
                    Button {
                        if editing { removeApp(path) }
                        else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                .font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if editing { Image(systemName: "minus.circle.fill").font(.system(size: 10)).foregroundStyle(.red).offset(x: -4, y: 4) }
                        }
                    }.buttonStyle(.plain).help(URL(fileURLWithPath: path).lastPathComponent)
                }
                ForEach(editing ? MenuQuickAction.allCases : actions) { action in
                    Button {
                        if editing { toggle(action) } else { perform(action) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: action.symbol).font(.system(size: 15, weight: .medium))
                            Text(action.title).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(isActive(action) ? Color.orange : Color.white.opacity(0.82))
                        .background(.white.opacity(editing && actions.contains(action) ? 0.14 : 0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if editing {
                                Image(systemName: actions.contains(action) ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 10)).foregroundStyle(actions.contains(action) ? Color.green : Color.white.opacity(0.65))
                                    .offset(x: -4, y: 4)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editing ? "\(action.title) \(actions.contains(action) ? "제거" : "추가")" : action.title)
                    .accessibilityValue(isActive(action) ? "켜짐" : "꺼짐")
                    .help(action == .fastInput ? "Caps Lock(한/A)을 F19로 연결해 누르는 즉시 등록된 입력 소스를 순환" :
                          action == .muteAlerts ? "미디어 음량을 유지하고 macOS 알림·효과음만 끕니다" : action.title)
                }
                if editing {
                    Button(action: addApp) {
                        VStack(spacing: 5) {
                            Image(systemName: "plus.app").font(.system(size: 17, weight: .medium))
                            Text("앱 추가").font(.system(size: 9, weight: .medium))
                        }.frame(maxWidth: .infinity).frame(height: 48)
                            .foregroundStyle(.white.opacity(0.72))
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
            if !editing && appPaths.isEmpty && actions.isEmpty {
                Text("편집에서 기능을 고르거나 앱을 추가하세요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
    }

    private func toggle(_ action: MenuQuickAction) {
        var selected = actions
        if let index = selected.firstIndex(of: action) { selected.remove(at: index) }
        else { selected.append(action) }
        savedActions = selected.map(\.rawValue).joined(separator: ",")
    }

    private func perform(_ action: MenuQuickAction) {
        switch action {
        case .sleep: model.setAwake(model.awakeUntil == nil)
        case .reverseScroll: model.toggleScrollDirection()
        case .fastInput: model.toggleFastInput()
        case .muteAlerts: model.toggleAlertSounds()
        case .keyboardCleaning: model.startKeyboardCleaning()
        case .monitorCleaning: model.startMonitorCleaning()
        }
    }

    private func isActive(_ action: MenuQuickAction) -> Bool {
        switch action {
        case .sleep: model.awakeUntil != nil
        case .reverseScroll: model.scrollReversed
        case .fastInput: model.fastInputEnabled
        case .muteAlerts: model.alertSoundsMuted
        case .keyboardCleaning, .monitorCleaning: false
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "추가"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !appPaths.contains(url.path) { appPaths.append(url.path) }
        UserDefaults.standard.set(appPaths, forKey: "menuQuickApps")
    }

    private func removeApp(_ path: String) {
        appPaths.removeAll { $0 == path }
        UserDefaults.standard.set(appPaths, forKey: "menuQuickApps")
    }
}

private enum MenuPopoverSection: String, CaseIterable, Identifiable {
    case aiLimits = "AI 한도"
    case computer = "컴퓨터 이용 정보"
    var id: String { rawValue }
}

private struct AIUsageLimitsView: View {
    @State private var codex: CodexUsageReader.Usage?
    @State private var codexStatus = "불러오는 중"
    @State private var antigravity: [AntigravityUsageReader.Quota] = []
    @State private var antigravityStatus = "불러오는 중"

    private var claudeAvailable: Bool {
        ["/Users/\(NSUserName())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .contains(where: FileManager.default.isExecutableFile(atPath:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("남은 구독 한도").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(false).accessibilityLabel("사용량 새로고침")
            }
            providerCard("Codex", symbol: "circle.hexagongrid.fill", color: .green) {
                if let codex {
                    Text(codex.planName).font(.system(size: 10)).foregroundStyle(.secondary)
                    quotaRow("5시간", limit: codex.primary, color: Color(red: 0.40, green: 0.61, blue: 0.76))
                    if let weekly = codex.weekly { quotaRow("주간", limit: weekly, color: Color(red: 0.60, green: 0.52, blue: 0.70)) }
                } else { status(codexStatus) }
            }
            providerCard("Claude Code", symbol: "sparkle", color: .orange) {
                status(claudeAvailable ? "CLI 감지됨 · 구독 한도를 가져올 수 없음" : "이 Mac에서 Claude Code CLI 감지 안 됨")
            }
            providerCard("Antigravity", symbol: "sparkles", color: .cyan) {
                if antigravity.isEmpty { status(antigravityStatus) }
                else { ForEach(antigravity) { quotaRow($0.id, limit: CodexUsageReader.Limit(remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt, windowDurationMinutes: $0.windowDurationMinutes), color: Color(red: 0.40, green: 0.61, blue: 0.76)) } }
            }
            Text("표시는 구독 한도 기준이며 API 사용 금액과는 별도입니다.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func providerCard<Content: View>(_ title: String, symbol: String, color: Color,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
    }

    private func quotaRow(_ title: String, limit: CodexUsageReader.Limit, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("\(limit.remainingPercent)% 남음").foregroundStyle(.primary)
            }.font(.system(size: 10, weight: .medium))
            GeometryReader { proxy in
                ZStack {
                    Capsule().fill(.white.opacity(0.12))
                    HStack(spacing: 0) {
                        Capsule().fill(color).frame(width: proxy.size.width * CGFloat(limit.remainingPercent) / 100)
                        Spacer(minLength: 0)
                    }
                    if let reset = limit.resetsAt, let duration = limit.windowDurationMinutes, duration > 0 {
                        let remaining = min(1, max(0, reset.timeIntervalSinceNow / Double(duration * 60)))
                        Capsule().fill(.white).frame(width: 2, height: 8)
                            .position(x: min(proxy.size.width - 1, max(1, proxy.size.width * remaining)), y: 4)
                    }
                }
            }.frame(height: 8).clipShape(Capsule())
            HStack {
                Text("리셋")
                Spacer()
                Text(limit.resetsAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "시간 정보 없음")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    @MainActor private func refresh() async {
        codexStatus = "불러오는 중"
        antigravityStatus = "불러오는 중"
        do { codex = try await CodexUsageReader.read(); codexStatus = "" }
        catch { codexStatus = (error as? LocalizedError)?.errorDescription ?? "Codex 사용량을 가져오지 못함" }
        do { antigravity = try await AntigravityUsageReader.read(); antigravityStatus = "" }
        catch { antigravityStatus = (error as? LocalizedError)?.errorDescription ?? "Antigravity 사용량을 가져오지 못함" }
    }
}

struct MenuPopoverView: View {

    @ObservedObject var model: AppModel
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var section: MenuPopoverSection = .aiLimits

    var body: some View {
        VStack(spacing: 14) {
            Picker("정보 종류", selection: $section) {
                ForEach(MenuPopoverSection.allCases) { item in Text(item.rawValue).tag(item) }
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch section {
                case .aiLimits: AIUsageLimitsView()
                case .computer:
                    VStack(spacing: 12) {
                        CompactSystemView(model: model)
                        MenuQuickActionsView(model: model)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .top)
            Divider()
            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 32, height: 30).contentShape(Rectangle())
                }.accessibilityLabel("MacCore 종료")
            }.font(.system(size: 11, weight: .medium)).buttonStyle(PanelButtonStyle())
        }.padding(20).frame(maxWidth: .infinity, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(white: 0.105), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { onHeightChange($0) }
            .frame(maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }
}
