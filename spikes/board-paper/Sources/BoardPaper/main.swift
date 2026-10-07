import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: BoardPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bildschirm unter dem Mauszeiger (NSScreen.main waere der Bildschirm des Key-Fensters, Report 02).
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.screens.first else {
            FileHandle.standardError.write(Data("Kein Bildschirm gefunden.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        let scale = screen.backingScaleFactor

        var images: [PlacedImage] = []
        if let folder = Self.imagesArgument() {
            images = ImageLibrary.load(folder: folder, scale: scale)
            if images.isEmpty {
                FileHandle.standardError.write(Data("Keine lesbaren Bilder in \(folder), nutze Platzhalter.\n".utf8))
            }
        }
        if images.isEmpty { images = ImageLibrary.placeholders(scale: scale) }

        let panel = BoardPanel(screen: screen)
        let view = BoardView(frame: NSRect(origin: .zero, size: screen.frame.size),
                             scale: scale,
                             noiseTile: ImageLibrary.loadNoiseTile(),
                             images: images)
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()        // nie NSApp.activate / makeKeyAndOrderFront (Report 02)
        // ⚠️ VERIFIZIEREN: Ob ein nicht aktivierendes Panel einer inaktiven App per makeKey() Tastaturereignisse
        // (Esc, D, N) erhaelt, ist nicht belegt. Falls nicht: einmal ins Papier klicken (Klick macht das Panel key).
        panel.makeKey()
        panel.makeFirstResponder(view)
        self.panel = panel
    }

    /// Wert nach `--images`, falls vorhanden.
    private static func imagesArgument() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--images"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
