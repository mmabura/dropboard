import AppKit

enum HandoffMode: String {
    case twoPanels = "two-panels"   // Report 02, Variante A (Default)
    case grow                       // Report 02, Variante B (ohne Animation, ein setFrame)
}

/// Alle Spike-Konstanten an einer Stelle.
enum SpikeConfig {
    static let expandDelay: TimeInterval = 0.3        // E10
    static let earSize: CGFloat = 40
    static let earInsetRight: CGFloat = 12
    static let earTopGap: CGFloat = 2
    static let pollInterval: TimeInterval = 0.02      // Watchdog während Board offen
    static let releaseGrace: TimeInterval = 0.5       // Maustaste los, aber kein Drop → nach 500 ms schließen
    static let noEnterWarnAfter: TimeInterval = 1.0
    static let updateLogInterval: TimeInterval = 0.25 // draggingUpdated nach Expand gedrosselt loggen
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let mode: HandoffMode
    private let rejectDrops: Bool
    private let saver: DropSaver
    private var ear: SpikePanel!
    private var earView: DropView!
    private var board: SpikePanel?
    private var earFrame = NSRect.zero
    private var keyMonitor: Any?

    // Zustand Drag-Session / Expand
    private var sessionSeq = Int.min
    private var dropReceived = false
    private var expanded = false
    private var expandAt: TimeInterval = 0
    private var mouseAtExpand = NSPoint.zero
    private var boardReached = false
    private var mouseMovedLogged = false
    private var noEnterWarned = false
    private var releaseSeenAt: TimeInterval?
    private var updateLoggedAfterExpand = Set<String>()
    private var pollTimer: Timer?

    init(mode: HandoffMode, rejectDrops: Bool) {
        self.mode = mode
        self.rejectDrops = rejectDrops
        self.saver = DropSaver()
        super.init()
    }

    // MARK: Start

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = AppController.screenUnderMouse()
        let vf = screen.visibleFrame
        earFrame = NSRect(x: vf.maxX - SpikeConfig.earInsetRight - SpikeConfig.earSize,
                          y: vf.maxY - SpikeConfig.earTopGap - SpikeConfig.earSize,
                          width: SpikeConfig.earSize, height: SpikeConfig.earSize)
        ear = SpikePanel(spikeFrame: earFrame)
        earView = makeDropView(role: .ear, size: earFrame.size)
        ear.contentView = earView
        ear.orderFrontRegardless()   // nie makeKeyAndOrderFront / NSApp.activate (Report 02)

        if mode == .twoPanels {
            // Vorab erzeugt und versteckt; Expand kostet dann nur orderFrontRegardless.
            // ⚠️ VERIFIZIEREN: Report 02 ⚠️13 – ob Vorab-Erzeugung die Expand-Latenz wirklich senkt.
            let b = SpikePanel(spikeFrame: screen.frame)
            let v = makeDropView(role: .board, size: screen.frame.size)
            v.showsBoard = true
            b.contentView = v
            b.orderOut(nil)
            board = b
        }

        logStart(screen)
        logWindows("Start")
        logFocus("Start")

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                               name: NSWindow.didChangeScreenNotification, object: ear)

        // Esc beendet – funktioniert nur, wenn ein Panel key ist (z. B. nach Klick aufs Eselsohr).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Log.line("[WIN]", "Esc – Spike beendet")
                exit(0)
            }
            return event
        }
    }

    private func makeDropView(role: DropView.Role, size: NSSize) -> DropView {
        let v = DropView(frame: NSRect(origin: .zero, size: size))
        v.role = role
        v.controller = self
        v.boardLabel = "Dropboard-Spike · Board · handoff=\(mode.rawValue)"
        v.registerForDraggedTypes(DropSaver.acceptedTypes)
        return v
    }

    /// Bildschirm unter dem Mauszeiger (Report 02, Abschnitt 5), Fallback NSScreen.main.
    private static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Diagnose-Logs

    private func logStart(_ screen: NSScreen) {
        let pi = ProcessInfo.processInfo
        Log.line("[WIN]", "Start eselsohr-drop handoff=\(mode.rawValue) rejectDrops=\(rejectDrops) "
            + "macOS=\(pi.operatingSystemVersionString) pid=\(pi.processIdentifier) "
            + "activationPolicy=\(NSApp.activationPolicy().rawValue) log=\(Log.filePath)")
        Log.line("[WIN]", "Level-Referenz floating=\(NSWindow.Level.floating.rawValue) "
            + "mainMenu=\(NSWindow.Level.mainMenu.rawValue) statusBar=\(NSWindow.Level.statusBar.rawValue) "
            + "popUpMenu=\(NSWindow.Level.popUpMenu.rawValue) screenSaver=\(NSWindow.Level.screenSaver.rawValue) "
            + "cgDraggingWindow=\(CGWindowLevelForKey(.draggingWindow))")
        Log.line("[WIN]", "Bildschirme=\(NSScreen.screens.count) screensHaveSeparateSpaces=\(NSScreen.screensHaveSeparateSpaces) "
            + "eselsohrScreen frame=\(fmt(screen.frame)) visibleFrame=\(fmt(screen.visibleFrame)) "
            + "safeAreaTop=\(screen.safeAreaInsets.top)")
        Log.line("[DROP]", "Zielordner=\(saver.incomingRoot.path) registriert=[\(DropSaver.acceptedTypes.map { $0.rawValue }.joined(separator: ","))]")
    }

    private func logWindows(_ label: String) {
        logWindow(label, ear, name: "ear")
        if let b = board { logWindow(label, b, name: "board") }
    }

    private func logWindow(_ label: String, _ p: NSPanel, name: String) {
        let s = p.screen
        Log.line("[WIN]", "\(label) \(name) #\(p.windowNumber) level=\(p.level.rawValue) "
            + "behavior=0x\(String(p.collectionBehavior.rawValue, radix: 16)) onActiveSpace=\(p.isOnActiveSpace) "
            + "visible=\(p.isVisible) key=\(p.isKeyWindow) frame=\(fmt(p.frame)) "
            + "screen.frame=\(s.map { fmt($0.frame) } ?? "nil") visibleFrame=\(s.map { fmt($0.visibleFrame) } ?? "nil")")
    }

    private func logFocus(_ label: String) {
        let front = NSWorkspace.shared.frontmostApplication
        Log.line("[FOCUS]", "\(label) frontmost=\(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "?")) "
            + "NSApp.isActive=\(NSApp.isActive) keyWindow=\(windowName(NSApp.keyWindow)) "
            + "earKey=\(ear.isKeyWindow) boardKey=\(board?.isKeyWindow ?? false)")
    }

    private func windowName(_ w: NSWindow?) -> String {
        guard let w = w else { return "nil" }
        if w === ear { return "ear" }
        if w === board { return "board" }
        return "andere"
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        Log.line("[WIN]", "activeSpaceDidChange")
        logWindows("Space-Wechsel")
        logFocus("Space-Wechsel")
        perform(#selector(logWindowsLate), with: nil, afterDelay: 0.5, inModes: [.common])
    }

    @objc private func screenChanged(_ note: Notification) {
        Log.line("[WIN]", "\(note.name.rawValue) Bildschirme=\(NSScreen.screens.count)")
        logWindows("Bildschirm-Wechsel")
        perform(#selector(logWindowsLate), with: nil, afterDelay: 0.5, inModes: [.common])
    }

    @objc private func logWindowsLate() { logWindows("+500ms") }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        Log.line("[FOCUS]", "App aktiviert: \(app?.bundleIdentifier ?? "nil") (\(app?.localizedName ?? "?"))"
            + (own ? " !!! SPIKE SELBST AKTIVIERT" : ""))
    }

    @objc private func logFocusAfterDrop() { logFocus("500ms nach Drop") }

    // MARK: Klick

    func clicked(_ view: DropView) {
        Log.line("[WIN]", "Klick auf \(name(of: view)) ohne Drag → Ansichtsmodus würde öffnen")
        logFocus("nach Klick")
    }

    // MARK: Drag-Ereignisse (von DropView)

    private func name(of view: DropView) -> String {
        if view.role == .board { return "board" }
        return (expanded && mode == .grow) ? "ear(grown)" : "ear"
    }

    private func isBoardTarget(_ view: DropView) -> Bool { view.role == .board || (expanded && mode == .grow) }

    private func sinceExpand() -> String { expanded ? " +\(Log.ms(since: expandAt))ms nach Expand" : "" }

    private func screenPoint(_ view: DropView, _ info: NSDraggingInfo) -> NSPoint {
        guard let w = view.window else { return info.draggingLocation }
        return w.convertPoint(toScreen: info.draggingLocation)
    }

    private func mouseMovedSinceExpand() -> Bool { NSEvent.mouseLocation != mouseAtExpand }

    func dragEntered(_ view: DropView, _ info: NSDraggingInfo) -> NSDragOperation {
        let win = name(of: view)
        let seq = info.draggingSequenceNumber
        if view.role == .ear && !expanded && seq != sessionSeq {
            sessionSeq = seq
            dropReceived = false
            Log.line("[HANDOFF]", "neue Drag-Session seq=\(seq)")
        } else if seq != sessionSeq {
            Log.line("[HANDOFF]", "draggingEntered win=\(win) mit abweichender seq=\(seq) (Session \(sessionSeq))")
        }
        let pos = fmt(screenPoint(view, info))
        if expanded {
            if isBoardTarget(view) { boardReached = true }
            Log.line("[HANDOFF]", "draggingEntered win=\(win)\(sinceExpand()) mausBewegtSeitExpand=\(mouseMovedSinceExpand()) "
                + "pos=\(pos) maus=\(fmt(NSEvent.mouseLocation))")
        } else {
            Log.line("[HANDOFF]", "draggingEntered win=\(win) pos=\(pos) → Expand-Timer \(Int(SpikeConfig.expandDelay * 1000))ms")
            scheduleExpand()
        }
        saver.dumpPasteboard(info, phase: "draggingEntered", window: win)
        return .copy
    }

    func dragUpdated(_ view: DropView, _ info: NSDraggingInfo) -> NSDragOperation {
        view.updateCount += 1
        guard expanded else { return .copy }
        let win = name(of: view)
        if isBoardTarget(view) { boardReached = true }
        let first = !updateLoggedAfterExpand.contains(win)
        if first || Log.now - view.lastUpdateLog >= SpikeConfig.updateLogInterval {
            updateLoggedAfterExpand.insert(win)
            view.lastUpdateLog = Log.now
            Log.line("[HANDOFF]", "draggingUpdated\(first ? " (erstes nach Expand)" : "") win=\(win)\(sinceExpand()) "
                + "mausBewegtSeitExpand=\(mouseMovedSinceExpand()) pos=\(fmt(screenPoint(view, info))) n=\(view.updateCount)")
        }
        return .copy
    }

    func dragExited(_ view: DropView, _ info: NSDraggingInfo?) {
        let win = name(of: view)
        let mouse = NSEvent.mouseLocation
        guard expanded else {
            cancelExpand()
            Log.line("[HANDOFF]", "draggingExited win=\(win) vor Expand → Expand abgebrochen updates=\(view.updateCount) maus=\(fmt(mouse))")
            view.updateCount = 0
            return
        }
        Log.line("[HANDOFF]", "draggingExited win=\(win)\(sinceExpand()) updates=\(view.updateCount) maus=\(fmt(mouse))")
        guard isBoardTarget(view) else { return }   // Eselsohr-Exit nach Expand (two-panels) ist erwartet
        if let frame = view.window?.frame, frame.contains(mouse) {
            Log.line("[HANDOFF]", "Cursor noch im Board-Frame (Esc/Abbruch?) → warte auf draggingEnded bzw. Maustaste")
        } else {
            collapse(reason: "Maus hat Board verlassen (draggingExited)")
        }
    }

    func prepareDrop(_ view: DropView, _ info: NSDraggingInfo) -> Bool {
        dropReceived = true
        cancelExpand()
        Log.line("[DROP]", "prepareForDragOperation win=\(name(of: view))\(sinceExpand())")
        return true
    }

    func performDrop(_ view: DropView, _ info: NSDraggingInfo) -> Bool {
        dropReceived = true
        cancelExpand()
        let win = name(of: view)
        let kind: String
        if isBoardTarget(view) {
            kind = "Board-Drop"
        } else if expanded {
            kind = "Drop auf Eselsohr trotz offenem Board (Handoff fehlgeschlagen)"
        } else {
            kind = "Quick-Drop"
        }
        Log.line("[DROP]", "performDragOperation win=\(win) art=\(kind) dropPos=\(fmt(screenPoint(view, info))) "
            + "cursor=\(fmt(NSEvent.mouseLocation))\(sinceExpand())")
        if expanded {
            Log.line("[HANDOFF]", "performDragOperation auf win=\(win)\(sinceExpand()) boardErreicht=\(boardReached)")
        }
        saver.dumpPasteboard(info, phase: "performDragOperation", window: win)
        var ok = false
        if rejectDrops {
            Log.line("[DROP]", "--reject-drops aktiv → performDragOperation gibt false zurück (Report 01 T4b)")
        } else {
            ok = saver.save(info)
        }
        Log.line("[DROP]", "performDragOperation Rückgabe=\(ok)")
        logFocus("nach Drop")
        perform(#selector(logFocusAfterDrop), with: nil, afterDelay: 0.5, inModes: [.common])
        if expanded {
            // Board erst nach Rückkehr aus performDragOperation schließen, nicht mitten im Drop.
            perform(#selector(collapseAfterDrop), with: nil, afterDelay: 0, inModes: [.common])
        }
        return ok
    }

    func concludeDrop(_ view: DropView, _ info: NSDraggingInfo?) {
        Log.line("[DROP]", "concludeDragOperation win=\(name(of: view))\(sinceExpand())")
        saver.probeSources("concludeDragOperation")
    }

    func dragEnded(_ view: DropView, _ info: NSDraggingInfo) {
        Log.line("[HANDOFF]", "draggingEnded win=\(name(of: view)) dropEmpfangen=\(dropReceived)\(sinceExpand()) "
            + "cursor=\(fmt(NSEvent.mouseLocation))")
        view.updateCount = 0
        if expanded && !dropReceived {
            collapse(reason: "draggingEnded ohne Drop")
        }
    }

    // MARK: Expand / Collapse

    private func scheduleExpand() {
        cancelExpand()
        perform(#selector(expandFired), with: nil, afterDelay: SpikeConfig.expandDelay, inModes: [.common])
    }

    private func cancelExpand() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(expandFired), object: nil)
    }

    @objc private func expandFired() {
        guard !expanded, !dropReceived else { return }
        logFocus("vor Expand")
        let screen = ear.screen ?? AppController.screenUnderMouse()
        expanded = true
        boardReached = false
        mouseMovedLogged = false
        noEnterWarned = false
        releaseSeenAt = nil
        updateLoggedAfterExpand.removeAll()
        mouseAtExpand = NSEvent.mouseLocation
        expandAt = Log.now
        switch mode {
        case .twoPanels:
            board?.setFrame(screen.frame, display: false)
            board?.orderFrontRegardless()
        case .grow:
            earView.showsBoard = true
            ear.setFrame(screen.frame, display: true)
        }
        Log.line("[HANDOFF]", "Expand ausgelöst mode=\(mode.rawValue) maus=\(fmt(mouseAtExpand)) "
            + "dauer(orderFront/setFrame)=\(Log.ms(since: expandAt))ms mausTaste=\(NSEvent.pressedMouseButtons)")
        logWindows("nach Expand")
        startPolling()
    }

    @objc private func collapseAfterDrop() { collapse(reason: "nach Drop") }

    private func collapse(reason: String) {
        guard expanded else { return }
        let t = Log.now
        expanded = false
        stopPolling()
        switch mode {
        case .twoPanels:
            board?.orderOut(nil)
        case .grow:
            ear.setFrame(earFrame, display: true)
            earView.showsBoard = false
        }
        Log.line("[HANDOFF]", "Board geschlossen grund=\(reason) offen=\(String(format: "%.1f", (t - expandAt) * 1000))ms "
            + "dauer(orderOut/setFrame)=\(Log.ms(since: t))ms")
        logWindows("nach Schließen")
    }

    // MARK: Watchdog (Board offen)

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: SpikeConfig.pollInterval, target: self,
                          selector: #selector(pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    @objc private func pollTick() {
        guard expanded else { stopPolling(); return }
        let elapsed = Log.now - expandAt
        // ⚠️ VERIFIZIEREN: NSEvent.mouseLocation / pressedMouseButtons liefern während eines fremden Drags aktuelle Werte.
        if !mouseMovedLogged && mouseMovedSinceExpand() {
            mouseMovedLogged = true
            Log.line("[HANDOFF]", "erste Mausbewegung nach Expand +\(Log.ms(since: expandAt))ms boardErreicht=\(boardReached) "
                + "maus=\(fmt(NSEvent.mouseLocation))")
        }
        if !boardReached && !noEnterWarned && elapsed >= SpikeConfig.noEnterWarnAfter {
            noEnterWarned = true
            Log.line("[HANDOFF]", "WARNUNG: \(Int(SpikeConfig.noEnterWarnAfter * 1000))ms nach Expand kein Drag-Ereignis "
                + "auf dem Board (mausBewegtSeitExpand=\(mouseMovedSinceExpand()))")
        }
        guard !dropReceived else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if let released = releaseSeenAt {
                if Log.now - released >= SpikeConfig.releaseGrace {
                    collapse(reason: "Maustaste losgelassen, kein Drop innerhalb \(Int(SpikeConfig.releaseGrace * 1000))ms")
                }
            } else {
                releaseSeenAt = Log.now
                Log.line("[HANDOFF]", "Maustaste losgelassen (Polling)\(sinceExpand()) cursor=\(fmt(NSEvent.mouseLocation))")
            }
        } else {
            releaseSeenAt = nil
        }
    }
}
