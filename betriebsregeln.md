# Betriebsregeln – Dropboard

> **Status: ENTWURF vom Orchestrator, noch nicht von Max abgenommen.**
> Das Briefing verweist auf diese Datei, sie existierte aber noch nicht.
> Bis zur Abnahme gilt sie nur vorläufig.

## Allgemein

- Grundlage ist `docs/briefing.md`. Bei Widerspruch gilt das Briefing.
- Ein Sub-Agent hat genau eine Aufgabe und schreibt nur in die Dateien/Verzeichnisse, die ihm zugewiesen sind.
- **Stop-and-Report:** Bei Blockade (Berechtigung, nicht reproduzierbares Verhalten, widersprüchliche Doku, fehlende Plattform) stoppen und melden. Nicht raten, nicht umgehen.
- **Quellen:** Keine erfundenen URLs, Titel oder Zitate. Was nicht belegt werden kann, wird als ⚠️ VERIFIZIEREN markiert.
- **API-Annahmen:** Code darf nur APIs/Verhaltensweisen voraussetzen, die in einem abgenommenen Phase-0-Report belegt sind. Alles andere bekommt im Code einen Kommentar `// ⚠️ VERIFIZIEREN: …`.

## Report-Format (jeder Sub-Agent)

```
# <Titel>
## Ergebnis          – Antwort auf die Kernfrage in 3–6 Sätzen
## Details           – Begründung, je Aussage mit Quelle
## Offene Punkte     – was nicht geklärt werden konnte
## ⚠️ VERIFIZIEREN   – Liste aller unbelegten Annahmen
## Testplan macOS    – konkrete Schritte, um offene Punkte auf echter Hardware zu prüfen
## Quellen           – nur tatsächlich abgerufene Seiten, mit URL
```

## Plattform-Hinweis

Cloud-Sessions laufen in einem **Linux-Container ohne Xcode, ohne AppKit, ohne macOS**.
Dort kann Swift/AppKit-Code weder gebaut noch ausgeführt werden. Jeder Nachweis
„baut“ / „läuft“ / „verhält sich wie spezifiziert“ muss auf einem echten Mac erbracht
werden. Ein Agent, der so einen Nachweis behauptet, ohne ihn erbracht zu haben,
verletzt diese Regeln.

**Testumgebung macOS:** Max' Mac mini, angebunden als Remote-Control-Session
(`claude remote-control`, Branch `claude/relaxed-bell-vahe5z`). Der Orchestrator
schickt Build- und Testaufträge dorthin. Interaktive Gesten (Screenshot-Thumbnail
ziehen, Fullscreen-App) führt Max aus; Nachweis ist das Log der App
(empfangene Pasteboard-Typen, Fenster-Level, Zeitstempel).

## Definition of Done

### Phase 0 – Recherche
- Je Thema ein Report in `docs/phase0/` im Report-Format.
- Kernfrage explizit beantwortet oder explizit als offen markiert.
- Jede API-Aussage mit Quelle (Apple-Dokumentation bevorzugt) oder ⚠️ VERIFIZIEREN.
- Kein Produktionscode. API-Namen und Signaturen in Fließtext sind erlaubt.
- Testplan für die offenen Punkte vorhanden.
- **Abnahme:** Max liest die Reports und gibt frei.

### Phase 1 – Spikes
- Je Spike ein eigenes Verzeichnis unter `spikes/<name>/` mit eigenem Swift Package oder Xcode-Projekt, keine geteilten Dateien.
- README je Spike: Build-Befehl, Startanleitung, manuelle Testschritte.
- Baut auf macOS ohne Warnungen zu API-Deprecations, die das Verhalten betreffen.
- Testprotokoll vom echten Mac (wer, macOS-Version, Ergebnis je Testschritt).
- **Abnahme:** Max führt die Testschritte aus oder bestätigt das Protokoll.

### Phase 2 – Integration
- Prototyp-Schritte 1–5 aus dem Briefing umgesetzt.
- Realtime- und Stop-Motion-Pfad im Code getrennt und benannt.
- Testprotokoll gegen die Interaktionstabelle (Zeilen, die Schritte 1–5 betreffen).

### Phase 3 – Review
- Befundlisten mit Schweregrad, Datei:Zeile, Reproduktion. Keine Code-Änderungen.
- Review-Agents erhalten nur Briefing + Code.
- Performance: CPU im Idle (Eselsohr sichtbar, kein Drag) und Latenz Hover→Expand gemessen und mit Messmethode dokumentiert.

### Phase 4 – Fix
- Ein Agent pro Befundgruppe, disjunkte Dateisets.
- Je Befund: Nachweis (Test, Messung oder reproduzierbare Schritte vorher/nachher).
