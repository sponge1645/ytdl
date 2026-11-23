import AppKit

final class NativePreferences: NSObject {
    static let config = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ytdl-settings.json")

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: config),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any] else { return [:] }
        return dictionary
    }

    static func migrateLegacyProxy() throws {
        var prefs = read()
        guard prefs["proxy_in_keychain"] as? Bool != true,
              let proxy = prefs["proxy"] as? String, !proxy.isEmpty else { return }
        try ProxyKeychain.write(proxy)
        prefs.removeValue(forKey: "proxy")
        prefs["proxy_in_keychain"] = true
        let data = try JSONSerialization.data(withJSONObject: prefs, options: .prettyPrinted)
        try data.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }

    private static let automaticAppUpdateKey = "auto_check_app_updates"

    static var automaticAppUpdateChecksEnabled: Bool {
        automaticAppUpdateChecksEnabled(in: read())
    }

    private static func automaticAppUpdateChecksEnabled(in prefs: [String: Any]) -> Bool {
        prefs[automaticAppUpdateKey] as? Bool != false
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let saved: () -> Void
    private let engineAction: (String, @escaping (String) -> Void) -> Void
    private let engineVersions = NSTextField(wrappingLabelWithString: "")
    private let engineStatus = NSTextField(wrappingLabelWithString: "")
    private var engineButtons: [NSButton] = []
    private let videoFolder = NSTextField()
    private let audioFolder = NSTextField()
    private let language = NSPopUpButton()
    private let languages = ["system", "en", "ru"]
    private let auto = NSButton(checkboxWithTitle: localized("Start new downloads automatically"), target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: localized("Automatically update tools"), target: nil, action: nil)
    private let autoCheckApp = NSButton(checkboxWithTitle: localized("Automatically check for app updates"), target: nil, action: nil)
    private let afterQueue = NSPopUpButton()
    private let queueActions = [("none", "Do nothing"), ("open_folder", "Open download folder"),
                                ("clear_completed", "Clear completed entries")]
    private let notificationOptions = [
        ("notify_added", "Notify when links are added", false),
        ("notify_started", "Notify when a download starts", false),
        ("notify_completed", "Notify when a download completes", true),
        ("notify_failed", "Notify when a download fails", true),
        ("notify_sound", "Play notification sounds", true)
    ]
    private var notificationButtons: [NSButton] = []
    private let parallel = NSPopUpButton()
    private let rate = NSTextField()
    private let youtubeBrowser = NSPopUpButton()
    private let safariAccess = NSButton()
    private let youtubeBrowsers = ["", "safari", "chrome", "firefox"]
    private let proxy = NSSecureTextField()
    private let supportsKeychainProxy: Bool
    private var proxyReadFailed = false
    private let output = NSPopUpButton()
    private let preset = NSPopUpButton()
    private let mp4 = NSButton(checkboxWithTitle: "MP4", target: nil, action: nil)
    private let webm = NSButton(checkboxWithTitle: "WebM", target: nil, action: nil)
    private let flv = NSButton(checkboxWithTitle: "FLV", target: nil, action: nil)
    private let numbering = NSButton(checkboxWithTitle: localized("Number playlist files"), target: nil, action: nil)
    private let separator = NSTextField()
    private let outputModes = ["auto", "original", "convert"]

    init(defaultFolder: URL, supportsKeychainProxy: Bool, engineAction: @escaping (String, @escaping (String) -> Void) -> Void,
         saved: @escaping () -> Void) {
        self.supportsKeychainProxy = supportsKeychainProxy
        self.engineAction = engineAction
        self.saved = saved
        super.init()
        let prefs = Self.read()
        window.title = localized("Settings")
        window.isReleasedWhenClosed = false
        videoFolder.stringValue = prefs["video_folder"] as? String ?? defaultFolder.path
        audioFolder.stringValue = prefs["audio_folder"] as? String ?? defaultFolder.path
        language.addItems(withTitles: [localized("System Language"), "English", "Русский"])
        language.selectItem(at: languages.firstIndex(of: prefs["language"] as? String ?? "system") ?? 0)
        auto.state = prefs["auto"] as? Bool == true ? .on : .off
        autoUpdate.state = prefs["auto_update_tools"] as? Bool == false ? .off : .on
        autoCheckApp.state = Self.automaticAppUpdateChecksEnabled(in: prefs) ? .on : .off
        afterQueue.addItems(withTitles: queueActions.map { localized($0.1) })
        afterQueue.selectItem(at: queueActions.firstIndex { $0.0 == (prefs["after_queue"] as? String) } ?? 0)
        notificationButtons = notificationOptions.map { key, title, defaultValue in
            let checkbox = NSButton(checkboxWithTitle: localized(title), target: nil, action: nil)
            checkbox.state = (prefs[key] as? Bool ?? defaultValue) ? .on : .off
            return checkbox
        }
        parallel.addItems(withTitles: (1...10).map { String($0) })
        parallel.selectItem(at: min(max(prefs["parallel"] as? Int ?? 3, 1), 10) - 1)
        rate.stringValue = String(prefs["rate"] as? Int ?? 0)
        if prefs["proxy_in_keychain"] as? Bool == true {
            do {
                proxy.stringValue = try ProxyKeychain.read()
            } catch {
                proxyReadFailed = true
                proxy.isEnabled = false
                proxy.toolTip = localized("Proxy unavailable. Update the tools or check Keychain access.")
            }
        } else {
            proxy.stringValue = prefs["proxy"] as? String ?? ""
        }
        youtubeBrowser.addItems(withTitles: [localized("Off"), "Safari", "Chrome", "Firefox"])
        youtubeBrowser.selectItem(at: youtubeBrowsers.firstIndex(of: prefs["youtube_cookie_browser"] as? String ?? "") ?? 0)
        youtubeBrowser.toolTip = localized("Use the selected browser session only when YouTube requires sign-in.")
        youtubeBrowser.target = self
        youtubeBrowser.action = #selector(youtubeBrowserChanged)
        safariAccess.title = localized("Full Disk Access…")
        safariAccess.bezelStyle = .rounded
        safariAccess.target = self
        safariAccess.action = #selector(requestSafariAccess)
        safariAccess.isEnabled = youtubeBrowser.indexOfSelectedItem == 1
        proxy.placeholderString = "socks5://127.0.0.1:1080"
        output.addItems(withTitles: ["Auto — MP4 for QuickTime", "Original streams", "Convert to MP4"].map(localized))
        output.selectItem(at: outputModes.firstIndex(of: prefs["video_output"] as? String ?? "auto") ?? 0)
        output.target = self
        output.action = #selector(updateOutputControls)
        preset.addItems(withTitles: ["H.264 — standard quality", "H.264 — high quality"].map(localized))
        preset.selectItem(at: prefs["video_preset"] as? String == "high" ? 1 : 0)
        let formats = prefs["native_formats"] as? [String] ?? ["mp4", "webm"]
        for (key, field) in [("mp4", mp4), ("webm", webm), ("flv", flv)] {
            field.state = formats.contains(key) ? .on : .off
        }
        numbering.state = prefs["number_playlist_files"] as? Bool == false ? .off : .on
        separator.stringValue = prefs["playlist_separator"] as? String ?? "-"
        separator.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let videoChooser = NSButton(title: localized("Choose…"), target: self, action: #selector(chooseVideo))
        let audioChooser = NSButton(title: localized("Choose…"), target: self, action: #selector(chooseAudio))
        let tabs = NSTabView()
        let restartHint = NSTextField(labelWithString: localized("Language changes take effect after restarting the app."))
        restartHint.textColor = .secondaryLabelColor
        addTab("General", to: tabs, with: [
            row("Language", language), restartHint,
            row("Video folder", videoFolder, trailing: videoChooser),
            row("Audio folder", audioFolder, trailing: audioChooser),
            row("Parallel downloads", parallel), auto,
            autoCheckApp, autoUpdate, row("After all downloads finish", afterQueue),
            numbering, row("Number separator", separator)
        ])
        addTab("Notifications", to: tabs, with: notificationButtons.map { $0 as NSView })
        let formatsRow = NSStackView(views: [mp4, webm, flv])
        formatsRow.spacing = 12
        addTab("Video Output", to: tabs, with: [
            row("Output mode", output), row("Original formats", formatsRow), row("Conversion preset", preset)
        ])
        addTab("Network", to: tabs, with: [
            row("Proxy", proxy), row("Speed limit (KiB/s)", rate),
            row("YouTube session", youtubeBrowser, trailing: safariAccess),
            NSTextField(labelWithString: localized("Set the speed limit to 0 for unlimited."))
        ])

        let check = NSButton(title: localized("Check Tools Now"), target: self, action: #selector(checkTools))
        let clean = NSButton(title: localized("Clean Old Kits"), target: self, action: #selector(cleanTools))
        engineButtons = [check, clean]
        engineStatus.maximumNumberOfLines = 3
        engineStatus.preferredMaxLayoutWidth = 470
        engineVersions.stringValue = localized("Loading tool versions…")
        let toolActions = NSStackView(views: engineButtons)
        var engineViews: [NSView] = [engineVersions, toolActions]
        if MusicPreview.script != nil {
            let checkMusic = NSButton(title: localized("Check Spotify and Apple Music"), target: self, action: #selector(checkMusicExtensions))
            let reinstallMusic = NSButton(title: localized("Reinstall Music Extensions"), target: self, action: #selector(reinstallMusicExtensions))
            engineButtons += [checkMusic, reinstallMusic]
            engineViews.append(NSStackView(views: [checkMusic, reinstallMusic]))
        }
        addTab("Engine", to: tabs, with: engineViews + [engineStatus])
        engineAction("tool-versions") { [weak self] in self?.engineVersions.stringValue = $0 }

        let cancel = NSButton(title: localized("Cancel"), target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: localized("Save"), target: self, action: #selector(save))
        apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [NSView(), cancel, apply])
        actions.spacing = 8
        let root = NSView()
        window.contentView = root
        for view in [tabs, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            tabs.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        updateOutputControls()
        window.center()
    }

    private func row(_ title: String, _ field: NSView, trailing: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: localized(title))
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 165).isActive = true
        let views: [NSView] = trailing.map { [label, field, $0] } ?? [label, field]
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    private func addTab(_ label: String, to tabs: NSTabView, with views: [NSView]) {
        let page = NSView()
        let fields = NSStackView(views: views)
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 12
        fields.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(fields)
        for view in views where view is NSStackView {
            view.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            fields.topAnchor.constraint(equalTo: page.topAnchor, constant: 14),
            fields.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 14),
            fields.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -14)
        ])
        let item = NSTabViewItem(identifier: label)
        item.label = localized(label)
        item.view = page
        tabs.addTabViewItem(item)
    }

    @objc private func checkMusicExtensions() { performEngineAction("check-music", status: "Checking music extensions…") }
    @objc private func reinstallMusicExtensions() { performEngineAction("reinstall-music", status: "Reinstalling music extensions…") }

    @objc private func checkTools() { performEngineAction("update-tools", status: "Checking for tool updates…") }
    @objc private func cleanTools() { performEngineAction("clean-tools", status: "Cleaning old tool kits…") }

    private func performEngineAction(_ action: String, status: String) {
        engineButtons.forEach { $0.isEnabled = false }
        engineStatus.stringValue = localized(status)
        engineAction(action) { [weak self] result in
            self?.engineStatus.stringValue = result
            self?.engineButtons.forEach { $0.isEnabled = true }
        }
    }

    @objc private func updateOutputControls() {
        for control in [mp4, webm, flv] { control.isEnabled = output.indexOfSelectedItem == 1 }
        preset.isEnabled = output.indexOfSelectedItem == 2
    }

    @objc private func chooseVideo() { chooseFolder(for: videoFolder) }
    @objc private func chooseAudio() { chooseFolder(for: audioFolder) }

    private func chooseFolder(for field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: field.stringValue).expandingTildeInPath)
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { field.stringValue = url.path }
        }
    }

    @objc private func close() { window.close() }

    private func error(_ message: String) {
        let alert = NSAlert()
        alert.messageText = localized(message)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func youtubeBrowserChanged() {
        safariAccess.isEnabled = youtubeBrowser.indexOfSelectedItem == 1
        if safariAccess.isEnabled { requestSafariAccess() }
    }

    @objc private func requestSafariAccess() {
        let alert = NSAlert()
        alert.messageText = localized("Allow Safari cookie access")
        alert.informativeText = localized("If access is not already enabled, add YouTube Downloader to Full Disk Access, then quit and reopen the app.")
        alert.addButton(withTitle: localized("Open System Settings"))
        alert.addButton(withTitle: localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(pane)
    }

    @objc private func save() {
        let video = videoFolder.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = audioFolder.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !video.isEmpty, !audio.isEmpty else { error("Choose both download folders."); return }
        guard let speed = Int(rate.stringValue), speed >= 0 else { error("Enter a non-negative speed limit."); return }
        let proxyAddress = proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxyAddress.isEmpty {
            guard let components = URLComponents(string: proxyAddress), let scheme = components.scheme,
                  ["http", "https", "socks5", "socks5h"].contains(scheme.lowercased()),
                  let host = components.host, !host.isEmpty,
                  components.path.isEmpty || components.path == "/",
                  !proxyAddress.contains("?"), !proxyAddress.contains("#"),
                  let authorityStart = proxyAddress.range(of: "://"),
                  let authority = proxyAddress[authorityStart.upperBound...].split(separator: "/").first,
                  let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last,
                  components.port.map({ (1...65535).contains($0) })
                    ?? (String(hostAndPort).range(of: #"(?:\]|^[^:\[\]]+):"#, options: .regularExpression) == nil),
                  proxyAddress.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                error("Invalid proxy URL. Check the host and port and percent-encode credentials."); return
            }
        }
        let delimiter = separator.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        guard delimiter.count <= 16, delimiter.rangeOfCharacter(from: forbidden) == nil else {
            error("Use up to 16 filename-safe characters for the separator."); return
        }
        let formats = [("mp4", mp4), ("webm", webm), ("flv", flv)].compactMap { key, control in
            control.state == .on ? key : nil
        }
        let mode = outputModes[output.indexOfSelectedItem]
        guard mode != "original" || !formats.isEmpty else { error("Select at least one original format."); return }
        var prefs = Self.read()
        prefs["language"] = languages[language.indexOfSelectedItem]
        prefs["video_folder"] = video
        prefs["audio_folder"] = audio
        prefs["auto"] = auto.state == .on
        prefs["auto_update_tools"] = autoUpdate.state == .on
        prefs[Self.automaticAppUpdateKey] = autoCheckApp.state == .on
        prefs["after_queue"] = queueActions[afterQueue.indexOfSelectedItem].0
        for (option, checkbox) in zip(notificationOptions, notificationButtons) {
            prefs[option.0] = checkbox.state == .on
        }
        prefs["parallel"] = parallel.indexOfSelectedItem + 1
        prefs["rate"] = speed
        prefs["youtube_cookie_browser"] = youtubeBrowsers[youtubeBrowser.indexOfSelectedItem]
        prefs["video_output"] = mode
        prefs["video_preset"] = preset.indexOfSelectedItem == 1 ? "high" : "standard"
        prefs["native_formats"] = formats
        prefs["number_playlist_files"] = numbering.state == .on
        prefs["playlist_separator"] = delimiter
        do {
            var removeStoredProxy = false
            if !proxyReadFailed {
                let previouslyStored = prefs["proxy_in_keychain"] as? Bool == true
                if !proxyAddress.isEmpty && (supportsKeychainProxy || previouslyStored) {
                    let existing: String? = previouslyStored ? (try ProxyKeychain.read()) : nil
                    if existing != proxyAddress {
                        try ProxyKeychain.write(proxyAddress)
                    }
                    prefs.removeValue(forKey: "proxy")
                    prefs["proxy_in_keychain"] = true
                } else {
                    removeStoredProxy = previouslyStored
                    prefs.removeValue(forKey: "proxy_in_keychain")
                    prefs["proxy"] = proxyAddress
                }
            }
            let data = try JSONSerialization.data(withJSONObject: prefs, options: .prettyPrinted)
            try data.write(to: Self.config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.config.path)
            if removeStoredProxy { ProxyKeychain.remove() }
            saved()
            close()
        } catch {
            self.error(error.localizedDescription)
        }
    }
}
