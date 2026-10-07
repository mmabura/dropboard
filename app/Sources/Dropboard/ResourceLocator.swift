import Foundation

/// Findet mitgelieferte Ressourcen, ohne `Bundle.module` anzufassen.
///
/// Warum: Der von SwiftPM generierte Accessor `Bundle.module` sucht nur
/// `Bundle.main.bundleURL/Dropboard_Dropboard.bundle` und einen absoluten Build-Pfad und ruft sonst
/// `fatalError`. In einer `.app` zeigt `bundleURL` auf den `.app`-Ordner (dort darf nichts liegen, sonst
/// scheitert codesign), und den Build-Pfad gibt es auf einem anderen Mac nicht → Absturz beim Start.
///
/// Suchreihenfolge (erster Treffer gewinnt, nie ein Crash):
///  1. `Bundle.main` direkt – in der `.app` liegt `noise.png` in `Contents/Resources` (build-app.sh).
///  2. `Bundle.main.resourceURL/Dropboard_Dropboard.bundle` – falls das SwiftPM-Bundle mit in die `.app` kopiert wird.
///  3. Neben dem Executable: `<exe-ordner>/Dropboard_Dropboard.bundle` – so liegt es bei `swift build`/`swift run`.
/// Nichts gefunden → `nil` + eine Logzeile; der Aufrufer arbeitet dann ohne die Ressource.
enum ResourceLocator {
    /// Name des SwiftPM-Ressourcen-Bundles: `<Paket>_<Target>.bundle`.
    static let spmBundleName = "Dropboard_Dropboard.bundle"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let fm = FileManager.default
        let main = Bundle.main

        // 1. Direkt im Haupt-Bundle (Contents/Resources der .app).
        if let url = main.url(forResource: name, withExtension: ext), fm.fileExists(atPath: url.path) {
            return url
        }

        // 2./3. SwiftPM-Bundle in Contents/Resources bzw. neben dem Executable.
        var bundleDirs: [URL] = []
        if let res = main.resourceURL {
            bundleDirs.append(res.appendingPathComponent(spmBundleName, isDirectory: true))
        }
        if let exe = main.executableURL {
            bundleDirs.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent(spmBundleName, isDirectory: true))
        }
        let file = "\(name).\(ext)"
        for dir in bundleDirs where fm.fileExists(atPath: dir.path) {
            // SwiftPM legt die Datei je nach Plattform/Version flach oder unter Contents/Resources ab.
            // ⚠️ VERIFIZIEREN: Layout des SwiftPM-Bundles im Release-Build (Spike board-paper: „flach“, nur debug geprüft).
            for candidate in [dir.appendingPathComponent(file),
                              dir.appendingPathComponent("Contents/Resources").appendingPathComponent(file)]
            where fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let searched = ([main.bundleURL.appendingPathComponent("Contents/Resources")] + bundleDirs)
            .map(\.path).joined(separator: ", ")
        Log.line("[WIN]", "Ressource \(file) nicht gefunden (gesucht: \(searched)) → weiter ohne")
        return nil
    }
}
