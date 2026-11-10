import AppKit

@main enum ClipboardPersistenceChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacCore-clipboard-check-\(UUID().uuidString)")
        let suite = "MacCore.ClipboardChecks.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "clipboardEnabled")
        defer { try? FileManager.default.removeItem(at: directory); prefs.removePersistentDomain(forName: suite) }
        let board = NSPasteboard(name: NSPasteboard.Name("MacCore-test-\(UUID().uuidString)"))
        var model: AppModel? = AppModel(startMonitoring: false, clipboardPreferences: prefs, clipboardDirectory: directory)
        func copyText(_ text: String) {
            board.clearContents(); board.setString(text, forType: .string)
            model!.recordClipboard(from: board, source: "test.editor")
        }
        copyText("첫 번째")
        model!.clipboard[0].pinned = true
        let textURL = model!.clipboard[0].storedURL!
        assert(model!.clipboard[0].text == "첫 번째" && FileManager.default.fileExists(atPath: textURL.path))
        copyText("두 번째")
        copyText("첫 번째")
        assert(model!.clipboard.count == 2 && model!.clipboard[0].pinned && model!.clipboard[0].storedURL == textURL)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        board.clearContents(); board.setData(image.tiffRepresentation!, forType: .tiff)
        model!.recordClipboard(from: board, source: "test.editor")
        let imageURL = model!.clipboard[0].storedURL!
        let original = URL(fileURLWithPath: "/tmp/example-clipboard-file")
        board.clearContents(); board.writeObjects([original as NSURL])
        model!.recordClipboard(from: board, source: "test.editor")
        let fileURL = model!.clipboard[0].storedURL!
        assert(model!.clipboard[0].files == [original])
        model = nil
        let restored = AppModel(startMonitoring: false, clipboardPreferences: prefs, clipboardDirectory: directory)
        assert(restored.clipboard.count == 4 && restored.clipboard.contains { $0.text == "첫 번째" && $0.pinned })
        assert(restored.clipboard.contains { $0.storedURL == imageURL && $0.image != nil })
        assert(restored.clipboard.contains { $0.storedURL == fileURL && $0.files == [original] })
        restored.clipboard.removeAll()
        assert(!FileManager.default.fileExists(atPath: textURL.path) && !FileManager.default.fileExists(atPath: imageURL.path) && !FileManager.default.fileExists(atPath: fileURL.path))
        let empty = AppModel(startMonitoring: false, clipboardPreferences: prefs, clipboardDirectory: directory)
        assert(empty.clipboard.isEmpty)
        let index = directory.appendingPathComponent("index.json")
        let damaged = Data("invalid".utf8)
        try damaged.write(to: index)
        let broken = AppModel(startMonitoring: false, clipboardPreferences: prefs, clipboardDirectory: directory)
        board.clearContents(); board.setString("새 기록", forType: .string)
        broken.recordClipboard(from: board, source: "test.editor")
        let retainedIndex = try Data(contentsOf: index)
        assert(broken.clipboard.isEmpty && retainedIndex == damaged,
               "Unreadable history must not be overwritten by a new copy")
        print("PASS: file-backed text, image and files; deduplication, pins, reload and deletion")
    }
}
