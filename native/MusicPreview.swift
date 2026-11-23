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

    static func accepts(_ link: String) -> Bool {
        guard let url = URL(string: link), url.scheme == "https", let host = url.host else { return false }
        return ["open.spotify.com", "music.apple.com", "tidal.com", "www.tidal.com", "listen.tidal.com",
                "qobuz.com", "www.qobuz.com", "play.qobuz.com", "open.qobuz.com",
                "deezer.com", "www.deezer.com", "link.deezer.com", "deezer.page.link"].contains(host)
            || ["com", "co.uk", "de", "co.jp", "fr", "it", "es", "in", "com.br", "com.mx", "com.au", "co"]
                .contains { host == "music.amazon." + $0 }
    }

    func run(link: String, folder: URL, source: String?, format: String, inspect: Bool = false, trackJSON: String? = nil,
             status: @escaping (String) -> Void,
             event: @escaping (String, Data) -> Void,
             finish: @escaping (Int32, String) -> Void) -> Process? {
        guard let script = Self.script else { return nil }
        let worker = Process()
        let pipe = Pipe()
        let input = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = ["-u", script.path, Bundle.main.bundlePath, link, folder.path, "--gui", "--format", format]
        if let source = source { arguments += ["--source", source] }
        if inspect { arguments.append("--inspect") }
        if let trackJSON = trackJSON { arguments += ["--track-json", trackJSON] }
        worker.arguments = arguments
        worker.standardOutput = pipe
        worker.standardError = pipe
        worker.standardInput = input
        do {
            try worker.run()
        } catch {
            return nil
        }
        if !inspect { task = worker }
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
                    } else if let split = line.firstIndex(of: " "),
                              line.hasPrefix("YTDL_METADATA ") || line.hasPrefix("YTDL_FILE ") {
                        let kind = String(line[..<split])
                        let payload = Data(line[line.index(after: split)...].utf8)
                        DispatchQueue.main.async { event(kind, payload) }
                    } else if !line.isEmpty {
                        lastLine = line
                        if line.hasPrefix("Searching ") {
                            DispatchQueue.main.async { status(line) }
                        }
                    }
                }
            }
            worker.waitUntilExit()
            let message = buffer.isEmpty ? lastLine : String(decoding: buffer, as: UTF8.self)
            DispatchQueue.main.async {
                if !inspect {
                    self?.pendingInput?.closeFile()
                    self?.pendingInput = nil
                    self?.expectedState = nil
                    self?.task = nil
                }
                finish(worker.terminationStatus, message)
            }
        }
        return worker
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

}
