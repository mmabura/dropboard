import AppKit
import QuartzCore

/// Alle visuellen Konstanten. Werte aus Spike board-paper (PaperStyle), ergänzt um Platzhalter und Eselsohr.
/// Layout-Zahlen (Grid, Bildkante, Rotation) stehen in DropboardCore.LayoutMetrics.
enum PaperStyle {
    // Farben (sRGB, 0xRRGGBB)
    static let paperHex: UInt32 = 0xF4F0E8      // warmes Off-White, kein reines Weiß
    static let graphiteHex: UInt32 = 0x3A2E22   // warmes Graphit/Umbra statt neutralem Grau (Schatten, Abdunklung, Linien); v1: 0x2E2E2C

    // Noise-Ebene
    static let noiseOpacity: Float = 0.05       // bei 100 % gerade sichtbar; v1: 0.06 bei Textur-Std 55, jetzt Std 34 (Effekt auf dem Papier: Std 3.3 -> 1.7 Stufen)

    // Abgedunkeltes Papier während eines Drags (Briefing „Look“)
    static let dimOpacity: Float = 0.35         // warmes Graphit über dem Papier, unter den Bildern; Ergebnis ca. #AFA89F (v1: #ADABA5 neutral)

    // Harter Schatten (kein Blur)
    static let shadowRadius: CGFloat = 0
    static let shadowOffset = CGSize(width: 1.5, height: -1.5)  // pt; nach unten rechts (y-up, nicht geflippt)
    static let shadowOpacity: Float = 0.45        // v1: 0.25; auf Board ca. #9D968C statt #BEBBB5 (Kontrast 2.5:1 statt 1.6:1)

    // Platzhalter bis ein File-Promise erfüllt ist: leeres Papier-Rechteck, etwas heller als das Board
    static let placeholderHex: UInt32 = 0xFBF9F4

    // Eselsohr: umgeknickte Ecke. Die Lasche zeigt die Papier-Rückseite (etwas dunkler und kühler als die Vorderseite),
    // gedämpft, ohne Schatten im Ruhezustand. Nach Noise ca. #E0DED8 (Board: #EEEAE3).
    static let earBackHex: UInt32 = 0xE5E3DD    // v1: 0xE9E3D7 (wärmer, wirkte wie flaches Dreieck)
    static let earOpacity: Float = 0.9
    static let earEdgeAlpha: CGFloat = 0.18     // schmaler harter Kantenstrich an den beiden Papierkanten (Lesbarkeit auf Hell); v1: 0.14
    static let earFoldAlpha: CGFloat = 0.24     // Falzlinie (Diagonale); v1: 0.28
    static let earFoldBandAlpha: CGFloat = 0.07 // schmale Abdunklung der Lasche entlang des Falzes (Papierwölbung), flach, 3 pt
    static let earFoldHighlightAlpha: CGFloat = 0.45 // heller Haarstrich direkt neben der Falzlinie (Falzkante)

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
