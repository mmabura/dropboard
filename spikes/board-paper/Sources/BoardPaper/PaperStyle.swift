import AppKit
import QuartzCore

/// Alle visuellen Konstanten des Spikes an einer Stelle.
enum PaperStyle {
    // Farben (sRGB, 0xRRGGBB)
    static let paperHex: UInt32 = 0xF4F0E8      // warmes Off-White, kein reines Weiss
    static let graphiteHex: UInt32 = 0x2E2E2C   // Graphit statt Schwarz (Schatten, Abdunklung, Text)

    // Noise-Ebene
    static let noiseOpacity: Float = 0.06       // bei 100 % gerade sichtbar; hier nachjustieren

    // Abgedunkeltes Papier (Taste D)
    static let dimOpacity: Float = 0.35         // Graphit ueber dem Papier

    // Bilder
    static let imageLongestEdge: CGFloat = 220  // pt
    static let snapGrid: CGFloat = 24           // pt, unsichtbar; der Bildmittelpunkt snappt
    static let rotationDegreesRange: ClosedRange<Double> = 1.0...2.0  // Betrag, Vorzeichen zufaellig

    // Harter Schatten (kein Blur)
    static let shadowRadius: CGFloat = 0
    static let shadowOffset = CGSize(width: 1.5, height: -1.5)  // pt; nach unten rechts (y-up, nicht geflippt)
    static let shadowOpacity: Float = 0.25

    // Hilfezeile
    static let helpText = "Klick: Bild ablegen · D: abdunkeln · N: Noise · Esc"
    static let helpFontSize: CGFloat = 11
    static let helpInset = CGPoint(x: 24, y: 16)

    // Hilfsfunktionen
    static func cgColor(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// Fuehrt Layer-Aenderungen ohne implizite Animationen aus (Report 03, Abschnitt 3, Weg 1).
func withoutImplicitAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}
