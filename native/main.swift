import AppKit
import Darwin
import ImageIO
import Quartz
import UserNotifications

private final class Download {
    let id = UUID()
    let url: String
    var title: String
    let index: Int?
    var startedMode: String?
    var music = false
    var musicTrackJSON: String?
    var inspectingMusic = false
    var musicBatchInterrupted = false
    var musicCollection: UUID?
    var collectionTitle: String?
    var numberedPlaylist = false
    var musicFormat = "FLAC"
    var musicSource = 0
    var status = "Waiting"
    var progress: Double?
    var thumbnailURL: URL?
    var retry: DispatchWorkItem?
    var retryCount = 0
    var didRetryYouTubeSession = false
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

private final class QueueTitleCell: NSStackView {
    let thumbnail = NSImageView()
    let caption = NSTextField(labelWithString: "")
    var thumbnailURL: URL?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.widthAnchor.constraint(equalToConstant: 84).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 47.25).isActive = true
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(thumbnail)
        addArrangedSubview(caption)
        spacing = 10
        alignment = .centerY
    }

    required init?(coder: NSCoder) { fatalError("QueueTitleCell is created in code") }
}

private final class DownloadTable: NSTableView, NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var rowMenu: ((Int) -> NSMenu?)?
    var selectedFiles: (() -> [URL])?
    var removeSelection: (() -> Void)?
    private var previewFiles: [URL] = []

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if !event.isARepeat { toggleQuickLook() }
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117), !selectedRowIndexes.isEmpty,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            removeSelection?()
            return
        }
        super.keyDown(with: event)
    }

    private func toggleQuickLook() {
        guard let files = selectedFiles?(), !files.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            previewFiles = files
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !previewFiles.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewFiles.removeAll()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewFiles.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewFiles.indices.contains(index) else { return nil }
        return previewFiles[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if !event.isARepeat { panel.orderOut(nil) }
        return true
    }

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
    private var displayedRows: [Download] = []
    private var displayedRowIDs: [UUID] = []
    private let thumbnails = NSCache<NSURL, NSImage>()
    private var thumbnailRequests: Set<URL> = []
    private var thumbnailFailures: Set<URL> = []
    private var dirtyStatusRows: Set<UUID> = []
    private var refreshingRows = false
    private var logWindow: NSWindow?
    private var logTextView: NSTextView?
    private var logLines: [String] = []
    private var logRefreshScheduled = false
    private let visibleCount = NSTextField(labelWithString: "")
    private let queueCount = NSTextField(labelWithString: "0")
    private let completedCount = NSTextField(labelWithString: "0")
    private let status = NSTextField(labelWithString: localized("Preparing download tools…"))
    private var statusClearTimer: Timer?
    let title = NSTextField(labelWithString: localized("Queue"))
    let empty = EmptyQueueView()
    let mode = NSSegmentedControl(labels: [localized("Video"), localized("Audio")], trackingMode: .selectOne, target: nil, action: nil)
    let quality = NSPopUpButton()
    private var qualityWidth: NSLayoutConstraint?
    private var sharedAudioFormat: String?
    private var queuedMusicFormat: String?
    let musicSource = NSPopUpButton()
    private weak var musicSelection: Download?
    private var previousMode = 0
    private var previousFormat = "best"
    private let musicSources = ["", "amazon", "tidal-web", "qobuz-web", "deezer", "ytmusic-spotiflac", "beatport", "jiosaavn"]
    var showCompleted = false
    var sidebarSelection: [NSBox] = []
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ytdl-native-" + UUID().uuidString)
    let resources = Bundle.main.resourceURL!
    var downloads: [Download] = []
    var toolsReady = false
    private let musicPreview = MusicPreview()
    private var pendingSafariLinks: [String] = []
    private var preferencesPanel: NativePreferences?
    var folder = UserDefaults.standard.url(forKey: "downloadFolder") ??
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    var rows: [Download] {
        downloads.filter { $0.done == showCompleted && !$0.pendingRemoval }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        buildWindow()
        UNUserNotificationCenter.current().delegate = self
        prepareTools()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { musicPreview.acceptVerification(url) }
        let links = urls.compactMap { url -> String? in
            guard url.scheme == "ytdl", url.host == "youtube",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/video/") else { return nil }
            let id = String(url.path.dropFirst("/video/".count))
            guard id.utf8.count == 11,
                  id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            return "https://www.youtube.com/watch?v=" + id
        }
        guard !links.isEmpty else { return }
        if toolsReady {
            window.makeKeyAndOrderFront(nil)
            addLinks(links)
        } else {
            pendingSafariLinks.append(contentsOf: links)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkForAppUpdatesAutomatically()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        musicPreview.stop()
        for item in downloads {
            if let process = item.process, process.isRunning { process.terminate() }
        }
        for item in downloads { item.process?.waitUntilExit() }
        try? FileManager.default.removeItem(at: temp)
    }

    private func buildMenus() {
        let bar = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "Media Downloader")
        application.submenu?.addItem(withTitle: localized("About Media Downloader"),
                                     action: #selector(showAbout), keyEquivalent: "").target = self
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(withTitle: localized("Settings…"), action: #selector(settings), keyEquivalent: ",").target = self
        application.submenu?.addItem(withTitle: localized("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(withTitle: localized("Quit Media Downloader"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editMenu.addItem(withTitle: localized("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        window.title = "Media Downloader"
        window.minSize = NSSize(width: 720, height: 400)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        let root = NSView()
        window.contentView = root

        let header = NSVisualEffectView()
        header.material = .titlebar
        header.blendingMode = .withinWindow
        let appName = NSTextField(labelWithString: "Media Downloader")
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
        let width = quality.widthAnchor.constraint(equalToConstant: 160)
        width.isActive = true
        qualityWidth = width
        musicSource.addItems(withTitles: [localized("Automatic"), "Amazon Music", "Tidal", "Qobuz", "Deezer", "YouTube Music", "Beatport", "JioSaavn"])
        musicSource.toolTip = localized("Audio source")
        musicSource.target = self
        musicSource.action = #selector(changeMusicSource)
        musicSource.isHidden = true
        let controls = NSStackView(views: [title, NSView(), mode, qualityDivider, quality, musicSource])
        controls.alignment = .centerY
        controls.spacing = 10

        thumbnails.countLimit = 256
        table.dataSource = self
        table.allowsMultipleSelection = true
        table.removeSelection = { [weak self] in self?.removeSelectedRows() }
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
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (key, label, width) in [("title", "Title", 335.0), ("format", "Format", 58.0),
                                     ("status", "Status", 112.0), ("action", "", 78.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = localized(label)
            column.width = CGFloat(width)
            if key == "title" {
                column.resizingMask = .autoresizingMask
            } else if key == "action" {
                column.resizingMask = []
                column.minWidth = CGFloat(width)
                column.maxWidth = CGFloat(width)
            }
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
        let hint = MusicPreview.script == nil
            ? localized("Paste (⌘V) or drop a link from YouTube, Vimeo, OK.ru, VK, Rutube, TikTok, SoundCloud, Instagram, Artlist and more.")
            : localized("Paste (⌘V) or drop a link from YouTube, Vimeo, OK.ru, VK, Rutube, Spotify, Apple Music, YouTube Music, SoundCloud, TikTok, Instagram, Amazon Music, Tidal, Qobuz, Deezer, Beatport, JioSaavn, Artlist and more.")
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
        status.isSelectable = true
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

    private func setFooterStatus(_ message: String, error: Bool = false, duration: TimeInterval? = nil) {
        statusClearTimer?.invalidate()
        statusClearTimer = nil
        if status.stringValue != message {
            status.abortEditing()
            status.stringValue = message
            status.toolTip = message.isEmpty ? nil : message
        }
        if let interval = duration ?? (error ? 15 : nil), !message.isEmpty {
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                self?.setFooterStatus("")
            }
            statusClearTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func process(_ arguments: [String], executable: URL? = nil, event: @escaping ([String: Any]) -> Void,
                         finish: @escaping (Int32) -> Void) -> Process? {
        let bundledEngine = resources.appendingPathComponent("engine/ytdl-engine")
        let bundledActions = ["update-tools", "clean-tools", "tool-versions"]
        let engine = executable ?? (bundledActions.contains(arguments.first ?? "") && !isUniversalDownload
                                    ? bundledEngine : (updatedEngine ?? bundledEngine))
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            setFooterStatus(localized("Download engine unavailable"), error: true)
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
                setFooterStatus(message, error: true)
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
            setFooterStatus(error.localizedDescription, error: true)
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
    private var engineSupportsArtlist = false
    private var engineSupportsKeychainProxy = false

    private func startEngine() {
        engineUsesModeKeys = false
        engineSupportsArtlist = false
        engineSupportsKeychainProxy = false
        if isUniversalDownload {
            showInstallSheet(stage: "Checking installed tools…")
            updateInstallStep(6)
        }
        var engineError = ""
        let setup = process(["setup"], event: { [weak self] message in
            if message["event"] as? String == "capabilities" {
                self?.engineSupportsArtlist = message["artlist_preview"] as? Bool == true
                self?.engineUsesModeKeys = message["mode_keys"] as? Bool == true
                self?.engineSupportsKeychainProxy = message["proxy_environment"] as? Bool == true
            }
            if let label = message["status"] as? String {
                engineError = localized(label)
                self?.setFooterStatus(engineError, error: message["event"] as? String == "error")
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
                self.setFooterStatus(localized("Ready · Paste (⌘V)"))
                if self.engineSupportsKeychainProxy {
                    do {
                        try NativePreferences.migrateLegacyProxy()
                    } catch {
                        let message = localized("Could not move proxy settings to Keychain.")
                        self.setFooterStatus(message, error: true)
                        self.appendLog(message)
                    }
                }
                if !self.pendingSafariLinks.isEmpty {
                    let links = self.pendingSafariLinks
                    self.pendingSafariLinks.removeAll()
                    self.addLinks(links)
                }
                self.checkForAppUpdatesAutomatically()
            } else {
                self.setFooterStatus(engineError.isEmpty ? localized("Download engine unavailable") : engineError, error: true)
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

    private var installingAppUpdate = false
    private static let skippedAppVersion = "skippedAppVersion"

    private func requestAppUpdate(manual: Bool) {
        guard !installingAppUpdate else { return }
        if manual { showAppUpdateResult = true }
        guard !checkingAppUpdates else { return }
        checkingAppUpdates = true
        let endpoint = URL(string: "https://api.github.com/repos/sponge1645/ytdl/releases/latest")!
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var update: AppUpdate?
            var hasSignedArchive = false
            if (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
               let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let tag = release["tag_name"] as? String,
               tag.range(of: #"^v[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil {
                let candidate = AppUpdate(tag: tag)
                update = candidate
                let names = (release["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let archive = "Media-Downloader-\(candidate.version).zip"
                hasSignedArchive = names.contains(archive) && names.contains(archive + ".sig")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingAppUpdates = false
                let manual = self.showAppUpdateResult
                self.showAppUpdateResult = false
                let defaults = UserDefaults.standard
                guard let update = update else {
                    if manual { self.showAppUpdateMessage("Could not check for app updates.") }
                    return
                }
                defaults.set(Date(), forKey: Self.lastAutomaticAppUpdateCheck)
                guard Self.compareAppVersions(installed, update.version) == .orderedAscending else {
                    if manual { self.showAppUpdateMessage("You’re up to date.") }
                    return
                }
                if !manual {
                    guard defaults.string(forKey: Self.skippedAppVersion) != update.version,
                          NativePreferences.automaticAppUpdateChecksEnabled,
                          self.window.attachedSheet == nil else { return }
                }
                let alert = NSAlert()
                alert.messageText = String(format: localized("Version %@ is available."), update.version)
                alert.addButton(withTitle: localized(hasSignedArchive ? "Install Update" : "Open Release"))
                alert.addButton(withTitle: localized("Remind Me Later"))
                alert.addButton(withTitle: localized("Skip This Version"))
                let respond: (NSApplication.ModalResponse) -> Void = { result in
                    if result == .alertFirstButtonReturn {
                        if hasSignedArchive { self.installAppUpdate(update) }
                        else { NSWorkspace.shared.open(update.releaseURL) }
                    } else if result == .alertThirdButtonReturn {
                        defaults.set(update.version, forKey: Self.skippedAppVersion)
                    }
                }
                if manual { respond(alert.runModal()) }
                else { alert.beginSheetModal(for: self.window, completionHandler: respond) }
            }
        }.resume()
    }

    private func showAppUpdateMessage(_ message: String, release: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = localized(message)
        if release != nil { alert.addButton(withTitle: localized("Open Release")) }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn, let release = release {
            NSWorkspace.shared.open(release)
        }
    }

    private var downloadsBusy: Bool {
        downloads.contains { $0.process != nil || $0.scheduled || $0.retry != nil }
    }

    private func installAppUpdate(_ update: AppUpdate) {
        guard !installingAppUpdate else { return }
        guard !downloadsBusy else {
            showAppUpdateMessage("Finish or stop downloads before installing the update.")
            return
        }
        installingAppUpdate = true
        setFooterStatus(localized("Downloading app update…"))
        update.prepare { result in
            do {
                let staged = try result.get()
                let directory = staged.deletingLastPathComponent()
                guard !self.downloadsBusy else {
                    try? FileManager.default.removeItem(at: directory)
                    self.installingAppUpdate = false
                    self.setFooterStatus("")
                    self.showAppUpdateMessage("Finish or stop downloads before installing the update.")
                    return
                }
                let installed = Bundle.main.bundleURL
                do { try AppUpdate.swap(staged, with: installed) }
                catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { app, error in
                    DispatchQueue.main.async {
                        if app != nil && error == nil {
                            try? FileManager.default.removeItem(at: directory)
                            NSApp.terminate(nil)
                        } else {
                            if (try? AppUpdate.swap(staged, with: installed)) != nil {
                                try? FileManager.default.removeItem(at: directory)
                            }
                            self.appUpdateFailed(update)
                        }
                    }
                }
            } catch {
                self.appUpdateFailed(update)
            }
        }
    }

    private func appUpdateFailed(_ update: AppUpdate) {
        installingAppUpdate = false
        setFooterStatus("")
        showAppUpdateMessage("Could not install the app update.", release: update.releaseURL)
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
        return (urls + text.split(whereSeparator: { $0.isWhitespace }).map(String.init)).map { MusicPreview.script == nil ? $0 : MusicPreview.normalizedLink($0) }.filter {
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
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text), url.scheme?.lowercased() == "mornye" {
            if !musicPreview.acceptVerification(url) {
                setFooterStatus(localized("This return link does not match an active verification. Retry the track for a new link."), error: true)
            }
            return
        }
        guard toolsReady else { NSSound.beep(); return }
        let pasted = links(from: NSPasteboard.general)
        guard !pasted.isEmpty else {
            setFooterStatus(localized("Copy an HTTP or HTTPS link first."), error: true)
            return
        }
        addLinks(pasted)
    }

    private func isArtlistLink(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host?.lowercased() else { return false }
        return host == "artlist.io" || host.hasSuffix(".artlist.io")
    }

    private var askingForYouTubeSession = false

    private func isYouTubeSessionError(_ message: String, for link: String) -> Bool {
        let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]
        guard let host = URL(string: link)?.host?.lowercased(), hosts.contains(host) else { return false }
        let error = message.lowercased().replacingOccurrences(of: "’", with: "'")
        return error.contains("[youtube]") && error.contains("sign in to confirm you're not a bot")
    }

    private func showSafariAccessIfNeeded(_ message: String) -> Bool {
        let error = message.lowercased()
        guard NativePreferences.read()["youtube_cookie_browser"] as? String == "safari",
              error.contains("cookies.binarycookies"),
              error.contains("operation not permitted") || error.contains("permission denied") else { return false }
        if !askingForYouTubeSession {
            askingForYouTubeSession = true
            defer { askingForYouTubeSession = false }
            NativePreferences.showSafariAccessInstructions()
        }
        return true
    }

    private func requestYouTubeSession(for link: String) -> Bool {
        guard !askingForYouTubeSession, let url = URL(string: link) else { return false }
        askingForYouTubeSession = true
        defer { askingForYouTubeSession = false }

        let browsers = ["safari", "chrome", "firefox"]
        let bundleIDs = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"]
        let picker = NSPopUpButton()
        picker.addItems(withTitles: ["Safari", "Chrome", "Firefox"])
        picker.sizeToFit()
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let id = Bundle(url: app)?.bundleIdentifier,
           let index = bundleIDs.firstIndex(of: id) {
            picker.selectItem(at: index)
        } else {
            picker.selectItem(at: -1)
        }
        let alert = NSAlert()
        alert.messageText = localized("Allow YouTube browser cookies?")
        alert.informativeText = localized("Choose a browser where you are signed in to YouTube. YTDL will remember your choice and use its cookies when YouTube requires sign-in. Safari may require Full Disk Access.")
        alert.accessoryView = picker
        alert.addButton(withTitle: localized("Allow"))
        alert.addButton(withTitle: localized("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              browsers.indices.contains(picker.indexOfSelectedItem) else { return false }
        var prefs = NativePreferences.read()
        prefs["youtube_cookie_browser"] = browsers[picker.indexOfSelectedItem]
        do {
            let data = try JSONSerialization.data(withJSONObject: prefs, options: .prettyPrinted)
            try data.write(to: NativePreferences.config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: NativePreferences.config.path)
            return true
        } catch {
            setFooterStatus(error.localizedDescription, error: true)
            return false
        }
    }

    private func addLinks(_ links: [String], canAskForYouTubeSession: Bool = true) {
        showCompleted = false
        switchPage()
        for link in links {
            if isArtlistLink(link) && !engineSupportsArtlist {
                setFooterStatus(localized("Update the download tools to use Artlist."), error: true)
                continue
            }
            if MusicPreview.script != nil && MusicPreview.accepts(link) {
                addMusic(link)
                continue
            }
            showMusicControls(for: nil)
            setFooterStatus(localized("Reading link…"))
            var needsYouTubeSession = false
            var inspectError = ""
            _ = process(["inspect", link], event: { [weak self] message in
                guard let self = self else { return }
                if message["event"] as? String == "youtube_session_required" {
                    needsYouTubeSession = true
                } else if let items = message["items"] as? [[String: Any]] {
                    let added = items.map { Download($0) }
                    for (info, item) in zip(items, added) {
                        item.thumbnailURL = Self.thumbnailURL(info["thumbnail"])
                        item.collectionTitle = info["playlist_title"] as? String
                    }
                    self.downloads.append(contentsOf: added)
                    if let first = added.first {
                        self.notify("Links added", body: added.count == 1 ? first.title : itemCount(added.count),
                                    setting: "notify_added")
                    }
                    if NativePreferences.read()["auto"] as? Bool == true {
                        added.forEach { self.schedule($0) }
                        self.dispatch()
                    }
                    if self.status.stringValue == localized("Reading link…") { self.setFooterStatus("") }
                    self.refresh()
                } else if let label = message["status"] as? String {
                    let isError = message["event"] as? String == "error"
                    if isError { inspectError = label }
                    needsYouTubeSession = needsYouTubeSession || (isError && self.isYouTubeSessionError(label, for: link))
                    self.setFooterStatus(localized(label), error: isError)
                }
            }, finish: { [weak self] code in
                guard let self = self, code != 0 else { return }
                if self.showSafariAccessIfNeeded(inspectError) { return }
                guard canAskForYouTubeSession, needsYouTubeSession,
                      self.requestYouTubeSession(for: link) else { return }
                self.addLinks([link], canAskForYouTubeSession: false)
            })
        }
    }

    private func addMusic(_ link: String) {
        let item = Download(["url": link])
        item.music = true
        let preferred = queuedMusicFormat ?? defaultMusicFormat(for: item)
        item.musicFormat = musicFormatChoices(for: item).contains(preferred) ? preferred : defaultMusicFormat(for: item)
        downloads.append(item)
        refresh()
        if table.selectedRowIndexes.isEmpty, let row = rows.firstIndex(where: { $0 === item }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        var metadata: [String: Any]?
        item.inspectingMusic = true
        item.process = musicPreview.run(link: link, folder: outputFolder(for: "audio_folder"),
                                        source: nil, format: "FLAC", inspect: true, status: { [weak self] message in
            self?.setFooterStatus(localized(message))
        },
                                        event: { [weak self] kind, data in
            if kind == "YTDL_VERIFICATION_RESULT" {
                self?.showVerificationResult(data)
            } else if kind == "YTDL_METADATA" {
                metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }, finish: { [weak self, weak item] code, message in
            guard let self = self, let item = item else { return }
            item.process = nil
            item.inspectingMusic = false
            if item.pendingRemoval {
                self.delete(item, trashFile: false)
            } else if code == 0, let info = metadata,
                      let tracks = info["tracks"] as? [[String: Any]], !tracks.isEmpty {
                let kind = info["kind"] as? String
                let folderTitle: String?
                switch kind {
                case "playlist": folderTitle = info["collection_title"] as? String ?? localized("Playlist")
                case "album": folderTitle = info["collection_title"] as? String ?? localized("Album")
                default: folderTitle = nil
                }
                self.expandMusic(item, tracks: tracks, collection: kind != "track",
                                 folderTitle: folderTitle, numberFiles: kind == "playlist",
                                 skipped: info["skipped"] as? Int ?? 0)
            } else if item.status != "Paused" {
                item.lastError = message.isEmpty ? localized("Could not read music tracks.") : message
                item.scheduled = false
                item.startedMode = nil
                item.status = "Error"
                self.setFooterStatus(item.lastError, error: true)
            }
            self.dispatch()
        })
        if item.process == nil {
            item.inspectingMusic = false
            item.status = "Error"
            setFooterStatus("Could not launch the music engine.", error: true)
        }
        refresh()
    }

    private func expandMusic(_ item: Download, tracks: [[String: Any]], collection: Bool, folderTitle: String?, numberFiles: Bool, skipped: Int) {
        guard let index = downloads.firstIndex(where: { $0 === item }) else { return }
        let autoDownload = NativePreferences.read()["auto"] as? Bool == true
        let added = tracks.enumerated().compactMap { offset, track -> Download? in
            guard let name = track["name"] as? String, let artist = track["artists"] as? String,
                  !name.isEmpty, !artist.isEmpty else { return nil }
            var metadata = track
            if numberFiles { metadata["playlist_index"] = offset + 1 }
            guard let encoded = try? JSONSerialization.data(withJSONObject: metadata) else { return nil }
            let row = collection ? Download(["url": item.url, "index": offset + 1]) : item
            row.title = "\(artist) — \(name)"
            row.music = true
            row.musicTrackJSON = String(decoding: encoded, as: UTF8.self)
            row.musicCollection = collection ? item.id : nil
            row.collectionTitle = folderTitle
            row.numberedPlaylist = numberFiles
            row.musicSource = item.musicSource
            row.musicFormat = item.musicFormat
            row.status = item.status
            row.thumbnailURL = Self.thumbnailURL(track["cover_url"])
            if item.status != "Paused" && (item.scheduled || autoDownload) {
                schedule(row)
            }
            return row
        }
        downloads.replaceSubrange(index...index, with: added)
        if skipped > 0 {
            setFooterStatus(String(format: localized("%d unavailable tracks skipped."), skipped))
        }
        refresh(replacing: item.id, with: added.first?.id)
    }

    private func pendingMusicGroup(for item: Download) -> [Download] {
        guard let group = item.musicCollection else { return [item] }
        return downloads.filter { $0.musicCollection == group && !$0.done && !$0.pendingRemoval && $0.startedMode == nil }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingRows else { return }
        updateMusicControlsForSelection()
    }

    private func updateMusicControlsForSelection() {
        let row = table.selectedRow
        if rows.indices.contains(row) {
            let item = rows[row]
            showMusicControls(for: item.music && !item.done ? item : nil)
        } else {
            showMusicControls(for: nil)
        }
    }

    private func showMusicControls(for item: Download?) {
        let resetSharedFormat = sharedAudioFormat != nil && !downloads.contains {
            $0.music && !$0.done && !$0.pendingRemoval
        }
        if resetSharedFormat { sharedAudioFormat = nil }
        quality.isEnabled = item?.startedMode == nil
        musicSource.isEnabled = item?.startedMode == nil
        if let item = item {
            guard musicSelection !== item else { return }
        } else if mode.isEnabled && !resetSharedFormat {
            return
        }
        if mode.isEnabled && !resetSharedFormat {
            previousMode = mode.selectedSegment
            previousFormat = selectedFormat
        }
        musicSelection = item
        musicSource.isHidden = item == nil
        qualityWidth?.constant = item == nil ? 160 : 228
        mode.isEnabled = item == nil
        if let item = item {
            mode.selectedSegment = 1
            musicSource.selectItem(at: item.musicSource)
        } else {
            mode.selectedSegment = sharedAudioFormat == nil ? previousMode : 1
        }
        let shared = sharedAudioFormat
        changeMode()
        sharedAudioFormat = shared
        if item == nil, let index = formatChoices.firstIndex(of: shared ?? previousFormat) {
            quality.selectItem(at: index)
            refresh()
        }
    }

    @objc private func changeMusicSource() {
        if let item = musicSelection, item.startedMode == nil {
            item.musicSource = musicSource.indexOfSelectedItem
            for row in pendingMusicGroup(for: item) {
                row.musicSource = item.musicSource
                if !musicFormatChoices(for: row).contains(row.musicFormat) {
                    row.musicFormat = defaultMusicFormat(for: row)
                }
            }
            changeMode()
        }
    }

    private func explicitMusicSource(for item: Download) -> String? {
        let index = item.musicSource
        return musicSources.indices.contains(index) && index > 0 ? musicSources[index] : nil
    }

    private func effectiveSource(for item: Download) -> String {
        if let source = explicitMusicSource(for: item) { return source }
        guard let host = URL(string: item.url)?.host else { return "amazon" }
        if host == "music.youtube.com" { return "ytmusic-spotiflac" }
        if host == "beatport.com" || host == "www.beatport.com" { return "beatport" }
        if host == "jiosaavn.com" || host == "www.jiosaavn.com" { return "jiosaavn" }
        if host == "tidal.com" || host.hasSuffix(".tidal.com") { return "tidal-web" }
        if host == "qobuz.com" || host.hasSuffix(".qobuz.com") { return "qobuz-web" }
        if host == "deezer.com" || host.hasSuffix(".deezer.com") || host == "deezer.page.link" { return "deezer" }
        return "amazon"
    }

    private func defaultMusicFormat(for item: Download) -> String {
        ["ytmusic-spotiflac", "jiosaavn"].contains(effectiveSource(for: item)) ? "M4A" : "FLAC"
    }

    private func musicFormatChoices(for item: Download) -> [String] {
        let manualSource = explicitMusicSource(for: item)
        var choices = manualSource == nil || defaultMusicFormat(for: item) == "FLAC" ? ["FLAC"] : []
        let source = effectiveSource(for: item)
        if manualSource == nil || source == "tidal-web" || source == "qobuz-web" { choices.append("FLAC-CD") }
        choices.append("M4A")
        if manualSource == nil || source == "tidal-web" { choices.append("M4A-ATMOS") }
        if manualSource == nil || source == "amazon" { choices += ["M4A-DDP", "MP4-ATMOS"] }
        choices.append("MP3")
        return choices
    }

    private var formatChoices: [String] {
        if let item = musicSelection { return musicFormatChoices(for: item) }
        return mode.selectedSegment == 1 ? ["MP3", "M4A"] : ["best", "2160p", "1080p", "720p", "480p"]
    }

    private var regularFormat: String {
        if let shared = sharedAudioFormat, downloads.contains(where: { $0.music && !$0.done }) {
            return shared
        }
        return musicSelection == nil ? selectedFormat : previousFormat
    }

    private func formatLabel(_ format: String) -> String {
        guard let item = musicSelection else { return format == "best" ? localized("Best available") : format }
        switch format {
        case "FLAC": return ["deezer", "beatport"].contains(effectiveSource(for: item)) ? "FLAC (Lossless)" : "FLAC (Hi-Res)"
        case "FLAC-CD": return "FLAC (Lossless)"
        case "M4A": return "M4A (AAC)"
        case "M4A-DDP": return "M4A (Dolby Digital Plus)"
        case "M4A-ATMOS": return "M4A (Dolby Atmos)"
        case "MP4-ATMOS": return "MP4 (Dolby Atmos)"
        case "MP3": return "MP3 (320 kbit/s)"
        default: return format
        }
    }

    private var selectedFormat: String {
        let choices = formatChoices
        let index = quality.indexOfSelectedItem
        return choices.indices.contains(index) ? choices[index] : choices[0]
    }

    @objc private func changeMode() {
        if musicSelection == nil { sharedAudioFormat = nil }
        quality.removeAllItems()
        quality.addItems(withTitles: formatChoices.map { formatLabel($0) })
        quality.selectItem(at: formatChoices.firstIndex(of: musicSelection?.musicFormat ?? "") ?? 0)
        refresh()
    }

    @objc private func changeQuality() {
        if let item = musicSelection, item.startedMode == nil {
            queuedMusicFormat = selectedFormat
            for row in pendingMusicGroup(for: item) { row.musicFormat = selectedFormat }
            if selectedFormat == "MP3" || selectedFormat == "M4A" {
                let shared = selectedFormat
                sharedAudioFormat = shared
                for pending in downloads where pending.music && !pending.done && pending.startedMode == nil && pending !== item && (item.musicCollection == nil || pending.musicCollection != item.musicCollection) {
                    pending.musicFormat = shared
                }
            } else {
                sharedAudioFormat = nil
            }
        } else if musicSelection == nil {
            sharedAudioFormat = nil
        }
        refresh()
    }

    private func schedule(_ item: Download) {
        item.retry?.cancel()
        item.retry = nil
        item.retryCount = 0
        item.didRetryYouTubeSession = false
        if !item.music { item.startedMode = item.startedMode ?? regularFormat }
        item.status = "Waiting"
        item.scheduled = true
    }

    @objc private func selectQueue() {
        showCompleted = false
        switchPage()
    }

    @objc private func selectCompleted() {
        showCompleted = true
        showMusicControls(for: nil)
        switchPage()
    }

    private func switchPage() {
        for (index, row) in sidebarSelection.enumerated() {
            row.fillColor = index == (showCompleted ? 1 : 0)
                ? NSColor.controlAccentColor.withAlphaComponent(0.24) : .clear
        }
        title.stringValue = localized(showCompleted ? "Completed" : "Queue")
        refresh()
        window.makeFirstResponder(table)
    }

    @objc private func startAll() {
        for item in downloads where !item.done && !item.pendingRemoval && (item.process == nil || item.music && item.startedMode == nil) {
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
        if !item.inspectingMusic, let process = item.process, process.isRunning {
            for peer in downloads where peer !== item && peer.process === process {
                peer.musicBatchInterrupted = true
            }
            process.terminate()
        }
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
        if action == "check-music" || action == "reinstall-music" {
            let task = musicPreview.run(link: "", folder: folder, source: nil, format: "FLAC",
                                        maintenance: action == "check-music" ? "check" : "reinstall",
                                        status: { _ in }, event: { _, _ in }, finish: { _, message in
                reply(message.isEmpty ? localized("Tool operation failed.") : message)
            })
            if task == nil { reply(localized("Tool operation failed.")) }
            return
        }
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

    private func removeSelectedRows() {
        let indexes = table.selectedRowIndexes
        guard let first = indexes.first else { return }
        let selected = indexes.compactMap { displayedRows.indices.contains($0) ? displayedRows[$0] : nil }
        for item in selected where !item.pendingRemoval { clear(item) }
        refresh(selectNear: first)
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
        var remaining = available
        var musicActive = downloads.contains { $0.music && $0.process != nil }
        for item in downloads where item.scheduled && !item.pendingRemoval && item.process == nil {
            guard remaining > 0 else { break }
            if item.music && musicActive { continue }
            let source = explicitMusicSource(for: item)
            if remaining >= 2, item.musicTrackJSON != nil,
               let peer = downloads.first(where: {
                   $0 !== item && $0.scheduled && !$0.pendingRemoval && $0.process == nil
                       && $0.musicTrackJSON != nil && explicitMusicSource(for: $0) == source
                       && downloadFolder(for: $0, audio: true) == downloadFolder(for: item, audio: true)
               }), beginMusicPair(item, peer, source: source) {
                musicActive = true
                remaining -= 2
                continue
            }
            begin(item)
            if item.music { musicActive = item.process != nil }
            if item.process != nil { remaining -= 1 }
        }
        refresh()
    }

    private func begin(_ item: Download) {
        let selectedMode = item.startedMode ?? (item.music ? item.musicFormat : regularFormat)
        item.startedMode = selectedMode
        if item.music {
            beginMusic(item, format: selectedMode)
            return
        }
        let link = URL(string: item.url)
        let artlist = isArtlistLink(item.url)
        let path = link?.path ?? ""
        let audio = artlist ? !path.hasPrefix("/stock-footage/clip/") :
            ["MP3", "M4A"].contains(selectedMode) && !item.url.contains("instagram.com/")
        let destination = downloadFolder(for: item, audio: audio)
        let engineMode = selectedMode == "best" && !engineUsesModeKeys ? "Лучшее видео" : selectedMode
        var request: [String: Any] = ["url": item.url, "mode": engineMode, "folder": destination.path,
                                      "temporary": temp.appendingPathComponent(item.id.uuidString).path]
        if let index = item.index { request["index"] = index }
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        item.scheduled = false
        item.status = "Connecting…"
        item.lastError = ""
        var needsYouTubeSession = false
        item.process = process(["download", String(decoding: data, as: UTF8.self)], event: { [weak self, weak item] message in
            guard let self = self, let item = item else { return }
            switch message["event"] as? String {
            case "file":
                if let path = message["path"] as? String {
                    let file = URL(fileURLWithPath: path)
                    if !item.files.contains(file) { item.files.append(file) }
                }
            case "youtube_session_required":
                needsYouTubeSession = true
            case "youtube_session":
                if item.status != "Paused", let label = message["status"] as? String {
                    self.setFooterStatus(localized(label))
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
                    self.setFooterStatus(localized(label), error: true)
                }
            default: return
            }
            self.refreshStatus(for: item)
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
                let safariAccessDenied = code != 0 && self.showSafariAccessIfNeeded(item.lastError)
                if code != 0, !safariAccessDenied, !item.didRetryYouTubeSession,
                   needsYouTubeSession || self.isYouTubeSessionError(item.lastError, for: item.url),
                   self.requestYouTubeSession(for: item.url) {
                    self.schedule(item)
                    item.didRetryYouTubeSession = true
                    self.dispatch()
                    return
                }
                if code != 0 && !safariAccessDenied && self.retryIfTransient(item) {
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

    private func downloadFolder(for item: Download, audio: Bool) -> URL {
        let folder = outputFolder(for: audio ? "audio_folder" : "video_folder")
        guard let title = item.collectionTitle else { return folder }
        let invalidCharacters = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let name = title.components(separatedBy: invalidCharacters).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let shortened = String(decoding: name.utf8.prefix(180), as: UTF8.self)
        return folder.appendingPathComponent(shortened.isEmpty ? localized(item.musicTrackJSON != nil && !item.numberedPlaylist ? "Album" : "Playlist") : shortened, isDirectory: true)
    }

    private func showVerificationResult(_ data: Data) {
        guard let success = try? JSONDecoder().decode(Bool.self, from: data) else { return }
        setFooterStatus(localized(success ? "Verification successful." : "Verification failed."), duration: 5)
    }

    private func beginMusic(_ item: Download, format: String) {
        item.scheduled = false
        item.status = "Connecting…"
        item.progress = nil
        item.lastError = ""
        let source = explicitMusicSource(for: item)
        appendLog("Music · " + item.title + " · " + (source ?? localized("Automatic")) + " · " + format)
        item.process = musicPreview.run(link: item.url, folder: downloadFolder(for: item, audio: true),
                                        source: source, format: format, trackJSON: item.musicTrackJSON,
                                        status: { [weak self, weak item] message in
            guard let self = self, let item = item, item.status != "Paused" else { return }
            self.setFooterStatus(message)
            item.status = "Downloading"
            self.refresh()
        }, log: { [weak self] message in
            self?.appendLog("Music · " + message)
        }, event: { [weak self, weak item] kind, data in
            if kind == "YTDL_VERIFICATION_RESULT" { self?.showVerificationResult(data) }
            if kind == "YTDL_PROGRESS", let item = item, item.status != "Paused",
               let percent = try? JSONDecoder().decode(Double.self, from: data) {
                item.status = "Downloading"
                item.progress = percent
                self?.refreshStatus(for: item)
            }
            if kind == "YTDL_FILE", let path = try? JSONDecoder().decode(String.self, from: data) {
                item?.files = [URL(fileURLWithPath: path)]
            }
        }, finish: { [weak self, weak item] code, message in
            guard let self = self, let item = item else { return }
            self.finishMusic(item, code: code, message: message)
            self.dispatch()
            if item.done { self.finishQueueIfNeeded(last: item) }
        })
        if item.process == nil {
            item.progress = nil
            item.status = "Error"
            unlockMusicOptions(item)
            setFooterStatus("Could not launch the music engine.", error: true)
        } else {
            notify("Download started", body: item.title, setting: "notify_started")
        }
    }

    private func beginMusicPair(_ first: Download, _ second: Download, source: String?) -> Bool {
        let items = [first, second]
        let entries = items.map { ["url": $0.url, "track": $0.musicTrackJSON ?? "",
                                   "format": $0.startedMode ?? $0.musicFormat] }
        guard let payload = try? JSONSerialization.data(withJSONObject: entries) else { return false }
        var results: [Int: [String: String]] = [:]
        let process = musicPreview.run(link: first.url, folder: downloadFolder(for: first, audio: true),
                                       source: source, format: first.startedMode ?? first.musicFormat,
                                       batch: String(decoding: payload, as: UTF8.self),
                                       status: { [weak self] message in self?.setFooterStatus(message) },
                                       log: { [weak self] message in self?.appendLog("Music · " + message) },
                                       event: { [weak self] kind, data in
            guard let self = self else { return }
            if kind == "YTDL_VERIFICATION_RESULT" {
                self.showVerificationResult(data)
                return
            }
            guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  fields.count == 2, let index = fields[0] as? Int, items.indices.contains(index) else { return }
            let item = items[index]
            if kind == "YTDL_BATCH_PROGRESS", item.status != "Paused", let progress = fields[1] as? Double {
                item.progress = progress
                item.status = "Downloading"
                self.refreshStatus(for: item)
            } else if kind == "YTDL_BATCH_RESULT", let result = fields[1] as? [String: String] {
                results[index] = result
            }
        }, finish: { [weak self] code, message in
            guard let self = self else { return }
            for (index, item) in items.enumerated() {
                let result = results[index]
                if let file = result?["file"] { item.files = [URL(fileURLWithPath: file)] }
                let interrupted = item.musicBatchInterrupted
                item.musicBatchInterrupted = false
                if interrupted && item.status != "Paused" && result == nil && !item.pendingRemoval {
                    item.process = nil
                    item.progress = nil
                    self.unlockMusicOptions(item)
                    item.status = "Waiting"
                    item.scheduled = true
                } else {
                    self.finishMusic(item, code: result?["file"] != nil ? 0 : (code == 0 ? 1 : code),
                                     message: result?["error"] ?? message)
                }
            }
            self.dispatch()
            if let last = items.last(where: { $0.done }) { self.finishQueueIfNeeded(last: last) }
        })
        guard let process = process else { return false }
        for item in items {
            item.process = process
            item.startedMode = item.startedMode ?? item.musicFormat
            item.scheduled = false
            item.status = "Connecting…"
            item.progress = nil
            item.lastError = ""
            notify("Download started", body: item.title, setting: "notify_started")
        }
        return true
    }

    private func finishMusic(_ item: Download, code: Int32, message: String) {
        item.process = nil
        item.progress = nil
        if item.pendingRemoval {
            delete(item, trashFile: false)
        } else if item.status == "Paused" && item.files.isEmpty {
            unlockMusicOptions(item)
        } else {
            item.done = code == 0 && !item.files.isEmpty
            item.status = item.done ? "Done" : "Error"
            item.lastError = item.done ? "" : message
            appendLog("Music · " + item.status + " · " + item.title)
            if !item.done {
                unlockMusicOptions(item)
                setFooterStatus(item.lastError, error: true)
            }
            notify(item.done ? "Download completed" : "Download failed", body: item.title,
                   setting: item.done ? "notify_completed" : "notify_failed", enabledByDefault: true)
        }
    }

    private func unlockMusicOptions(_ item: Download) {
        item.startedMode = nil
        if musicSelection === item {
            quality.isEnabled = true
            musicSource.isEnabled = true
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

    private func refresh(replacing previousID: UUID? = nil, with replacementID: UUID? = nil,
                         selectNear deletedIndex: Int? = nil) {
        let completed = downloads.filter { $0.done }.count
        queueCount.stringValue = String(downloads.filter { !$0.done && !$0.pendingRemoval }.count)
        completedCount.stringValue = String(completed)
        let visible = rows
        let count = visible.count
        visibleCount.stringValue = itemCount(count)
        empty.isHidden = showCompleted || count > 0
        let ids = visible.map(\.id)
        displayedRows = visible
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { index -> UUID? in
            guard displayedRowIDs.indices.contains(index) else { return nil }
            let id = displayedRowIDs[index]
            return id == previousID ? replacementID : id
        })
        var selection = IndexSet(ids.indices.filter { selectedIDs.contains(ids[$0]) })
        if selection.isEmpty, let deletedIndex = deletedIndex, !ids.isEmpty {
            selection.insert(min(deletedIndex, ids.count - 1))
        }
        refreshingRows = true
        if ids == displayedRowIDs {
            table.reloadData(forRowIndexes: IndexSet(integersIn: ids.indices),
                             columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        } else {
            displayedRowIDs = ids
            table.reloadData()
        }
        if table.selectedRowIndexes != selection {
            table.selectRowIndexes(selection, byExtendingSelection: false)
        }
        if deletedIndex != nil, let row = selection.first { table.scrollRowToVisible(row) }
        refreshingRows = false
        updateMusicControlsForSelection()
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
        if item.music {
            schedule(item)
            dispatch()
        } else {
            begin(item)
            refresh()
        }
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
            setFooterStatus(error.localizedDescription, error: true)
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

    private static func thumbnailURL(_ value: Any?) -> URL? {
        guard let value = value as? String, let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }

    private func requestThumbnail(_ url: URL) {
        guard !thumbnailFailures.contains(url), thumbnailRequests.insert(url).inserted else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let bitmap = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap {
                CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 168
                ] as CFDictionary)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.thumbnailRequests.remove(url)
                guard let bitmap = bitmap else {
                    self.thumbnailFailures.insert(url)
                    return
                }
                let image = NSImage(cgImage: bitmap, size: .zero)
                self.thumbnails.setObject(image, forKey: url as NSURL)
                let visible = self.table.rows(in: self.table.visibleRect)
                let column = self.table.column(withIdentifier: NSUserInterfaceItemIdentifier("title"))
                guard visible.location != NSNotFound, column >= 0 else { return }
                for index in visible.location..<(visible.location + visible.length) {
                    if let cell = self.table.view(atColumn: column, row: index, makeIfNecessary: false) as? QueueTitleCell,
                       cell.thumbnailURL == url {
                        cell.thumbnail.image = image
                    }
                }
            }
        }.resume()
    }

    private func refreshStatus(for item: Download) {
        let schedule = dirtyStatusRows.isEmpty
        dirtyStatusRows.insert(item.id)
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let dirty = self.dirtyStatusRows
            self.dirtyStatusRows.removeAll(keepingCapacity: true)
            let visible = self.table.rows(in: self.table.visibleRect)
            guard visible.location != NSNotFound else { return }
            let indexes = IndexSet((visible.location..<(visible.location + visible.length)).filter {
                self.displayedRowIDs.indices.contains($0) && dirty.contains(self.displayedRowIDs[$0])
            })
            let column = self.table.column(withIdentifier: NSUserInterfaceItemIdentifier("status"))
            if !indexes.isEmpty, column >= 0 {
                self.table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column))
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard displayedRows.indices.contains(row), let column = column else { return nil }
        let item = displayedRows[row]
        switch column.identifier.rawValue {
        case "title":
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? QueueTitleCell
                ?? QueueTitleCell(identifier: column.identifier)
            let prefix = item.index.map { String(format: "%02d · ", $0) } ?? ""
            cell.caption.stringValue = prefix + item.title
            cell.thumbnailURL = item.thumbnailURL
            cell.thumbnail.image = NSImage(named: NSImage.multipleDocumentsName)
            if let url = item.thumbnailURL {
                if let image = thumbnails.object(forKey: url as NSURL) {
                    cell.thumbnail.image = image
                } else {
                    requestThumbnail(url)
                }
            }
            return cell
        case "format":
            let selectedMode = item.startedMode ?? (item.music ? item.musicFormat : regularFormat)
            let format = item.files.last?.pathExtension.uppercased() ??
                (item.url.contains("instagram.com/") ? "Media" : (item.music ? String(selectedMode.prefix(while: { $0 != "-" })) :
                    (["MP3", "M4A"].contains(selectedMode) ? selectedMode : "MP4")))
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
            if item.done {
                let check = NSTextField(labelWithString: "✓")
                check.font = .systemFont(ofSize: 15, weight: .semibold)
                check.textColor = .systemGreen
                check.toolTip = localized("Done")
                check.setAccessibilityLabel(localized("Done"))
                return centeredCell(check)
            }
            let label = NSTextField(labelWithString: localized(item.status))
            label.textColor = item.status == "Error" ? .systemRed : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = label.stringValue
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
                appearance = ("📁", "folder", NSImage.folderName)
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
