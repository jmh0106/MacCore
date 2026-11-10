import Foundation
import Combine

@MainActor
final class AIUsageStore: ObservableObject {
    @Published var codex: CodexUsageReader.Usage?
    @Published var codexStatus = "불러오는 중"
    @Published var antigravity: [AntigravityUsageReader.Quota] = []
    @Published var antigravityStatus = "불러오는 중"
    @Published private(set) var isRefreshing = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do { codex = try await CodexUsageReader.read(); codexStatus = "" }
            catch { codexStatus = (error as? LocalizedError)?.errorDescription ?? "Codex 사용량을 가져오지 못함" }
            do { antigravity = try await AntigravityUsageReader.read(); antigravityStatus = "" }
            catch { antigravityStatus = (error as? LocalizedError)?.errorDescription ?? "Antigravity 사용량을 가져오지 못함" }
        }
    }
}

enum CodexUsageReader {
    struct Limit {
        let remainingPercent: Int
        let resetsAt: Date?
        let windowDurationMinutes: Int?
    }

    struct Usage {
        let planName: String
        let primary: Limit
        let weekly: Limit?
    }

    enum ReadError: LocalizedError {
        case cliMissing
        case unavailable
        case invalidResponse
        case invalidAntigravityResponse
        case antigravityCLIMissing
        case antigravityUnavailable
        case server(String)

        var errorDescription: String? {
            switch self {
            case .cliMissing: "Codex CLI를 찾을 수 없음"
            case .unavailable: "Codex 계정 사용량을 가져오지 못함"
            case .invalidResponse: "Codex 사용량 응답을 읽지 못함"
            case .invalidAntigravityResponse: "Antigravity 사용량 응답을 읽지 못함"
            case .antigravityCLIMissing: "Antigravity CLI를 찾을 수 없음"
            case .antigravityUnavailable: "Antigravity 사용량을 가져오지 못함"
            case .server(let message): message
            }
        }
    }

    static func read() async throws -> Usage {
        try await Task.detached(priority: .utility) { try readSynchronously() }.value
    }

    private static func readSynchronously() throws -> Usage {
        guard let executable = ["/Users/\(NSUserName())/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { throw ReadError.cliMissing }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try send(["method": "initialize", "id": 1, "params": [
            "clientInfo": ["name": "MacCore", "title": "MacCore", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"],
            "capabilities": ["experimentalApi": true]
        ]], to: input)
        _ = try response(id: 1, from: output)
        try send(["method": "initialized", "params": [:]], to: input)
        try send(["method": "account/rateLimits/read", "id": 2], to: input)
        let result = try response(id: 2, from: output)
        guard let usage = extract(result) else { throw ReadError.unavailable }
        return usage
    }

    private static func send(_ message: [String: Any], to pipe: Pipe) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    private static func response(id: Int, from pipe: Pipe) throws -> [String: Any] {
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw ReadError.unavailable }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (message["id"] as? Int) == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw ReadError.server(error["message"] as? String ?? "Codex 사용량 요청 실패")
                }
                guard let result = message["result"] as? [String: Any] else { throw ReadError.invalidResponse }
                return result
            }
        }
    }

    private static func extract(_ result: [String: Any]) -> Usage? {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let codexBucket = buckets?["codex"] as? [String: Any]
        let fallback = result["rateLimits"] as? [String: Any]
        let limits = codexBucket ?? ((fallback?["limitId"] as? String == "codex") ? fallback : nil)
        guard let limits,
              let primary = limits["primary"] as? [String: Any],
              let primaryUsed = (primary["usedPercent"] as? NSNumber)?.intValue else { return nil }

        func limit(_ window: [String: Any], used: Int) -> Limit {
            let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let duration = (window["windowDurationMins"] as? NSNumber)?.intValue
            return Limit(remainingPercent: min(100, max(0, 100 - used)), resetsAt: reset, windowDurationMinutes: duration)
        }

        let plan = limits["planType"] as? String ?? "Codex"
        let displayPlan: String
        switch plan.lowercased() {
        case "plus": displayPlan = "Plus 구독"
        case "pro": displayPlan = "Pro 구독"
        case "team": displayPlan = "Team 구독"
        case "business": displayPlan = "Business 구독"
        default: displayPlan = "\(plan.capitalized) 구독"
        }
        let weekly = (limits["secondary"] as? [String: Any]).flatMap { window -> Limit? in
            guard let used = (window["usedPercent"] as? NSNumber)?.intValue else { return nil }
            return limit(window, used: used)
        }
        return Usage(planName: displayPlan, primary: limit(primary, used: primaryUsed), weekly: weekly)
    }
}

enum AntigravityUsageReader {
    struct Quota: Identifiable {
        let id: String
        let remainingPercent: Int
        let resetsAt: Date?
        let windowDurationMinutes: Int?
    }

    static func read() async throws -> [Quota] {
        try await Task.detached(priority: .utility) {
            let executable = "/Users/\(NSUserName())/.local/bin/agy"
            guard FileManager.default.isExecutableFile(atPath: executable) else { throw CodexUsageReader.ReadError.antigravityCLIMissing }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-p", "/usage"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { throw CodexUsageReader.ReadError.antigravityUnavailable }
            let quotas = text.split(whereSeparator: \.isNewline).compactMap { line -> Quota? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 3,
                      let remaining = Int(fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
                let period = String(fields[1]).lowercased()
                let duration = period.contains("weekly") ? 7 * 24 * 60 : (period.contains("daily") ? 24 * 60 : nil)
                let resetText = fields.count > 3 ? String(fields[3]) : ""
                return Quota(id: String(fields[0]), remainingPercent: min(100, max(0, remaining)),
                    resetsAt: ISO8601DateFormatter().date(from: resetText), windowDurationMinutes: duration)
            }
            guard !quotas.isEmpty else { throw CodexUsageReader.ReadError.invalidAntigravityResponse }
            return quotas
        }.value
    }
}
