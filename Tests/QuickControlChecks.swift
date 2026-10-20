import AppKit
import IOKit.hidsystem
import Carbon

@main enum QuickControlChecks {
    @MainActor static func main() throws {
        typealias Keys = FastInputSwitcher
        let other: Keys.Mapping = [Keys.sourceKey: 0x7000000E3, Keys.destinationKey: 0x7000000E7]
        let oldCaps: Keys.Mapping = [Keys.sourceKey: Keys.capsLock, Keys.destinationKey: 0x700000029]
        let originals = [other, oldCaps]
        let enabled = Keys.enabling(in: originals)
        assert(enabled.contains(other), "Other remapped keys must stay intact")
        assert(enabled.filter { $0[Keys.sourceKey] == Keys.capsLock } == [[Keys.sourceKey: Keys.capsLock, Keys.destinationKey: Keys.f19]])
        assert(Keys.enabling(in: enabled) == enabled, "Refreshing connected keyboards must not duplicate mappings")
        assert(Keys.restoring([oldCaps], in: enabled) == originals, "Turning off must restore the user's Caps Lock mapping")
        assert(Keys.restoring([], in: Keys.enabling(in: [other])) == [other], "Unmapped Caps Lock must return to its default behavior")
        let external: Keys.Mapping = [Keys.sourceKey: 0x700000004, Keys.destinationKey: 0x700000005]
        assert(Keys.restoring([oldCaps], in: enabled + [external]).contains(external), "New unrelated mappings must survive turning off")
        let sources = ["ABC", "Seamtype", "두벌식"]
        assert(Keys.nextSourceID(current: "ABC", enabled: sources) == "Seamtype")
        assert(Keys.nextSourceID(current: "Seamtype", enabled: sources) == "두벌식")
        assert(Keys.nextSourceID(current: "두벌식", enabled: sources) == "ABC")
        assert(Keys.nextSourceID(current: "removed source", enabled: sources) == "ABC")
        assert(Keys.nextSourceID(current: "ABC", enabled: ["ABC"]) == nil)
        print("PASS: F19 mapping, idempotency, original key restoration and unrelated mappings")
        if CommandLine.arguments.contains("--integration") { try integration() }
    }

    @MainActor private static func integration() throws {
        _ = NSApplication.shared
        let reversed = SystemQuickControls.scrollReversed
        defer { try? SystemQuickControls.setScrollReversed(reversed) }
        try SystemQuickControls.setScrollReversed(!reversed)
        assert(SystemQuickControls.scrollReversed != reversed)
        try SystemQuickControls.setScrollReversed(reversed)
        assert(SystemQuickControls.scrollReversed == reversed)
        print("PASS: scroll direction changes, fresh state and original preference restored")
        let volume = try SystemQuickControls.alertVolume()
        let outputScript = NSAppleScript(source: "output volume of (get volume settings)")!
        var scriptError: NSDictionary?
        let mediaVolume = outputScript.executeAndReturnError(&scriptError).int32Value
        assert(scriptError == nil)
        defer { try? SystemQuickControls.setAlertVolume(volume) }
        try SystemQuickControls.setAlertVolume(0)
        let mutedVolume = try SystemQuickControls.alertVolume()
        assert(mutedVolume == 0)
        assert(outputScript.executeAndReturnError(&scriptError).int32Value == mediaVolume,
               "Muting alerts must leave media volume unchanged")
        try SystemQuickControls.setAlertVolume(volume)
        print("PASS: system alert mute and restore; media output volume unchanged")

        let suite = "MacCore.QuickControlChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = FastInputSwitcher(preferences: preferences)
        let sources = FastInputSwitcher.enabledSources
        let ids = sources.compactMap { FastInputSwitcher.stringProperty($0, kTISPropertyInputSourceID) }
        print("Input source cycle:", sources.compactMap { FastInputSwitcher.stringProperty($0, kTISPropertyLocalizedName) }.joined(separator: " → "))
        let current = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
        defer { TISSelectInputSource(current) }
        for source in sources {
            assert(TISSelectInputSource(source) == noErr)
            try controller.advanceInputSource()
            let selected = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
            assert(FastInputSwitcher.stringProperty(selected, kTISPropertyInputSourceID) ==
                   FastInputSwitcher.nextSourceID(current: FastInputSwitcher.stringProperty(source, kTISPropertyInputSourceID)!, enabled: ids),
                   "Every enabled input source must be reachable in the cycle")
        }
        print("PASS: all enabled input sources selected in order and original input restored")
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        func mappings() -> [String: [FastInputSwitcher.Mapping]] {
            var result: [String: [FastInputSwitcher.Mapping]] = [:]
            for service in IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [] {
                guard IOHIDServiceClientConformsTo(service, 1, 6) != 0 else { continue }
                let id = String((IOHIDServiceClientGetRegistryID(service) as! NSNumber).uint64Value)
                result[id] = IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [FastInputSwitcher.Mapping] ?? []
            }
            return result
        }
        let before = mappings()
        defer { try? controller.disable() }
        try controller.enable()
        assert(controller.isEnabled)
        let active = mappings()
        assert(before.contains { id, original in active[id] == FastInputSwitcher.enabling(in: original) })
        try controller.disable()
        assert(!controller.isEnabled && mappings() == before, "The real keyboard mapping must return to its exact original state")
        print("PASS: F19 registration and real keyboard remapping restored")
    }
}
