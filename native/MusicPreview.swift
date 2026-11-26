import AppKit

final class MusicPreview {
    private var pendingInputs: [String: FileHandle] = [:]

    static var script: URL? {
        Bundle.main.url(forResource: "music-track-smoke", withExtension: "py")
    }

    func stop() {
        for input in pendingInputs.values { input.closeFile() }
        pendingInputs.removeAll()
    }

    static func normalizedLink(_ link: String) -> String {
        let parts = link.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].lowercased() == "spotify",
              ["track", "album", "playlist", "artist"].contains(String(parts[1])),
              String(parts[2]).range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil else { return link }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }

    static func accepts(_ link: String) -> Bool {
        guard let url = URL(string: link), url.scheme == "https", let host = url.host else { return false }
        return ["music.youtube.com", "beatport.com", "www.beatport.com", "jiosaavn.com", "www.jiosaavn.com",
                "open.spotify.com", "music.apple.com", "tidal.com", "www.tidal.com", "listen.tidal.com",
                "qobuz.com", "www.qobuz.com", "play.qobuz.com", "open.qobuz.com",
                "deezer.com", "www.deezer.com", "link.deezer.com", "deezer.page.link"].contains(host)
            || ["com", "co.uk", "de", "co.jp", "fr", "it", "es", "in", "com.br", "com.mx", "com.au", "co"]
                .contains { host == "music.amazon." + $0 }
    }

    func run(link: String, folder: URL, source: String?, format: String, inspect: Bool = false, trackJSON: String? = nil, maintenance: String? = nil,
             status: @escaping (String) -> Void,
             log: @escaping (String) -> Void = { _ in },
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
        if let maintenance = maintenance { arguments += ["--maintenance", maintenance] }
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
                              line.hasPrefix("YTDL_METADATA ") || line.hasPrefix("YTDL_FILE ") || line.hasPrefix("YTDL_PROGRESS ") || line.hasPrefix("YTDL_VERIFICATION_RESULT ") {
                        let kind = String(line[..<split])
                        let payload = Data(line[line.index(after: split)...].utf8)
                        DispatchQueue.main.async { event(kind, payload) }
                    } else if !line.isEmpty {
                        lastLine = line
                        DispatchQueue.main.async { log(line) }
                        if line.hasPrefix("Searching ") {
                            DispatchQueue.main.async { status(line) }
                        }
                    }
                }
            }
            worker.waitUntilExit()
            let message = buffer.isEmpty ? lastLine : String(decoding: buffer, as: UTF8.self)
            DispatchQueue.main.async {
                self?.closeVerification(input.fileHandleForWriting)
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
        pendingInputs[state] = input
        let opened = NSWorkspace.shared.open(url)
        status(opened ? "Complete verification in your browser. Paste the return link here with ⌘V if needed."
                      : "Could not open verification. Retry the track to request a new link.")
        if !opened { closeVerification(input); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            self?.closeVerification(input)
        }
    }

    private func closeVerification(_ input: FileHandle) {
        guard let state = pendingInputs.first(where: { $0.value === input })?.key else { return }
        pendingInputs.removeValue(forKey: state)?.closeFile()
    }

    @discardableResult
    func acceptVerification(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "mornye", parts.host == "session-grant",
              parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              let state = items.first(where: { $0.name == "state" })?.value,
              let input = pendingInputs[state],
              items.filter({ $0.name == "grant" }).count == 1,
              let grant = items.first(where: { $0.name == "grant" })?.value, !grant.isEmpty else { return false }
        let data = Data((url.absoluteString + "\n").utf8)
        if #available(macOS 10.15.4, *) {
            do {
                try input.write(contentsOf: data)
            } catch {
                closeVerification(input)
                return false
            }
        } else {
            input.write(data)
        }
        closeVerification(input)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

}
