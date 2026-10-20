import AppKit
import Carbon
import IOKit.hidsystem

enum QuickControlError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let message): message } }
}

enum SystemQuickControls {
    static var scrollReversed: Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let natural = CFPreferencesCopyValue("com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? true
        return !natural
    }

    static func setScrollReversed(_ reversed: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "-g", "com.apple.swipescrolldirection", "-bool", String(!reversed)]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, scrollReversed == reversed else {
            throw QuickControlError.failed("스크롤 방향을 바꾸지 못했습니다")
        }
    }

    static func alertVolume() throws -> Int {
        Int(try script("alert volume of (get volume settings)").int32Value)
    }

    static func setAlertVolume(_ volume: Int) throws {
        _ = try script("set volume alert volume \(min(100, max(0, volume)))")
    }

    private static func script(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw QuickControlError.failed("알림 음량 명령을 준비하지 못했습니다") }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { throw QuickControlError.failed("macOS 알림 음량을 바꾸지 못했습니다") }
        return result
    }
}

@MainActor
final class FastInputSwitcher {
    static let capsLock: UInt64 = 0x700000039
    static let f19: UInt64 = 0x70000006E
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"
    typealias Mapping = [String: UInt64]

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let preferences: UserDefaults
    // Persist ownership so a forced Xcode stop cannot lose the user's original Caps Lock mapping.
    private var originals: [String: [Mapping]]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var keyHeld = false
    var onError: (String) -> Void = { _ in }
    var isEnabled: Bool { hotKey != nil }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        originals = preferences.dictionary(forKey: "fastInputOriginalCapsMappings") as? [String: [Mapping]] ?? [:]
    }

    func enable() throws {
        guard !isEnabled else { return }
        guard Self.enabledSources.count >= 2 else {
            throw QuickControlError.failed("시스템 설정 → 키보드 → 입력 소스에 전환할 입력기를 두 개 이상 추가해 주세요")
        }
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4D434953 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let controller = Unmanaged<FastInputSwitcher>.fromOpaque(data).takeUnretainedValue()
                if GetEventKind(event) == kEventHotKeyReleased { controller.keyHeld = false }
                else if !controller.keyHeld {
                    controller.keyHeld = true
                    do { try controller.advanceInputSource() }
                    catch { controller.onError(error.localizedDescription) }
                }
            }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, events.count, &events,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else {
            throw QuickControlError.failed("빠른 한영키를 준비하지 못했습니다")
        }
        guard RegisterEventHotKey(UInt32(kVK_F19), 0, EventHotKeyID(signature: 0x4D434953, id: 19),
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }; handler = nil
            throw QuickControlError.failed("F19가 다른 단축키에서 사용 중입니다")
        }
        guard refreshKeyboards() else {
            try? disable()
            throw QuickControlError.failed("Caps Lock을 F19로 연결하지 못했습니다. 키보드 접근 권한을 확인해 주세요")
        }
    }

    @discardableResult func refreshKeyboards() -> Bool {
        guard isEnabled else { return false }
        var mapped = false
        for service in keyboards {
            let id = String((IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0)
            let current = mappings(service)
            if originals[id] != nil, current.contains(where: { $0[Self.sourceKey] == Self.capsLock && $0[Self.destinationKey] == Self.f19 }) {
                mapped = true
                continue
            }
            if originals[id] == nil {
                originals[id] = current.filter { $0[Self.sourceKey] == Self.capsLock }
                saveOriginals()
            }
            if IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, Self.enabling(in: current) as CFArray) {
                mapped = true
            }
        }
        return mapped
    }

    func disable() throws {
        let connected = keyboards
        guard originals.isEmpty || !connected.isEmpty else {
            throw QuickControlError.failed("키보드에 접근할 수 없어 기존 키 설정을 아직 복원하지 못했습니다")
        }
        var restored = true
        for service in connected {
            let id = String((IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0)
            guard let original = originals[id] else { continue }
            let current = mappings(service)
            // Leave a newer mapping from another app alone.
            if current.contains(where: { $0[Self.sourceKey] == Self.capsLock && $0[Self.destinationKey] == Self.f19 }) {
                if !IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString,
                    Self.restoring(original, in: current) as CFArray) { restored = false }
            }
        }
        guard restored else { throw QuickControlError.failed("기존 한영키 설정을 복원하지 못했습니다. 다시 꺼 주세요") }
        originals.removeAll(); saveOriginals()
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        keyHeld = false
    }

    private var keyboards: [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [])
            .filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 }
    }
    private func mappings(_ service: IOHIDServiceClient) -> [Mapping] {
        IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [Mapping] ?? []
    }
    private func saveOriginals() { preferences.set(originals, forKey: "fastInputOriginalCapsMappings") }

    static func enabling(in mappings: [Mapping]) -> [Mapping] {
        mappings.filter { $0[sourceKey] != capsLock } + [[sourceKey: capsLock, destinationKey: f19]]
    }
    static func restoring(_ originals: [Mapping], in mappings: [Mapping]) -> [Mapping] {
        mappings.filter { $0[sourceKey] != capsLock } + originals
    }
    static var enabledSources: [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                      kTISPropertyInputSourceIsEnabled: kCFBooleanTrue!,
                      kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue!] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.sorted {
            (stringProperty($0, kTISPropertyLocalizedName) ?? "") < (stringProperty($1, kTISPropertyLocalizedName) ?? "")
        }
    }
    static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
    static func nextSourceID(current: String, enabled: [String]) -> String? {
        guard enabled.count >= 2 else { return nil }
        let index = enabled.firstIndex(of: current).map { ($0 + 1) % enabled.count } ?? 0
        return enabled[index]
    }
    func advanceInputSource() throws {
        let sources = Self.enabledSources
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let currentID = Self.stringProperty(current, kTISPropertyInputSourceID),
              let nextID = Self.nextSourceID(current: currentID, enabled: sources.compactMap { Self.stringProperty($0, kTISPropertyInputSourceID) }),
              let next = sources.first(where: { Self.stringProperty($0, kTISPropertyInputSourceID) == nextID }),
              TISSelectInputSource(next) == noErr else {
            throw QuickControlError.failed("입력 소스 전환에 실패했습니다. 입력기 실행 상태를 확인해 주세요")
        }
    }
}
