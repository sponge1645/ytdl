import AppKit
import Darwin
import UserNotifications

private final class Download {
    let id = UUID()
    let url: String
    let title: String
    let index: Int?
    var startedMode: String?
    var status = "Waiting"
    var progress: Double?
    var image: NSImage?
    var retry: DispatchWorkItem?
    var retryCount = 0
    var lastError = ""
    var files: [URL] = []
    var existingFiles: [URL] {
        files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var process: Process?
    var done = false
    var scheduled = false
    var pendingRemoval = false

    init(_ info: [String: Any]) {
        url = info["url"] as? String ?? ""
        title = info["title"] as? String ?? url
        index = info["index"] as? Int
    }
}

private final class EmptyQueueView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DropZoneIcon: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 13, yRadius: 13)
        border.lineWidth = 1.5
        let dash: [CGFloat] = [4, 4]
        border.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        border.stroke()

        let center = bounds.midX
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: center, y: 40))
        arrow.line(to: NSPoint(x: center, y: 21))
        arrow.move(to: NSPoint(x: center - 7, y: 28))
        arrow.line(to: NSPoint(x: center, y: 21))
        arrow.line(to: NSPoint(x: center + 7, y: 28))
        arrow.lineWidth = 2
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        arrow.stroke()
    }
}

private final class DownloadTable: NSTableView, NSMenuItemValidation {
    var rowMenu: ((Int) -> NSMenu?)?
    var selectedFiles: (() -> [URL])?

    @objc(copy:) func copySelectedFiles(_ sender: Any?) {
        writeFilesToPasteboard(selectedFiles?() ?? [])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(copySelectedFiles(_:)) || !(selectedFiles?() ?? []).isEmpty
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return rowMenu?(row(at: location))
    }
}

private func writeFilesToPasteboard(_ files: [URL]) {
    guard !files.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(files.map { $0 as NSURL })
}

private final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    let table = DownloadTable()
    private var logWindow: NSWindow?
    private var logTextView: NSTextView?
    private var logLines: [String] = []
    private var logRefreshScheduled = false
    private let visibleCount = NSTextField(labelWithString: "")
    private let queueCount = NSTextField(labelWithString: "0")
    private let completedCount = NSTextField(labelWithString: "0")
    let status = NSTextField(labelWithString: localized("Preparing download tools…"))
    let title = NSTextField(labelWithString: localized("Queue"))
    let empty = EmptyQueueView()
    let mode = NSSegmentedControl(labels: [localized("Video"), localized("Audio")], trackingMode: .selectOne, target: nil, action: nil)
    let quality = NSPopUpButton()
    var showCompleted = false
    var sidebarSelection: [NSBox] = []
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ytdl-native-" + UUID().uuidString)
    let resources = Bundle.main.resourceURL!
    var downloads: [Download] = []
    var toolsReady = false
    private var preferencesPanel: NativePreferences?
    var folder = UserDefaults.standard.url(forKey: "downloadFolder") ??
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    var rows: [Download] {
        downloads.filter { $0.done == showCompleted }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()
        UNUserNotificationCenter.current().delegate = self
        prepareTools()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkForAppUpdatesAutomatically()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        for item in downloads {
            if let process = item.process, process.isRunning { process.terminate() }
        }
        for item in downloads { item.process?.waitUntilExit() }
        try? FileManager.default.removeItem(at: temp)
    }

    private func buildMenus() {
        let bar = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu()
        application.submenu?.addItem(withTitle: localized("About YouTube Downloader"),
                                     action: #selector(showAbout), keyEquivalent: "").target = self
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(withTitle: localized("Settings…"), action: #selector(settings), keyEquivalent: ",").target = self
        application.submenu?.addItem(withTitle: localized("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(withTitle: localized("Quit YouTube Downloader"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem()
        file.submenu = NSMenu(title: localized("File"))
        file.submenu?.addItem(withTitle: localized("Paste Link"), action: #selector(pasteLink), keyEquivalent: "v").target = self
        file.submenu?.addItem(.separator())
        file.submenu?.addItem(withTitle: localized("Copy"), action: #selector(copyFile(_:)), keyEquivalent: "").target = self
        file.submenu?.addItem(withTitle: localized("Copy Link"), action: #selector(copyRowLink(_:)), keyEquivalent: "").target = self
        file.submenu?.addItem(withTitle: localized("Delete"), action: #selector(deleteDownload(_:)), keyEquivalent: "").target = self
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: localized("Edit"))
        editMenu.addItem(withTitle: localized("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu = editMenu
        let windowMenu = NSMenu(title: localized("Window"))
        windowMenu.addItem(withTitle: localized("Show Log"), action: #selector(showLog), keyEquivalent: "l").target = self
        let windows = NSMenuItem()
        windows.submenu = windowMenu
        bar.addItem(application)
        bar.addItem(file)
        bar.addItem(edit)
        bar.addItem(windows)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = bar
    }

    private func button(_ label: String, _ selector: Selector) -> NSButton {
        NSButton(title: localized(label), target: self, action: selector)
    }

    private func icon(_ symbol: String, fallback: NSImage.Name?, label: String, size: CGFloat) -> NSImage? {
        var source = fallback.flatMap { NSImage(named: $0) }
        if #available(macOS 11.0, *),
           let system = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            source = system.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? system
        }
        guard let source = source, source.size.width > 0, source.size.height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: size + 4, height: size + 4), flipped: false) { bounds in
            let scale = min(size / source.size.width, size / source.size.height)
            let width = source.size.width * scale
            let height = source.size.height * scale
            source.draw(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                  width: width, height: height), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func headerButton(_ label: String, symbol: String, fallback: NSImage.Name,
                              action: Selector) -> NSButton {
        let control = button(label, action)
        control.isBordered = false
        control.image = icon(symbol, fallback: fallback, label: localized(label), size: 18)
        control.imagePosition = .imageAbove
        control.font = .systemFont(ofSize: 11)
        control.toolTip = localized(label == "Paste Link" ? "Paste Link (⌘V)" : label)
        control.widthAnchor.constraint(equalToConstant: 70).isActive = true
        control.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return control
    }

    private func sidebarButton(_ label: String, symbol: String, fallback: NSImage.Name,
                               action: Selector) -> NSButton {
        let control = button(label, action)
        control.isBordered = false
        control.font = .systemFont(ofSize: 13, weight: .medium)
        control.image = icon(symbol, fallback: fallback, label: localized(label), size: 16)
        control.imagePosition = .imageLeft
        control.alignment = .left
        return control
    }

    private func sidebarRow(_ control: NSButton, count: NSTextField) -> NSBox {
        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 0
        background.cornerRadius = 6
        background.contentViewMargins = .zero
        control.translatesAutoresizingMaskIntoConstraints = false
        background.contentView?.addSubview(control)

        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .secondaryLabelColor
        count.alignment = .center
        count.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSBox()
        badge.boxType = .custom
        badge.borderWidth = 0
        badge.cornerRadius = 8
        badge.fillColor = .quaternaryLabelColor
        badge.contentViewMargins = .zero
        badge.translatesAutoresizingMaskIntoConstraints = false
        background.contentView?.addSubview(badge)
        badge.contentView?.addSubview(count)

        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            count.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            count.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            count.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            background.heightAnchor.constraint(equalToConstant: 28),
            control.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            control.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            control.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        return background
    }

    private func separator(vertical: Bool = false) -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let thickness = vertical ? line.widthAnchor : line.heightAnchor
        thickness.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func insetBar(_ bar: NSStackView) -> NSView {
        let container = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func buildWindow() {
        window.title = "YouTube Downloader"
        window.minSize = NSSize(width: 720, height: 400)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        let root = NSView()
        window.contentView = root

        let header = NSVisualEffectView()
        header.material = .titlebar
        header.blendingMode = .withinWindow
        let appName = NSTextField(labelWithString: "YouTube Downloader")
        appName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appName.font = .systemFont(ofSize: 15, weight: .semibold)
        appName.lineBreakMode = .byTruncatingTail
        let tools = NSStackView(views: [
            headerButton("Paste Link", symbol: "link", fallback: NSImage.addTemplateName,
                         action: #selector(pasteLink)),
            headerButton("Start All", symbol: "play", fallback: NSImage.goRightTemplateName,
                         action: #selector(startAll)),
            headerButton("Stop", symbol: "stop", fallback: NSImage.stopProgressTemplateName,
                         action: #selector(stopAll)),
            headerButton("Log", symbol: "list.bullet", fallback: NSImage.listViewTemplateName,
                         action: #selector(showLog)),
            headerButton("Settings", symbol: "gearshape", fallback: NSImage.actionTemplateName,
                         action: #selector(settings))
        ])
        tools.spacing = 6
        let divider = separator()
        let toolbarDivider = separator(vertical: true)
        for view in [appName, tools, divider, toolbarDivider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }

        let navigation = NSVisualEffectView()
        navigation.material = .sidebar
        navigation.blendingMode = .withinWindow
        let library = NSTextField(labelWithString: localized("LIBRARY"))
        library.font = .systemFont(ofSize: 10, weight: .semibold)
        library.textColor = .secondaryLabelColor
        let queueRow = sidebarRow(sidebarButton("Queue", symbol: "arrow.down.to.line",
                                                fallback: NSImage.addTemplateName, action: #selector(selectQueue)), count: queueCount)
        let completedRow = sidebarRow(sidebarButton("Completed", symbol: "checkmark.circle",
                                                    fallback: NSImage.statusAvailableName, action: #selector(selectCompleted)), count: completedCount)
        sidebarSelection = [queueRow, completedRow]
        let nav = NSStackView(views: [library, queueRow, completedRow] as [NSView])
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        let destination = sidebarButton("Downloads", symbol: "folder",
                                        fallback: NSImage.folderName, action: #selector(openFolder))
        let sidebarDivider = separator(vertical: true)
        let destinationDivider = separator()
        let destinationArrow = rowIconButton("", symbol: "chevron.right", fallback: NSImage.goRightTemplateName,
                                             action: #selector(openFolder), label: "Downloads")
        for view in [nav, destination, sidebarDivider, destinationDivider, destinationArrow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            navigation.addSubview(view)
        }
        for row in sidebarSelection {
            row.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }

        title.font = .systemFont(ofSize: 24, weight: .semibold)
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(changeMode)
        quality.target = self
        quality.action = #selector(changeQuality)
        changeMode()
        let qualityDivider = separator(vertical: true)
        qualityDivider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        quality.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let controls = NSStackView(views: [title, NSView(), mode, qualityDivider, quality])
        controls.alignment = .centerY
        controls.spacing = 10

        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.URL, .string])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.rowMenu = { [weak self] row in self?.downloadMenu(at: row) }
        table.selectedFiles = { [weak self] in
            guard let self = self else { return [] }
            let rows = self.rows
            return self.table.selectedRowIndexes.flatMap { index -> [URL] in
                guard rows.indices.contains(index), rows[index].done else { return [] }
                return rows[index].existingFiles
            }
        }
        table.rowHeight = 58
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (key, label, width) in [("title", "Title", 300.0), ("format", "Format", 58.0),
                                     ("status", "Status", 190.0), ("action", "", 78.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = localized(label)
            column.width = CGFloat(width)
            if key == "title" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let queue = NSView()
        queue.addSubview(scroll)
        queue.addSubview(empty)
        let heading = NSAttributedString(string: localized("No downloads yet"), attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.labelColor
        ])
        let hint = [
            localized("Public links from YouTube, Vimeo, TikTok, SoundCloud, Instagram and more"),
            localized("Drop a link here or press ⌘V")
        ].joined(separator: "\n")
        let emptyContent = NSMutableAttributedString(attributedString: heading)
        emptyContent.append(NSAttributedString(string: "\n\n" + hint, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        let dropHint = NSTextField(wrappingLabelWithString: "")
        let centeredParagraph = NSMutableParagraphStyle()
        centeredParagraph.alignment = .center
        emptyContent.addAttribute(.paragraphStyle, value: centeredParagraph,
                                  range: NSRange(location: 0, length: emptyContent.length))
        dropHint.attributedStringValue = emptyContent
        dropHint.preferredMaxLayoutWidth = 460
        let dropIcon = DropZoneIcon()
        dropIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dropIcon.widthAnchor.constraint(equalToConstant: 60),
            dropIcon.heightAnchor.constraint(equalToConstant: 60)
        ])
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 12
        empty.addArrangedSubview(dropIcon)
        empty.addArrangedSubview(dropHint)
        for view in [scroll, empty] { view.translatesAutoresizingMaskIntoConstraints = false }
        let footer = NSStackView(views: [visibleCount, status, NSView(), button("Clear List", #selector(clearList))])
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerDivider = separator()
        let insetControls = insetBar(controls)
        let insetFooter = insetBar(footer)
        let content = NSStackView(views: [insetControls, queue, footerDivider, insetFooter])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.setCustomSpacing(0, after: queue)
        content.setCustomSpacing(8, after: footerDivider)

        for view in [header, navigation, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [insetControls, queue, footerDivider, insetFooter] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let centeredTools = tools.centerXAnchor.constraint(equalTo: header.centerXAnchor)
        centeredTools.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 64),
            appName.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 82),
            appName.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toolbarDivider.leadingAnchor.constraint(equalTo: appName.trailingAnchor, constant: 14),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 32),
            toolbarDivider.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tools.leadingAnchor.constraint(greaterThanOrEqualTo: toolbarDivider.trailingAnchor, constant: 10),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -12),
            tools.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            centeredTools,
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: header.bottomAnchor),
            navigation.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 180),
            nav.leadingAnchor.constraint(equalTo: navigation.leadingAnchor, constant: 12),
            nav.topAnchor.constraint(equalTo: navigation.topAnchor, constant: 18),
            nav.trailingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: -10),
            destination.leadingAnchor.constraint(equalTo: navigation.leadingAnchor, constant: 14),
            destination.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            destinationArrow.trailingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: -8),
            destinationArrow.centerYAnchor.constraint(equalTo: destination.centerYAnchor),
            destination.trailingAnchor.constraint(lessThanOrEqualTo: destinationArrow.leadingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: navigation.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: navigation.bottomAnchor),
            sidebarDivider.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
            destinationDivider.leadingAnchor.constraint(equalTo: navigation.leadingAnchor),
            destinationDivider.trailingAnchor.constraint(equalTo: navigation.trailingAnchor),
            destinationDivider.centerYAnchor.constraint(equalTo: footerDivider.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: queue.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: queue.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: queue.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: queue.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: queue.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: queue.centerYAnchor)
        ])
        queue.setContentHuggingPriority(.defaultLow, for: .vertical)
        queue.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        switchPage()
    }

    private var updatedEngine: URL?
    private var bootstrapRunning = false
    private var installSheet: NSWindow?
    private let installProgress = NSProgressIndicator()
    private let installMessage = NSTextField(wrappingLabelWithString: "")
    private let installDetails = NSTextField(wrappingLabelWithString: "")
    private lazy var installRetry = button("Install Tools Again", #selector(retryToolInstall))
    private var isUniversalDownload: Bool {
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("bootstrap-tools.sh").path)
    }
    private var engineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private var engineCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YTDL/tool-kits-v1")
            .appendingPathComponent(engineArchitecture)
    }

    private func process(_ arguments: [String], executable: URL? = nil, event: @escaping ([String: Any]) -> Void,
                         finish: @escaping (Int32) -> Void) -> Process? {
        let bundledEngine = resources.appendingPathComponent("engine/ytdl-engine")
        let bundledActions = ["update-tools", "clean-tools", "tool-versions"]
        let engine = executable ?? (bundledActions.contains(arguments.first ?? "") && !isUniversalDownload
                                    ? bundledEngine : (updatedEngine ?? bundledEngine))
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            status.stringValue = localized("Download engine unavailable")
            appendLog(status.stringValue)
            return nil
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = engine
        process.arguments = arguments
        if let action = arguments.first, ["inspect", "download"].contains(action),
           NativePreferences.read()["proxy_in_keychain"] as? Bool == true {
            guard engineSupportsKeychainProxy, let proxy = try? ProxyKeychain.read() else {
                let message = localized("Proxy unavailable. Update the tools or check Keychain access.")
                status.stringValue = message
                appendLog(message)
                return nil
            }
            var environment = ProcessInfo.processInfo.environment
            environment["YTDL_DOWNLOAD_PROXY"] = proxy
            process.environment = environment
        }
        appendLog("→ " + (arguments.first ?? ""))
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            status.stringValue = error.localizedDescription
            appendLog(error.localizedDescription)
            return nil
        }
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            let reader = pipe.fileHandleForReading
            func deliver(_ line: Data) {
                let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                var message = json ?? ["event": "log", "status": String(decoding: line, as: UTF8.self)]
                if let status = message["status"] as? String {
                    message["status"] = Self.redactCredentials(status)
                }
                let sanitizedMessage = message
                DispatchQueue.main.async { [weak self] in
                    if let line = sanitizedMessage["status"] as? String {
                        self?.appendLog(line)
                    } else if let path = sanitizedMessage["path"] as? String {
                        self?.appendLog(path)
                    }
                    event(sanitizedMessage)
                }
            }
            while true {
                let block = reader.availableData
                if block.isEmpty { break }
                pending.append(block)
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    deliver(line)
                }
            }
            if !pending.isEmpty { deliver(pending) }
            process.waitUntilExit()
            DispatchQueue.main.async { finish(process.terminationStatus) }
        }
        return process
    }

    private func loadCachedEngine() {
        let root = engineCache
        updatedEngine = nil
        if let value = try? String(contentsOf: root.appendingPathComponent("current"), encoding: .ascii) {
            let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if version.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil {
                let engine = root.appendingPathComponent(version + "/engine/ytdl-engine")
                let kit = engine.deletingLastPathComponent().deletingLastPathComponent()
                let legacyTool = kit.appendingPathComponent("bin/gallery-dl")
                if FileManager.default.isExecutableFile(atPath: engine.path),
                   !FileManager.default.fileExists(atPath: legacyTool.path) { updatedEngine = engine }
            }
        }
    }

    private func prepareTools() {
        let key = resources.appendingPathComponent("tools-update-public.pem")
        let updatesConfigured = FileManager.default.fileExists(atPath: key.path)
        if updatesConfigured { loadCachedEngine() }
        if isUniversalDownload && updatedEngine == nil {
            runBootstrap(mode: "install")
            return
        }
        startEngine()
        if updatesConfigured && NativePreferences.read()["auto_update_tools"] as? Bool != false {
            if isUniversalDownload {
                runBootstrap(mode: "auto")
            } else {
                _ = process(["update-tools"], event: { _ in }, finish: { _ in })
            }
        }
    }

    @objc private func retryToolInstall() { runBootstrap(mode: "install") }

    private func showInstallSheet(stage: String) {
        if installSheet == nil {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 92),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = localized("Set Up Download Tools")
            let content = NSView()
            sheet.contentView = content
            installProgress.maxValue = 100
            installDetails.textColor = .secondaryLabelColor
            installDetails.isSelectable = true
            installDetails.maximumNumberOfLines = 4
            installDetails.preferredMaxLayoutWidth = 340
            installMessage.preferredMaxLayoutWidth = 340
            let fields = NSStackView(views: [installMessage, installProgress, installDetails, installRetry])
            fields.orientation = .vertical
            fields.alignment = .leading
            fields.spacing = 10
            fields.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(fields)
            NSLayoutConstraint.activate([
                fields.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                fields.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                fields.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                installMessage.widthAnchor.constraint(equalTo: fields.widthAnchor),
                installProgress.widthAnchor.constraint(equalTo: fields.widthAnchor),
                installDetails.widthAnchor.constraint(equalTo: fields.widthAnchor)
            ])
            installSheet = sheet
            window.beginSheet(sheet)
        }
        installSheet?.setContentSize(NSSize(width: 380, height: 92))
        installMessage.stringValue = localized(stage)
        installDetails.stringValue = ""
        installDetails.isHidden = true
        installRetry.isHidden = true
        installProgress.isHidden = false
        installProgress.isIndeterminate = true
        installProgress.startAnimation(nil)
    }

    private func updateInstallStep(_ step: Int, downloadPercent: Double? = nil) {
        let stages = ["Checking engine manifest…", "Downloading tools…", "Verifying tools…",
                      "Installing tools…", "Checking installed tools…", "Starting tools…"]
        guard stages.indices.contains(step - 1) else { return }
        let percent = min(100, max(0, downloadPercent ?? 0))
        let name = localized(stages[step - 1])
        let progress = downloadPercent == nil ? name : name + " " + String(Int(percent)) + "%"
        installMessage.stringValue = String(format: localized("Step %d of %d — %@"), step, stages.count, progress)
        installProgress.stopAnimation(nil)
        installProgress.isIndeterminate = false
        installProgress.doubleValue = (Double(step - 1) + percent / 100) / Double(stages.count) * 100
    }

    private func showInstallError(_ message: String) {
        showInstallSheet(stage: "Could not install the download tools.")
        installSheet?.setContentSize(NSSize(width: 380, height: 166))
        installProgress.stopAnimation(nil)
        installProgress.isHidden = true
        installDetails.stringValue = message
        installDetails.isHidden = false
        installRetry.isHidden = false
    }

    private func closeInstallSheet() {
        guard let sheet = installSheet else { return }
        installProgress.stopAnimation(nil)
        window.endSheet(sheet)
        sheet.orderOut(nil)
        installSheet = nil
    }

    private func runBootstrap(mode: String, reply: ((String) -> Void)? = nil) {
        let installing = mode == "install"
        let root = engineCache
        let fm = FileManager.default
        let recent: (String, TimeInterval) -> Bool = { name, interval in
            let url = root.appendingPathComponent(name)
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            return Date().timeIntervalSince(modified) < interval
        }
        if mode == "auto" && (recent("checked", 86400) || recent("attempted", 900)) { return }
        let busy = localized("Another tools operation is in progress.")
        if bootstrapRunning { reply?(busy); return }
        if installing {
            showInstallSheet(stage: "Checking engine manifest…")
            updateInstallStep(1)
        }
        let failed = localized("Could not install the download tools.")
        let showFailure: (String) -> Void = { [weak self] message in
            guard let self = self else { return }
            self.appendLog(message)
            if installing { self.showInstallError(message) }
            reply?(message)
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            showFailure(error.localizedDescription)
            return
        }
        let lock = Darwin.open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { showFailure(failed); return }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lock)
            showFailure(busy)
            return
        }
        if mode == "auto" {
            let marker = root.appendingPathComponent("attempted")
            try? Data().write(to: marker, options: .atomic)
        }
        bootstrapRunning = true

        let script = resources.appendingPathComponent("bootstrap-tools.sh")
        let key = resources.appendingPathComponent("tools-update-public.pem")
        let args = [script.path, key.path, root.path, engineArchitecture, mode]
        var latestMessage = ""
        var recentMessages: [String] = []
        let task = process(args, executable: URL(fileURLWithPath: "/bin/bash"), event: { [weak self] event in
            guard let self = self, let line = event["status"] as? String else { return }
            if line.hasPrefix("STEP "), let step = Int(line.dropFirst(5)) {
                if installing { self.updateInstallStep(step) }
                return
            }
            if line.hasPrefix("PROGRESS "), let percent = Double(line.dropFirst(9)), percent.isFinite {
                if installing { self.updateInstallStep(2, downloadPercent: percent) }
                return
            }
            latestMessage = localized(line)
            recentMessages.append(latestMessage)
            if recentMessages.count > 3 { recentMessages.removeFirst() }

        }, finish: { [weak self] code in
            Darwin.close(lock)
            guard let self = self else { return }
            self.bootstrapRunning = false
            guard code == 0 else {
                showFailure(recentMessages.isEmpty ? failed : recentMessages.joined(separator: "\n"))
                return
            }
            if installing {
                self.loadCachedEngine()
                self.startEngine()
            }
            reply?(latestMessage)
        })
        if task == nil {
            Darwin.close(lock)
            bootstrapRunning = false
            showFailure(failed)
        }
    }

    private var engineUsesModeKeys = false
    private var engineSupportsKeychainProxy = false

    private func startEngine() {
        engineUsesModeKeys = false
        engineSupportsKeychainProxy = false
        if isUniversalDownload {
            showInstallSheet(stage: "Checking installed tools…")
            updateInstallStep(6)
        }
        var engineError = ""
        let setup = process(["setup"], event: { [weak self] message in
            if message["event"] as? String == "capabilities" {
                self?.engineUsesModeKeys = message["mode_keys"] as? Bool == true
                self?.engineSupportsKeychainProxy = message["proxy_environment"] as? Bool == true
            }
            if let label = message["status"] as? String {
                engineError = localized(label)
                self?.status.stringValue = engineError
            }
        }, finish: { [weak self] code in
            guard let self = self else { return }
            if code != 0 && self.isUniversalDownload {
                self.showInstallError(engineError.isEmpty ? localized("Download engine unavailable") : engineError)
                return
            }
            if code != 0 && self.updatedEngine != nil {
                self.updatedEngine = nil
                self.startEngine()
                return
            }
            self.toolsReady = code == 0
            if code == 0 {
                self.closeInstallSheet()
                self.status.stringValue = localized("Ready · ⌘V to add a link")
                if self.engineSupportsKeychainProxy {
                    do {
                        try NativePreferences.migrateLegacyProxy()
                    } catch {
                        let message = localized("Could not move proxy settings to Keychain.")
                        self.status.stringValue = message
                        self.appendLog(message)
                    }
                }
                self.checkForAppUpdatesAutomatically()
            }
        })
        if setup == nil && isUniversalDownload {
            showInstallError(status.stringValue)
        } else if setup == nil && updatedEngine != nil {
            updatedEngine = nil
            startEngine()
        }
    }

    private static func redactCredentials(_ message: String) -> String {
        let sanitized = message.replacingOccurrences(of: #"(?i)(\b(?:https?|socks5h?)://)[^:/?#@\s'"<>]+:(?![0-9]+[/?#])[^\s'"<>]+@(?=[a-z0-9\[])"#,
                                                     with: "$1[redacted]@", options: .regularExpression)
        return sanitized.replacingOccurrences(of: #"(?i)(\b[a-z][a-z0-9+.\-]*://)[^\s/?#'"<>]+@"#,
                                     with: "$1[redacted]@", options: .regularExpression)
    }

    private func appendLog(_ message: String) {
        logLines.append(String(Self.redactCredentials(message).prefix(4000)))
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        guard logWindow?.isVisible == true, !logRefreshScheduled else { return }
        logRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.logRefreshScheduled = false
            if self.logWindow?.isVisible == true { self.refreshLog() }
        }
    }

    private func refreshLog() {
        guard let view = logTextView else { return }
        view.string = logLines.joined(separator: "\n")
        view.scrollRangeToVisible(NSRange(location: (view.string as NSString).length, length: 0))
    }

    @objc private func showLog() {
        if logWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = localized("Download Log")
            let scroll = NSTextView.scrollableTextView()
            let view = scroll.documentView as? NSTextView
            view?.isEditable = false
            view?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            panel.contentView = scroll
            panel.center()
            logTextView = view
            logWindow = panel
        }
        logWindow?.makeKeyAndOrderFront(nil)
        refreshLog()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    private static let lastAutomaticAppUpdateCheck = "lastAutomaticAppUpdateCheck"
    private var checkingAppUpdates = false
    private var lastAutomaticAppUpdateAttempt: Date?
    private var showAppUpdateResult = false

    private func checkForAppUpdatesAutomatically() {
        guard !checkingAppUpdates, toolsReady, window.attachedSheet == nil,
              NativePreferences.automaticAppUpdateChecksEnabled else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: Self.lastAutomaticAppUpdateCheck) as? Date,
           last <= now, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        if let last = lastAutomaticAppUpdateAttempt, last <= now,
           now.timeIntervalSince(last) < 5 * 60 { return }
        lastAutomaticAppUpdateAttempt = now
        requestAppUpdate(manual: false)
    }

    @objc private func checkForUpdates() {
        requestAppUpdate(manual: true)
    }

    private func requestAppUpdate(manual: Bool) {
        if manual { showAppUpdateResult = true }
        guard !checkingAppUpdates else { return }
        checkingAppUpdates = true
        let endpoint = URL(string: "https://api.github.com/repos/sponge1645/ytdl/releases/latest")!
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var releaseTag: String?
            if (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
               let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let tag = release["tag_name"] as? String,
               tag.range(of: #"^v[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil {
                releaseTag = tag
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingAppUpdates = false
                let manual = self.showAppUpdateResult
                self.showAppUpdateResult = false
                let alert = NSAlert()
                var releaseURL: URL?
                if let tag = releaseTag {
                    UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticAppUpdateCheck)
                    let version = String(tag.dropFirst())
                    if App.compareAppVersions(installed, version) == .orderedAscending {
                        alert.messageText = String(format: localized("Version %@ is available."), version)
                        releaseURL = URL(string: "https://github.com/sponge1645/ytdl/releases/tag/" + tag)
                    } else {
                        guard manual else { return }
                        alert.messageText = localized("You’re up to date.")
                    }
                } else {
                    guard manual else { return }
                    alert.messageText = localized("Could not check for app updates.")
                    releaseURL = URL(string: "https://github.com/sponge1645/ytdl/releases/latest")
                }
                if releaseURL != nil { alert.addButton(withTitle: localized("Open Release")) }
                alert.addButton(withTitle: "OK")
                if manual {
                    if alert.runModal() == .alertFirstButtonReturn, let url = releaseURL {
                        NSWorkspace.shared.open(url)
                    }
                } else if NativePreferences.automaticAppUpdateChecksEnabled,
                          self.window.attachedSheet == nil, let url = releaseURL {
                    alert.beginSheetModal(for: self.window) { result in
                        if result == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }.resume()
    }

    private static func compareAppVersions(_ first: String, _ second: String) -> ComparisonResult {
        let lhs = first.split(separator: ".").compactMap { Int($0) }
        let rhs = second.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func notify(_ title: String, body: String, setting: String, enabledByDefault: Bool = false) {
        let prefs = NativePreferences.read()
        guard (prefs[setting] as? Bool ?? enabledByDefault) else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = localized(title)
        content.body = body
        let errorSound = resources.appendingPathComponent("Basso.aiff")
        if prefs["notify_sound"] as? Bool != false {
            content.sound = setting == "notify_failed" && FileManager.default.fileExists(atPath: errorSound.path)
                ? UNNotificationSound(named: UNNotificationSoundName(rawValue: "Basso.aiff")) : .default
        }
        center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            if allowed {
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
                           withCompletionHandler: nil)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    private func links(from pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap { ($0 as? NSURL)?.absoluteString } ?? []
        let text = pasteboard.string(forType: .string) ?? ""
        var seen = Set<String>()
        return (urls + text.split(whereSeparator: { $0.isWhitespace }).map(String.init)).filter {
            guard let url = URL(string: $0), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else { return false }
            return seen.insert($0).inserted
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard showCompleted, rows.indices.contains(row), let file = rows[row].existingFiles.first else { return nil }
        return file as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard toolsReady, !links(from: info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        let dropped = links(from: info.draggingPasteboard)
        guard toolsReady, !dropped.isEmpty else { return false }
        addLinks(dropped)
        return true
    }

    @objc private func pasteLink() {
        guard toolsReady else { NSSound.beep(); return }
        let pasted = links(from: NSPasteboard.general)
        guard !pasted.isEmpty else { status.stringValue = localized("Copy an HTTP or HTTPS link first."); return }
        addLinks(pasted)
    }

    private func addLinks(_ links: [String]) {
        showCompleted = false
        switchPage()
        for link in links {
            status.stringValue = localized("Reading link…")
            _ = process(["inspect", link], event: { [weak self] message in
                guard let self = self else { return }
                if let items = message["items"] as? [[String: Any]] {
                    let added = items.map { Download($0) }
                    self.downloads.append(contentsOf: added)
                    if let first = added.first {
                        self.notify("Links added", body: added.count == 1 ? first.title : itemCount(added.count),
                                    setting: "notify_added")
                    }
                    if NativePreferences.read()["auto"] as? Bool == true {
                        added.forEach { self.schedule($0) }
                        self.dispatch()
                    }
                    if self.status.stringValue == localized("Reading link…") { self.status.stringValue = "" }
                    self.refresh()
                    for (info, item) in zip(items, added) {
                        guard let raw = info["thumbnail"] as? String, let url = URL(string: raw),
                              url.scheme == "https" else { continue }
                        URLSession.shared.dataTask(with: url) { [weak self, weak item] data, _, _ in
                            guard let data = data else { return }
                            DispatchQueue.main.async {
                                item?.image = NSImage(data: data)
                                self?.refresh()
                            }
                        }.resume()
                    }
                } else if let label = message["status"] as? String {
                    self.status.stringValue = localized(label)
                }
            }, finish: { _ in })
        }
    }

    private var formatChoices: [String] {
        mode.selectedSegment == 1 ? ["MP3", "M4A"] : ["best", "2160p", "1080p", "720p", "480p"]
    }

    private var selectedFormat: String {
        let choices = formatChoices
        let index = quality.indexOfSelectedItem
        return choices.indices.contains(index) ? choices[index] : choices[0]
    }

    @objc private func changeMode() {
        quality.removeAllItems()
        quality.addItems(withTitles: formatChoices.map {
            $0 == "best" ? localized("Best available") : $0
        })
        quality.selectItem(at: 0)
        refresh()
    }

    @objc private func changeQuality() { refresh() }

    private func schedule(_ item: Download) {
        item.retry?.cancel()
        item.retry = nil
        item.retryCount = 0
        item.startedMode = item.startedMode ?? selectedFormat
        item.status = "Waiting"
        item.scheduled = true
    }

    @objc private func selectQueue() {
        showCompleted = false
        switchPage()
    }

    @objc private func selectCompleted() {
        showCompleted = true
        switchPage()
    }

    private func switchPage() {
        for (index, row) in sidebarSelection.enumerated() {
            row.fillColor = index == (showCompleted ? 1 : 0)
                ? NSColor.controlAccentColor.withAlphaComponent(0.24) : .clear
        }
        title.stringValue = localized(showCompleted ? "Completed" : "Queue")
        refresh()
    }

    @objc private func startAll() {
        for item in downloads where !item.done && !item.pendingRemoval && item.process == nil {
            schedule(item)
        }
        dispatch()
    }

    @objc private func stopAll() {
        for item in downloads where !item.done { stop(item) }
        refresh()
    }

    private func stop(_ item: Download) {
        item.retry?.cancel()
        item.retry = nil
        item.scheduled = false
        item.status = "Paused"
        item.progress = nil
        if let process = item.process, process.isRunning { process.terminate() }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(outputFolder(for: "video_folder")) }

    private func outputFolder(for key: String) -> URL {
        if let path = NativePreferences.read()[key] as? String, !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return folder
    }

    @objc private func settings() {
        if let existing = preferencesPanel, existing.window.isVisible {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let preferences = NativePreferences(defaultFolder: folder, supportsKeychainProxy: engineSupportsKeychainProxy, engineAction: { [weak self] action, reply in
            self?.runEngineAction(action, reply: reply)
        }) { [weak self] in
            self?.dispatch()
            self?.checkForAppUpdatesAutomatically()
        }
        preferencesPanel = preferences
        preferences.window.makeKeyAndOrderFront(nil)
    }

    private func runEngineAction(_ action: String, reply: @escaping (String) -> Void) {
        if isUniversalDownload && action == "update-tools" {
            runBootstrap(mode: toolsReady ? "manual" : "install", reply: reply)
            return
        }
        let engineRoot = updatedEngine?.deletingLastPathComponent().deletingLastPathComponent() ?? resources
        let arguments: [String]
        switch action {
        case "tool-versions": arguments = [action, engineRoot.path]
        case "clean-tools": arguments = [action, updatedEngine == nil ? "" : engineRoot.lastPathComponent]
        default: arguments = ["update-tools", "--manual"]
        }
        var result = ""
        let task = process(arguments, event: { message in
            if let versions = message["versions"] as? [String: String] {
                result = ["yt-dlp", "parth-dl", "ffmpeg", "ffprobe", "deno"]
                    .map { $0 + "  " + (versions[$0] ?? "—") }.joined(separator: "\n")
            } else if let count = message["count"] as? Int {
                result = String(format: localized("Old kits removed: %d"), count)
            } else if let value = message["status"] as? String {
                result = localized(value)
            }
        }, finish: { _ in
            reply(result.isEmpty ? localized("Tool operation failed.") : result)
        })
        if task == nil { reply(localized("Tool operation failed.")) }
    }

    @objc private func clearList() {
        for item in rows where !item.pendingRemoval { clear(item) }
        refresh()
    }

    @objc private func clearDownload(_ sender: NSMenuItem) {
        if let item = menuDownload(sender) {
            clear(item)
            refresh()
        }
    }

    private func clear(_ item: Download) {
        item.retry?.cancel()
        item.retry = nil
        if item.process != nil {
            item.pendingRemoval = true
            stop(item)
        } else {
            delete(item, trashFile: false)
        }
    }

    private func dispatch() {
        let active = downloads.filter { $0.process != nil }.count
        let limit = NativePreferences.read()["parallel"] as? Int ?? 3
        let available = max(0, min(max(limit, 1), 10) - active)
        for item in downloads.filter({ $0.scheduled && !$0.pendingRemoval && $0.process == nil }).prefix(available) {
            begin(item)
        }
        refresh()
    }

    private func begin(_ item: Download) {
        let selectedMode = item.startedMode ?? selectedFormat
        item.startedMode = selectedMode
        let audio = ["MP3", "M4A"].contains(selectedMode) && !item.url.contains("instagram.com/")
        let destination = outputFolder(for: audio ? "audio_folder" : "video_folder")
        let engineMode = selectedMode == "best" && !engineUsesModeKeys ? "Лучшее видео" : selectedMode
        var request: [String: Any] = ["url": item.url, "mode": engineMode, "folder": destination.path,
                                      "temporary": temp.appendingPathComponent(item.id.uuidString).path]
        if let index = item.index { request["index"] = index }
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        item.scheduled = false
        item.status = "Connecting…"
        item.lastError = ""
        item.process = process(["download", String(decoding: data, as: UTF8.self)], event: { [weak self, weak item] message in
            guard let self = self, let item = item else { return }
            switch message["event"] as? String {
            case "file":
                if let path = message["path"] as? String {
                    let file = URL(fileURLWithPath: path)
                    if !item.files.contains(file) { item.files.append(file) }
                }
            case "progress":
                if item.status != "Paused" {
                    item.status = message["status"] as? String ?? item.status
                    if let raw = message["percent"] as? String,
                       let value = Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) {
                        item.progress = value
                    } else { item.progress = nil }
                }
            case "error":
                if let label = message["status"] as? String {
                    item.lastError = label
                    self.status.stringValue = localized(label)
                }
            default: return
            }
            self.refresh()
        }, finish: { [weak self, weak item] code in
            guard let self = self, let item = item else { return }
            item.process = nil
            item.progress = nil
            if item.pendingRemoval {
                self.delete(item, trashFile: false)
                self.dispatch()
                return
            }
            if item.status != "Paused" {
                if code != 0 && self.retryIfTransient(item) {
                    self.dispatch()
                    return
                }
                item.done = code == 0
                item.status = item.done ? "Done" : "Error"
                let title = item.done ? "Download completed" : "Download failed"
                let setting = item.done ? "notify_completed" : "notify_failed"
                self.notify(title, body: item.title, setting: setting, enabledByDefault: true)
            }
            self.dispatch()
            if item.done { self.finishQueueIfNeeded(last: item) }
        })
        if item.process == nil {
            item.status = "Error"
            notify("Download failed", body: item.title, setting: "notify_failed", enabledByDefault: true)
        } else {
            notify("Download started", body: item.title, setting: "notify_started")
        }
    }

    private func retryIfTransient(_ item: Download) -> Bool {
        let delays = [5, 15]
        guard item.retryCount < delays.count, item.files.isEmpty else { return false }
        let error = item.lastError.lowercased()
        let permanent = ["429", "too many requests", "sign in", "login", "private", "unsupported"]
        let transient = ["timed out", "timeout", "connection reset", "connection refused",
                         "connection aborted", "network is unreachable", "temporary failure in name resolution",
                         "remote end closed", "http error 500", "http error 502", "http error 503", "http error 504"]
        guard !permanent.contains(where: { error.contains($0) }),
              transient.contains(where: { error.contains($0) }) else { return false }
        let delay = delays[item.retryCount]
        item.retryCount += 1
        item.status = String(format: localized("Retry in %d s"), delay)
        appendLog(item.status + " · " + item.title)
        let retry = DispatchWorkItem { [weak self, weak item] in
            guard let self = self, let item = item, item.retry != nil else { return }
            item.retry = nil
            item.status = "Waiting"
            item.scheduled = true
            self.dispatch()
        }
        item.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: retry)
        return true
    }

    private func finishQueueIfNeeded(last item: Download) {
        guard !downloads.isEmpty, downloads.allSatisfy({ $0.done }) else { return }
        switch NativePreferences.read()["after_queue"] as? String {
        case "open_folder":
            if let folder = item.existingFiles.last?.deletingLastPathComponent() { NSWorkspace.shared.open(folder) }
        case "clear_completed":
            downloads.removeAll { $0.done }
            refresh()
        default:
            break
        }
    }

    @objc private func rowAction(_ button: NSButton) {
        guard rows.indices.contains(button.tag) else { return }
        performRowAction(rows[button.tag])
    }

    private func performRowAction(_ item: Download) {
        guard !item.pendingRemoval else { return }
        if item.done {
            NSWorkspace.shared.activateFileViewerSelecting(item.existingFiles)
        } else if item.process != nil {
            stop(item)
        } else {
            schedule(item)
            dispatch()
        }
        refresh()
    }

    private func refresh() {
        let completed = downloads.filter { $0.done }.count
        queueCount.stringValue = String(downloads.count - completed)
        completedCount.stringValue = String(completed)
        let count = rows.count
        visibleCount.stringValue = itemCount(count)
        empty.isHidden = showCompleted || count > 0
        table.reloadData()
    }

    private func centeredCell(_ content: NSView) -> NSView {
        let cell = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        let backgrounds = NSColor.alternatingContentBackgroundColors
        rowView.backgroundColor = backgrounds[row % backgrounds.count]
    }

    private func rowIconButton(_ glyph: String, symbol: String, fallback: NSImage.Name?,
                               action: Selector, label: String) -> NSButton {
        let control = button(glyph, action)
        let caption = localized(label)
        control.isBordered = false
        control.image = icon(symbol, fallback: fallback, label: caption, size: 15)
        if control.image != nil { control.imagePosition = .imageOnly }
        control.toolTip = caption
        control.setAccessibilityLabel(caption)
        control.widthAnchor.constraint(equalToConstant: 30).isActive = true
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return control
    }

    @objc private func showRowMenu(_ button: NSButton) {
        downloadMenu(at: button.tag)?.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func downloadMenu(at row: Int) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = rows.indices.contains(row) ? rows[row] : nil
        func add(_ title: String, _ selector: Selector, enabled: Bool) {
            let entry = menu.addItem(withTitle: localized(title), action: selector, keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.isEnabled = enabled
        }
        let canClear = rows.contains { !$0.pendingRemoval }
        guard let item = item else {
            add("Paste Link", #selector(pasteLink), enabled: toolsReady)
            add("Clear", #selector(clearList), enabled: canClear)
            return menu
        }
        let fileExists = !item.existingFiles.isEmpty
        add("Force Download", #selector(forceDownload(_:)),
            enabled: toolsReady && !item.done && !item.pendingRemoval && item.process == nil)
        add("Stop", #selector(stopDownload(_:)),
            enabled: !item.done && !item.pendingRemoval && (item.scheduled || item.process != nil || item.retry != nil))
        add("Open", #selector(openDownload(_:)), enabled: item.done && fileExists)
        add("Delete", #selector(deleteDownload(_:)), enabled: item.done && !item.pendingRemoval)
        add("Clear", #selector(clearDownload(_:)), enabled: !item.done && !item.pendingRemoval)
        add("Show in Finder", #selector(revealDownload(_:)), enabled: fileExists)
        menu.addItem(.separator())
        add("Copy", #selector(copyFile(_:)), enabled: item.done && fileExists)
        add("Copy Link", #selector(copyRowLink(_:)), enabled: !item.url.isEmpty)
        return menu
    }

    @objc private func forceDownload(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Download,
              toolsReady, !item.done, !item.pendingRemoval, item.process == nil else { return }
        item.retry?.cancel()
        item.retry = nil
        item.retryCount = 0
        begin(item)
        refresh()
    }

    @objc private func stopDownload(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Download, !item.done else { return }
        stop(item)
        refresh()
    }

    @objc private func revealDownload(_ sender: NSMenuItem) {
        guard let item = menuDownload(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(item.existingFiles)
    }

    private func menuDownload(_ sender: NSMenuItem) -> Download? {
        if let item = sender.representedObject as? Download { return item }
        return rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pasteLink): return toolsReady
        case #selector(deleteDownload(_:)): return menuDownload(menuItem)?.done == true
        case #selector(copyFile(_:)): return !completedFiles(menuItem).isEmpty
        case #selector(copyRowLink(_:)): return !(menuDownload(menuItem)?.url.isEmpty ?? true)
        default: return true
        }
    }

    private func completedFiles(_ sender: NSMenuItem) -> [URL] {
        guard let item = menuDownload(sender), item.done else { return [] }
        return item.existingFiles
    }

    @objc private func openDownload(_ sender: NSMenuItem) {
        if let file = completedFiles(sender).first { NSWorkspace.shared.open(file) }
    }

    @objc private func copyFile(_ sender: NSMenuItem) {
        writeFilesToPasteboard(completedFiles(sender))
    }

    @objc private func deleteDownload(_ sender: NSMenuItem) {
        guard let item = menuDownload(sender), item.done else { return }
        delete(item, trashFile: true)
        refresh()
    }

    private func delete(_ item: Download, trashFile: Bool) {
        item.pendingRemoval = false
        do {
            if trashFile {
                for file in item.existingFiles {
                    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                }
            }
            let partial = temp.appendingPathComponent(item.id.uuidString)
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            downloads.removeAll { $0 === item }
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    @objc private func copyRowLink(_ sender: NSMenuItem) {
        guard let item = menuDownload(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url, forType: .string)
    }

    private func rowActionTitle(_ item: Download) -> String {
        if item.done { return "Show in Finder" }
        if item.status == "Paused" { return "Resume" }
        return item.process != nil ? "Pause" : "Start"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let key = column?.identifier.rawValue else { return nil }
        let item = rows[row]
        switch key {
        case "title":
            let image = NSImageView(image: item.image ?? NSImage(named: NSImage.multipleDocumentsName) ?? NSImage())
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = 6
            image.layer?.masksToBounds = true
            image.widthAnchor.constraint(equalToConstant: 84).isActive = true
            image.heightAnchor.constraint(equalToConstant: 47.25).isActive = true
            let prefix = item.index.map { String(format: "%02d · ", $0) } ?? ""
            let label = NSTextField(labelWithString: prefix + item.title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let cell = NSStackView(views: [image, label])
            cell.spacing = 10
            cell.alignment = .centerY
            return cell
        case "format":
            let selectedMode = item.startedMode ?? selectedFormat
            let format = item.files.last?.pathExtension.uppercased() ??
                (item.url.contains("instagram.com/") ? "Media" : (["MP3", "M4A"].contains(selectedMode) ? selectedMode : "MP4"))
            let badge = NSTextField(labelWithString: localized(format))
            badge.font = .systemFont(ofSize: 11, weight: .medium)
            badge.alignment = .center
            let background = NSBox()
            background.boxType = .custom
            background.borderWidth = 0
            background.cornerRadius = 5
            background.fillColor = .quaternaryLabelColor
            background.contentViewMargins = .zero
            background.contentView = centeredCell(badge)
            background.widthAnchor.constraint(equalToConstant: 42).isActive = true
            background.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let badgeRow = NSStackView(views: [background, NSView()])
            badgeRow.alignment = .centerY
            return centeredCell(badgeRow)
        case "status":
            let label = NSTextField(labelWithString: localized(item.status))
            label.textColor = item.done ? .systemGreen : (item.status == "Error" ? .systemRed : .labelColor)
            if let progress = item.progress {
                let bar = NSProgressIndicator()
                bar.controlSize = .small
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 100
                bar.doubleValue = progress
                let percent = NSTextField(labelWithString: NumberFormatter.localizedString(
                    from: NSNumber(value: progress / 100), number: .percent))
                percent.setContentCompressionResistancePriority(.required, for: .horizontal)
                let cell = NSStackView(views: [bar, percent])
                cell.alignment = .centerY
                cell.spacing = 8
                cell.toolTip = label.stringValue
                bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
                return centeredCell(cell)
            }
            return centeredCell(label)
        default:
            let label = rowActionTitle(item)
            let appearance: (String, String, NSImage.Name?)
            if item.done {
                appearance = ("✓", "checkmark.circle", NSImage.statusAvailableName)
            } else if label == "Pause" {
                appearance = ("Ⅱ", "pause", nil)
            } else {
                appearance = ("▷", "play", NSImage.goRightTemplateName)
            }
            let control = rowIconButton(appearance.0, symbol: appearance.1, fallback: appearance.2,
                                        action: #selector(rowAction(_:)), label: label)
            let more = rowIconButton("…", symbol: "ellipsis", fallback: nil,
                                     action: #selector(showRowMenu(_:)), label: "More Actions")
            control.tag = row
            more.tag = row
            control.isEnabled = !item.pendingRemoval && (!item.done || !item.existingFiles.isEmpty)
            let actions = NSStackView(views: [NSView(), control, more])
            actions.alignment = .centerY
            actions.spacing = 4
            return centeredCell(actions)
        }
    }
}

let application = NSApplication.shared
private let delegate = App()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
