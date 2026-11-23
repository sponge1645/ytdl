import AppKit

final class MusicPreview {
    private var task: Process?
    private var pendingInput: FileHandle?
    private var expectedState: String?

    static var script: URL? {
        Bundle.main.url(forResource: "music-track-smoke", withExtension: "py")
    }

    func stop() {
        pendingInput?.closeFile()
        pendingInput = nil
        expectedState = nil
        if let task = task, task.isRunning { task.terminate() }
    }

    func show(defaultFolder: URL, initialURL: String = "", status: @escaping (String) -> Void) {
        guard task == nil, let script = Self.script else { return }
        let dialog = NSAlert()
        dialog.messageText = "Download music"
        dialog.informativeText = "Paste a single-track link and select a lossless audio source."
        let link = NSTextField(frame: NSRect(x: 0, y: 42, width: 420, height: 25))
        link.placeholderString = "https://…"
        link.stringValue = initialURL
        let source = NSPopUpButton(frame: NSRect(x: 0, y: 4, width: 220, height: 27))
        source.addItems(withTitles: ["Automatic", "Amazon Music", "Tidal", "Qobuz", "Deezer"])
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 70))
        fields.addSubview(link)
        fields.addSubview(source)
        dialog.accessoryView = fields
        dialog.addButton(withTitle: "Choose Folder…")
        dialog.addButton(withTitle: "Cancel")
        dialog.window.initialFirstResponder = link
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let value = link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            notify("Enter a valid HTTPS track link.")
            return
        }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.directoryURL = defaultFolder
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        let output = folder.appendingPathComponent("YTDL Music " + String(UUID().uuidString.prefix(8)))
        let worker = Process()
        let pipe = Pipe()
        let input = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        worker.arguments = ["-u", script.path, Bundle.main.bundlePath, value, output.path, "--gui"]
        let keys = ["", "amazon", "tidal-web", "qobuz-web", "deezer"]
        if source.indexOfSelectedItem > 0 {
            worker.arguments?.append(contentsOf: ["--source", keys[source.indexOfSelectedItem]])
        }
        worker.standardOutput = pipe
        worker.standardError = pipe
        worker.standardInput = input
        do {
            try worker.run()
        } catch {
            notify("Could not launch the music engine. Python 3 from Command Line Tools is required.")
            return
        }
        task = worker
        status("Preparing music download…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            var lastLine = ""
            let reader = pipe.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    if line.hasPrefix("YTDL_BROWSER_VERIFICATION ") {
                        let payload = Data(line.dropFirst("YTDL_BROWSER_VERIFICATION ".count).utf8)
                        DispatchQueue.main.async {
                            guard worker.isRunning else { return }
                            self?.beginVerification(payload, input: input.fileHandleForWriting, status: status)
                        }
                    } else if !line.isEmpty {
                        lastLine = line
                        if line.hasPrefix("Searching ") {
                            DispatchQueue.main.async { status(line) }
                        }
                    }
                }
            }
            worker.waitUntilExit()
            let succeeded = worker.terminationStatus == 0
            let message = lastLine
            DispatchQueue.main.async {
                self?.pendingInput?.closeFile()
                self?.pendingInput = nil
                self?.expectedState = nil
                self?.task = nil
                status(succeeded ? "Music download complete" : "Music download failed")
                self?.notify(message.isEmpty ? "Music process exited with code \(worker.terminationStatus)." : message,
                             folder: succeeded ? output : nil)
            }
        }
    }

    private func beginVerification(_ payload: Data, input: FileHandle, status: (String) -> Void) {
        guard let fields = (try? JSONSerialization.jsonObject(with: payload)) as? [String: String],
              let link = fields["url"], let url = URL(string: link),
              url.scheme == "https", url.host == "api.zarz.moe", url.path == "/v2/challenge",
              let state = fields["state"], !state.isEmpty else {
            input.closeFile()
            return
        }
        pendingInput = input
        expectedState = state
        status("Complete music verification in your browser…")
        if !NSWorkspace.shared.open(url) {
            stop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard let self = self, self.expectedState == state else { return }
            self.pendingInput?.closeFile()
            self.pendingInput = nil
            self.expectedState = nil
        }
    }

    func acceptVerification(_ url: URL) {
        guard let input = pendingInput, let expected = expectedState,
              task?.isRunning == true,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "mornye", parts.host == "session-grant",
              parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems,
              items.filter({ $0.name == "state" }).map({ $0.value }) == [expected],
              items.filter({ $0.name == "grant" }).count == 1,
              let grant = items.first(where: { $0.name == "grant" })?.value, !grant.isEmpty else { return }
        pendingInput = nil
        expectedState = nil
        try? input.write(contentsOf: Data((url.absoluteString + "\n").utf8))
        input.closeFile()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func notify(_ message: String, folder: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = folder == nil ? "Music download" : "Music download complete"
        alert.informativeText = message
        alert.addButton(withTitle: folder == nil ? "OK" : "Show in Finder")
        if folder != nil { alert.addButton(withTitle: "Close") }
        if alert.runModal() == .alertFirstButtonReturn, let folder = folder {
            NSWorkspace.shared.open(folder)
        }
    }
}
