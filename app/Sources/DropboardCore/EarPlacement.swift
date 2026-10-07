import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Briefing-Schritt 8 (Einstellungen): Ecke des Eselsohrs und Verzögerung bis zum Aufklappen.
// Reine Geometrie/Werte, ohne AppKit, damit `--selftest` sie prüfen kann.
// Koordinaten hier: Bildschirm-Koordinaten wie AppKit (pt, Ursprung unten links, y nach OBEN).

/// Bildschirmecke, in der das Eselsohr sitzt. Rohwerte gehen so in die UserDefaults (`dropboard.corner`).
public enum EarCorner: String, CaseIterable, Equatable {
    case topRight, topLeft, bottomRight, bottomLeft

    /// Oben (knapp unter der Menüleiste) oder unten (knapp über dem Dock)?
    public var isTop: Bool { self == .topRight || self == .topLeft }
    /// Rechts oder links?
    public var isRight: Bool { self == .topRight || self == .bottomRight }
}

public enum EarGeometry {
    /// Rahmen des Eselsohrs (Bildschirm-Koordinaten, y nach oben) innerhalb von `visibleFrame`
    /// (= Bildschirm ohne Menüleiste und Dock): horizontal `inset` vom linken/rechten Rand eingerückt,
    /// vertikal `gap` unter der Menüleiste (oben) bzw. über dem Dock/unteren Rand (unten).
    public static func earFrame(visibleFrame vf: CGRect, corner: EarCorner,
                                size: CGFloat, inset: CGFloat, gap: CGFloat) -> CGRect {
        let x = corner.isRight ? vf.maxX - inset - size : vf.minX + inset
        let y = corner.isTop ? vf.maxY - gap - size : vf.minY + gap
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// Äußere Ecke des Eselsohr-Rahmens (die zur Bildschirmecke zeigt). Das ist die „umgeknickte“ Ecke,
    /// der Falz zeigt von hier zur Bildschirmmitte. Anker für Aufblättern/Zuklappen.
    public static func outerCorner(of earFrame: CGRect, corner: EarCorner) -> CGPoint {
        CGPoint(x: corner.isRight ? earFrame.maxX : earFrame.minX,
                y: corner.isTop ? earFrame.maxY : earFrame.minY)
    }

    /// Anker in Layer-Koordinaten des Boards (Ursprung = Board-Ursprung unten links, y nach oben).
    public static func anchor(earFrame: CGRect, corner: EarCorner, boardFrame: CGRect) -> CGPoint {
        let p = outerCorner(of: earFrame, corner: corner)
        return CGPoint(x: p.x - boardFrame.minX, y: p.y - boardFrame.minY)
    }
}

/// Verzögerung bis zum Aufklappen bei Drag-Hover auf dem Eselsohr (E10: Standard 300 ms).
/// Nur die Werte aus dem Menü sind erlaubt; alles andere (z. B. per `defaults write`) fällt auf den Standard zurück.
public enum ExpandDelay {
    public static let choicesMs: [Int] = [150, 300, 500, 800]
    public static let defaultMs = 300

    public static func sanitized(_ ms: Int?) -> Int {
        guard let ms = ms, choicesMs.contains(ms) else { return defaultMs }
        return ms
    }
}
