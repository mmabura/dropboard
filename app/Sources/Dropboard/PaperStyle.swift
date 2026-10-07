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
    // Fix C: Versatz an der Briefing-Obergrenze (2 pt = 4 Device-px @2x). Deckkraft so, dass der Schatten dunkler ist als
    // jedes gedämpfte Bild und klar vom Papier absetzt (WCAG-Kontrast nach relativer Luminanz, Papier inkl. Noise #EEEAE3):
    //   0.45 → #9D968C, 2.46:1 zum Papier, 1.02–1.24:1 zu den Demo-Bildern (verschmolz mit der Bildkante, las als „Kante“)
    //   0.65 → #797065, 4.07:1 zum Papier (≥ 3:1), 1.37–2.05:1 zu den Demo-Bildern; abgedunkelt #63594E auf #AFA89F 2.93:1
    static let shadowOffset = CGSize(width: 2, height: -2)  // pt; nach unten rechts (y-up, nicht geflippt); v2: 1.5
    static let shadowOpacity: Float = 0.65        // v2: 0.45, v1: 0.25

    // Platzhalter bis ein File-Promise erfüllt ist: leeres Papier-Rechteck, etwas heller als das Board
    static let placeholderHex: UInt32 = 0xFBF9F4

    // Eselsohr (Fix C): kleines Stück Papier, Vorderseite = Board-Papier (paperHex + gleiche Noise), dessen äußere Ecke
    // (zur Bildschirmecke) diagonal umgeknickt ist. Die Lasche zeigt die Rückseite (minimal dunkler und kühler) und liegt
    // auf der Vorderseite; der weggeknickte Eckbereich ist transparent. Gedämpft, ohne Schatten (Briefing).
    // Nach Noise: Vorderseite ca. #EEEAE3, Lasche ca. #DFDDD7.
    static let earBackHex: UInt32 = 0xE4E2DB    // v2: 0xE5E3DD (nur Lasche gezeichnet), v1: 0xE9E3D7
    static let earOpacity: Float = 0.9
    static let earFoldFraction: CGFloat = 0.5   // Schenkellänge der Lasche relativ zur Kantenlänge (40 pt → 20 pt)
    static let earEdgeAlpha: CGFloat = 0.16     // Haarlinie (1 Device-px, innen) an den Außenkanten der Vorderseite
    static let earFlapEdgeAlpha: CGFloat = 0.20 // Haarlinie (1 Device-px, innen) an den beiden freien Laschenkanten
    static let earFoldAlpha: CGFloat = 0.34     // Falzlinie (1 Device-px, Diagonale)

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
