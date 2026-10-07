import Foundation
import DropboardCore

/// Teil 5: Menüleiste/Einstellungen (Schritt 8) – Ecken-Geometrie für alle 4 Ecken (Rahmen im visibleFrame,
/// Einrückung, Abstand zu Menüleiste/Dock, Anker), Verzögerungs-Werte, Settings-Roundtrip in einer eigenen
/// UserDefaults-Suite (danach removePersistentDomain).
enum SettingsSelfTest {
    static let suiteName = "dropboard.selftest"

    static func run(_ t: SelfTestChecker) {
        geometry(t)
        delays(t)
        roundtrip(t)
    }

    // MARK: Geometrie

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// Ecke des visibleFrame, die zu `corner` gehört (y nach oben).
    private static func screenCorner(_ vf: CGRect, _ corner: EarCorner) -> CGPoint {
        CGPoint(x: corner.isRight ? vf.maxX : vf.minX, y: corner.isTop ? vf.maxY : vf.minY)
    }

    private static func geometry(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("settings: " + name, ok()) }
        let size = DropboardConfig.earSize, inset = DropboardConfig.earInset, gap = DropboardConfig.earEdgeGap
        check("Konstanten: Eselsohr 40 pt, Einrückung 12 pt, Abstand 2 pt", size == 40 && inset == 12 && gap == 2)
        check("EarCorner: 4 Ecken, rawValue-Roundtrip",
              EarCorner.allCases.count == 4 && EarCorner.allCases.allSatisfy { EarCorner(rawValue: $0.rawValue) == $0 })
        check("EarCorner: isTop/isRight",
              EarCorner.topRight.isTop && EarCorner.topRight.isRight && EarCorner.topLeft.isTop && !EarCorner.topLeft.isRight
                && !EarCorner.bottomRight.isTop && EarCorner.bottomRight.isRight
                && !EarCorner.bottomLeft.isTop && !EarCorner.bottomLeft.isRight)
        check("Standard-Ecke = oben rechts (Briefing)", DropboardConfig.defaultCorner == .topRight)

        // Hauptbildschirm 1512×982 mit Menüleiste 38 pt und Dock unten 70 pt
        let frameA = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let vfA = CGRect(x: 0, y: 70, width: 1512, height: 874)
        // Zweiter Bildschirm links daneben, versetzt, ohne Dock (Menüleiste 25 pt)
        let frameB = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let vfB = CGRect(x: -1920, y: 100, width: 1920, height: 1055)

        var frames: [CGRect] = []
        for corner in EarCorner.allCases {
            let f = EarGeometry.earFrame(visibleFrame: vfA, corner: corner, size: size, inset: inset, gap: gap)
            frames.append(f)
            let n = corner.rawValue
            check("\(n): 40×40 und ganz im visibleFrame", f.width == 40 && f.height == 40 && vfA.contains(f))
            let horizontal = corner.isRight ? vfA.maxX - f.maxX : f.minX - vfA.minX
            check("\(n): 12 pt vom \(corner.isRight ? "rechten" : "linken") Rand eingerückt", horizontal == 12)
            let vertical = corner.isTop ? vfA.maxY - f.maxY : f.minY - vfA.minY
            check("\(n): 2 pt \(corner.isTop ? "unter der Menüleiste" : "über dem Dock")", vertical == 2)

            let outer = EarGeometry.outerCorner(of: f, corner: corner)
            let vertices = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                            CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
            let sc = screenCorner(vfA, corner)
            let nearest = vertices.min { dist($0, sc) < dist($1, sc) }
            let inner = CGPoint(x: corner.isRight ? f.minX : f.maxX, y: corner.isTop ? f.minY : f.maxY)
            let center = CGPoint(x: vfA.midX, y: vfA.midY)
            check("\(n): Anker = Rahmen-Ecke zur Bildschirmecke, Falz zeigt zur Mitte",
                  nearest == outer && dist(inner, center) < dist(outer, center))

            let anchor = EarGeometry.anchor(earFrame: f, corner: corner, boardFrame: frameA)
            check("\(n): Anker in Board-Koordinaten = äußere Ecke − Board-Ursprung, im Board",
                  anchor == CGPoint(x: outer.x - frameA.minX, y: outer.y - frameA.minY)
                    && anchor.x >= 0 && anchor.x <= frameA.width && anchor.y >= 0 && anchor.y <= frameA.height)
        }
        check("4 Ecken → 4 verschiedene Rahmen, keine Überlappung",
              Set(frames.map { "\($0)" }).count == 4
                && (0..<4).allSatisfy { i in (0..<4).allSatisfy { j in i == j || !frames[i].intersects(frames[j]) } })
        check("oben rechts wie bisher (vf.maxX − 12 − 40, vf.maxY − 2 − 40)",
              frames[0] == CGRect(x: vfA.maxX - 52, y: vfA.maxY - 42, width: 40, height: 40))

        // Versetzter zweiter Bildschirm (negative x): alle Ecken im visibleFrame, Anker im Board
        let okB = EarCorner.allCases.allSatisfy { corner -> Bool in
            let f = EarGeometry.earFrame(visibleFrame: vfB, corner: corner, size: size, inset: inset, gap: gap)
            let a = EarGeometry.anchor(earFrame: f, corner: corner, boardFrame: frameB)
            let horizontal = corner.isRight ? vfB.maxX - f.maxX : f.minX - vfB.minX
            let vertical = corner.isTop ? vfB.maxY - f.maxY : f.minY - vfB.minY
            return vfB.contains(f) && horizontal == 12 && vertical == 2
                && a.x >= 0 && a.x <= frameB.width && a.y >= 0 && a.y <= frameB.height
        }
        check("zweiter Bildschirm (x < 0, versetzt): alle 4 Ecken korrekt", okB)
    }

    // MARK: Verzögerung

    private static func delays(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("settings: " + name, ok()) }
        check("Verzögerung: Auswahl 150/300/500/800 ms", ExpandDelay.choicesMs == [150, 300, 500, 800])
        check("Verzögerung: Standard 300 ms (E10), in der Auswahl",
              ExpandDelay.defaultMs == 300 && DropboardConfig.defaultExpandDelayMs == 300 && ExpandDelay.choicesMs.contains(300))
        check("Verzögerung: sanitized (nil→300, 500→500, 1234→300, 0→300, -150→300)",
              ExpandDelay.sanitized(nil) == 300 && ExpandDelay.sanitized(500) == 500 && ExpandDelay.sanitized(1234) == 300
                && ExpandDelay.sanitized(0) == 300 && ExpandDelay.sanitized(-150) == 300)
        check("Verzögerung: aufsteigend, alle > 0 und < 1 s",
              zip(ExpandDelay.choicesMs, ExpandDelay.choicesMs.dropFirst()).allSatisfy { $0 < $1 }
                && ExpandDelay.choicesMs.allSatisfy { $0 > 0 && $0 < 1000 })
    }

    // MARK: Settings-Roundtrip (eigene Suite)

    private static func roundtrip(_ t: SelfTestChecker) {
        func check(_ name: String, _ ok: @autoclosure () -> Bool) { t.check("settings: " + name, ok()) }
        // ⚠️ VERIFIZIEREN: UserDefaults(suiteName:) + removePersistentDomain(forName:) räumen vollständig auf
        // (cfprefsd kann eine leere ~/Library/Preferences/dropboard.selftest.plist stehen lassen – harmlos).
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("UserDefaults(suiteName: \(suiteName)) verfügbar", false)
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        check("Keys: alle mit Präfix dropboard.",
              Settings.Key.all.count == 3 && Settings.Key.all.allSatisfy { $0.hasPrefix(Settings.Key.prefix) }
                && Settings.Key.prefix == "dropboard.")
        check("Ausblenden wird nicht gespeichert (kein Key dafür)",
              !Settings.Key.all.contains { $0.lowercased().contains("hid") || $0.lowercased().contains("ausblend") })

        let fresh = Settings(defaults: defaults)
        check("leer: Standardwerte (oben rechts, 300 ms, 0.3 s, Login aus)",
              fresh.corner == .topRight && fresh.expandDelayMs == 300 && fresh.expandDelay == 0.3 && !fresh.launchAtLogin)

        fresh.corner = .bottomLeft
        fresh.expandDelayMs = 800
        fresh.launchAtLogin = true
        let reread = Settings(defaults: defaults)
        check("Roundtrip: neue Instanz liest unten links / 800 ms / Login an",
              reread.corner == .bottomLeft && reread.expandDelayMs == 800 && reread.expandDelay == 0.8 && reread.launchAtLogin)
        check("Roundtrip: Rohwerte unter dropboard.corner / dropboard.expandDelayMs",
              defaults.string(forKey: "dropboard.corner") == "bottomLeft" && defaults.integer(forKey: "dropboard.expandDelayMs") == 800
                && defaults.bool(forKey: "dropboard.launchAtLogin"))

        let cornersOK = EarCorner.allCases.allSatisfy { corner -> Bool in
            fresh.corner = corner
            return Settings(defaults: defaults).corner == corner
        }
        check("Roundtrip: alle 4 Ecken", cornersOK)
        let delaysOK = ExpandDelay.choicesMs.allSatisfy { ms -> Bool in
            fresh.expandDelayMs = ms
            let s = Settings(defaults: defaults)
            return s.expandDelayMs == ms && s.expandDelay == Double(ms) / 1000
        }
        check("Roundtrip: alle 4 Verzögerungen (ms und s)", delaysOK)

        defaults.set("quer", forKey: Settings.Key.corner)
        defaults.set(1234, forKey: Settings.Key.expandDelayMs)
        check("ungültige gespeicherte Werte → Standard (oben rechts, 300 ms)",
              Settings(defaults: defaults).corner == .topRight && Settings(defaults: defaults).expandDelayMs == 300)
        fresh.expandDelayMs = 999
        check("Setter mit ungültigem Wert speichert den Standard (300)", defaults.integer(forKey: Settings.Key.expandDelayMs) == 300)

        defaults.removePersistentDomain(forName: suiteName)
        let cleared = Settings(defaults: defaults)
        check("nach removePersistentDomain: wieder Standardwerte",
              cleared.corner == .topRight && cleared.expandDelayMs == 300 && !cleared.launchAtLogin)
        check("nach removePersistentDomain: Domäne leer",
              (defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)
    }
}
