import AppKit

/// Fenster- und Fokus-Logs ([WIN], [FOCUS]) wie Spike eselsohr-drop. Nur Lesen, keine Seiteneffekte.
@MainActor
final class Diagnostics {
    private let presenter: BoardPresenter

    init(presenter: BoardPresenter) {
        self.presenter = presenter
    }

    func logWindows(_ label: String) {
        logWindow(label, presenter.ear, name: "ear")
        if let b = presenter.board { logWindow(label, b, name: "board") }
    }

    private func logWindow(_ label: String, _ p: NSPanel, name: String) {
        let s = p.screen
        Log.line("[WIN]", "\(label) \(name) #\(p.windowNumber) level=\(p.level.rawValue) "
            + "behavior=0x\(String(p.collectionBehavior.rawValue, radix: 16)) onActiveSpace=\(p.isOnActiveSpace) "
            + "visible=\(p.isVisible) key=\(p.isKeyWindow) frame=\(fmt(p.frame)) "
            + "screen.frame=\(s.map { fmt($0.frame) } ?? "nil") visibleFrame=\(s.map { fmt($0.visibleFrame) } ?? "nil")")
    }

    func logFocus(_ label: String) {
        let front = NSWorkspace.shared.frontmostApplication
        Log.line("[FOCUS]", "\(label) frontmost=\(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "?")) "
            + "NSApp.isActive=\(NSApp.isActive) keyWindow=\(windowName(NSApp.keyWindow)) "
            + "earKey=\(presenter.ear.isKeyWindow) boardKey=\(presenter.board?.isKeyWindow ?? false)")
    }

    private func windowName(_ w: NSWindow?) -> String {
        guard let w = w else { return "nil" }
        if w === presenter.ear { return presenter.isOpen && presenter.handoff == .grow ? "ear(grown)" : "ear" }
        if w === presenter.board { return "board" }
        return "andere"
    }

    func logLevels() {
        Log.line("[WIN]", "Level-Referenz floating=\(NSWindow.Level.floating.rawValue) "
            + "mainMenu=\(NSWindow.Level.mainMenu.rawValue) statusBar=\(NSWindow.Level.statusBar.rawValue) "
            + "popUpMenu=\(NSWindow.Level.popUpMenu.rawValue) screenSaver=\(NSWindow.Level.screenSaver.rawValue) "
            + "cgDraggingWindow=\(CGWindowLevelForKey(.draggingWindow))")
    }
}
