import AppKit
import QuartzCore

/// Alle visuellen Konstanten. Werte aus Spike board-paper (PaperStyle), ergänzt um Platzhalter und Eselsohr.
/// Layout-Zahlen (Grid, Bildkante, Rotation) stehen in DropboardCore.LayoutMetrics.
enum PaperStyle {
    // Farben (sRGB, 0xRRGGBB)
    static let paperHex: UInt32 = 0xF4F0E8      // warmes Off-White, kein reines Weiß
    static let graphiteHex: UInt32 = 0x2E2E2C   // Graphit statt Schwarz (Schatten, Abdunklung, Linien)

    // Noise-Ebene
    static let noiseOpacity: Float = 0.06       // bei 100 % gerade sichtbar

    // Abgedunkeltes Papier während eines Drags (Briefing „Look“)
    static let dimOpacity: Float = 0.35         // Graphit über dem Papier, unter den Bildern

    // Harter Schatten (kein Blur)
    static let shadowRadius: CGFloat = 0
    static let shadowOffset = CGSize(width: 1.5, height: -1.5)  // pt; nach unten rechts (y-up, nicht geflippt)
    static let shadowOpacity: Float = 0.25

    // Platzhalter bis ein File-Promise erfüllt ist: leeres Papier-Rechteck, etwas heller als das Board
    static let placeholderHex: UInt32 = 0xFBF9F4

    // Eselsohr: gleiches Papier (Rückseite etwas dunkler), gedämpft, ohne Schatten
    static let earBackHex: UInt32 = 0xE9E3D7
    static let earOpacity: Float = 0.9
    static let earEdgeAlpha: CGFloat = 0.14     // Haarlinie an den beiden Papierkanten
    static let earFoldAlpha: CGFloat = 0.28     // Falzlinie (Diagonale)

    static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

/// Führt Layer-Änderungen ohne implizite Animationen aus (Report 03, Abschnitt 3, Weg 1). Aus Spike board-paper.
func withoutImplicitAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}
