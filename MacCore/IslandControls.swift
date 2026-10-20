import SwiftUI

struct IslandSurface: Shape {
    var radius: CGFloat
    var attachment: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, attachment) }
        set { radius = newValue.first; attachment = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let attached = min(1, max(0, attachment))
        let wing = 6 * attached
        let top = min(radius, rect.height / 2) * (1 - attached)
        let corner = max(top, wing)
        let bottom = min(radius, (rect.width - wing * 2) / 2, rect.height / 2)
        let width = rect.width, height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: top, y: 0))
        path.addLine(to: CGPoint(x: width - top, y: 0))
        path.addCurve(to: CGPoint(x: width - wing, y: corner),
                      control1: CGPoint(x: width - top * 0.45 - wing * 0.55, y: 0),
                      control2: CGPoint(x: width - wing, y: corner * 0.45))
        path.addLine(to: CGPoint(x: width - wing, y: height - bottom))
        path.addQuadCurve(to: CGPoint(x: width - wing - bottom, y: height), control: CGPoint(x: width - wing, y: height))
        path.addLine(to: CGPoint(x: wing + bottom, y: height))
        path.addQuadCurve(to: CGPoint(x: wing, y: height - bottom), control: CGPoint(x: wing, y: height))
        path.addLine(to: CGPoint(x: wing, y: corner))
        path.addCurve(to: CGPoint(x: top, y: 0), control1: CGPoint(x: wing, y: corner * 0.45),
                      control2: CGPoint(x: top * 0.45 + wing * 0.55, y: 0))
        path.closeSubpath()
        return path
    }
}

struct IslandMorph: AnimatableModifier {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var topInset: CGFloat
    var attachment: CGFloat

    typealias Dimensions = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    var animatableData: AnimatablePair<Dimensions, CGFloat> {
        get { AnimatablePair(Dimensions(AnimatablePair(width, height), AnimatablePair(radius, topInset)), attachment) }
        set {
            width = newValue.first.first.first
            height = newValue.first.first.second
            radius = newValue.first.second.first
            topInset = newValue.first.second.second
            attachment = newValue.second
        }
    }

    func body(content: Content) -> some View {
        GeometryReader { canvas in
            let frame = OverlayLayout.surfaceFrame(canvasWidth: canvas.size.width, size: CGSize(width: width, height: height), topInset: topInset)
            let shape = IslandSurface(radius: radius, attachment: attachment)
            content
                .frame(width: width, height: height, alignment: .top)
                .background(.black, in: shape)
                .clipShape(shape)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

struct IslandNoticeView: View {
    let notice: IslandNotice
    var stacked = false
    var body: some View {
        let tint: Color = notice.kind == .power ? .orange : .white
        HStack(spacing: 9) {
            Group {
                if let image = notice.image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: notice.symbol).font(.system(size: 12, weight: .semibold)).padding(3).foregroundStyle(tint) }
            }.frame(width: 20, height: 20).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(notice.title).font(.system(size: stacked ? 10 : 11, weight: .semibold)).lineLimit(1).layoutPriority(1).foregroundStyle(tint)
            Spacer(minLength: 12)
            Text(notice.detail).font(.system(size: stacked ? 9 : 10, weight: .medium))
                .foregroundStyle(notice.kind == .power ? Color.orange.opacity(0.75) : Color.white.opacity(0.55))
                .lineLimit(1).frame(maxWidth: stacked ? 96 : (notice.kind == .notification ? 260 : 110), alignment: .trailing)
        }.padding(.horizontal, 20).foregroundStyle(.white)
    }
}

struct PanelButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { Color(white: 0.14); Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.65)) } }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

struct PlaybackIndicator: View {
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3, paused: !playing || reduceMotion)) { context in
            HStack(spacing: 2) {
                ForEach(0..<5) { index in
                    Capsule().frame(width: 2, height: height(index, time: context.date.timeIntervalSinceReferenceDate))
                }
            }.frame(width: 18, height: 18).animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: context.date)
        }.accessibilityHidden(true)
    }
    private func height(_ index: Int, time: Double) -> CGFloat {
        guard playing && !reduceMotion else { return [4, 8, 15, 8, 4][index] }
        // A playback indicator, not a measurement of the audio signal.
        return 3 + CGFloat((sin(time * 5 + Double(index) * 1.7) + 1) * 5)
    }
}

struct CompactSystemView: View {
    @ObservedObject var model: AppModel
    private var snapshot: SystemSnapshot { model.snapshot }
    private var memoryUse: Double? {
        guard let used = snapshot.usedMemory, snapshot.totalMemory > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(snapshot.totalMemory)))
    }
    private var diskUse: Double? {
        guard let free = snapshot.diskFree, let total = snapshot.diskTotal, total > 0 else { return nil }
        return min(1, max(0, Double(total - free) / Double(total)))
    }
    private var powerDetail: String {
        guard snapshot.charging else { return snapshot.onAC ? "전원 어댑터" : "배터리 사용 중" }
        guard let minutes = snapshot.timeToFullChargeMinutes else { return "충전 시간 계산 중" }
        if minutes == 0 { return "충전 완료 임박" }
        return minutes < 60 ? "약 \(minutes)분 후 완료" : "약 \(minutes / 60)시간 \(minutes % 60)분 후 완료"
    }
    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricCard("CPU", symbol: "cpu", value: snapshot.cpu.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                           detail: "프로세서 사용률",
                           progress: snapshot.cpu, color: .blue)
                metricCard("메모리", symbol: "memorychip",
                           value: snapshot.usedMemory.map { "\(byteString($0)) / \(byteString(snapshot.totalMemory))" } ?? "—",
                           detail: snapshot.usedMemory.map { "\(Int(Double($0) / Double(snapshot.totalMemory) * 100))% 사용 중" } ?? "",
                           progress: memoryUse, color: .cyan)
                metricCard("디스크", symbol: "internaldrive",
                           value: snapshot.diskFree.map { "\(byteString($0)) 남음" } ?? "—",
                           detail: snapshot.diskTotal.map { "전체 \(byteString($0))" } ?? "",
                           progress: diskUse, color: .purple)
                metricCard("네트워크", symbol: "network", value: "↓  \(speedString(snapshot.download))",
                           detail: "↑  \(speedString(snapshot.upload))", progress: nil, color: .cyan)
            }
            HStack(spacing: 8) {
                Label("전원", systemImage: "battery.75percent").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(snapshot.battery.map { "\($0)%" } ?? "전원 연결").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                Text(powerDetail)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
    private func metricCard(_ title: String, symbol: String, value: String, detail: String,
                            progress: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let progress { ProgressView(value: progress).tint(color).scaleEffect(x: 1, y: 0.7, anchor: .center) }
            else { Capsule().fill(.clear).frame(height: 4) }
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 96, alignment: .leading).padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
