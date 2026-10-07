# Dropboard __VERSION__ (Build __BUILD__)

Prototyp, gebaut am __DATE__. Architekturen: __ARCHS__. Ad-hoc signiert, nicht notarisiert.
Läuft ab macOS 14.

## Installation

1. `Dropboard.app` in den Ordner „Programme“ ziehen (im DMG: auf den Pfeil-Ordner „Programme“ ziehen).
2. Dropboard per Doppelklick starten. Es erscheint kein Dock-Symbol und kein Fenster,
   nur das Eselsohr oben rechts am Bildschirm und ein kleines Blatt-Symbol rechts in der Menüleiste.

## Erster Start auf einem anderen Mac

Die App ist nur ad-hoc signiert (kein Apple-Entwicklerzertifikat). Kommt sie aus dem Netz
(Download, Mail, AirDrop), sollte macOS den ersten Start blockieren. Dann:

1. Dropboard einmal per Doppelklick starten und die Meldung schließen.
2. Systemeinstellungen → Datenschutz & Sicherheit → ganz nach unten scrollen →
   bei „Dropboard wurde blockiert …“ auf „Trotzdem öffnen“ klicken und bestätigen.
   (Ab macOS 15 sollte das der einzige Weg per Mausklick sein; Rechtsklick → „Öffnen“ reicht dort nicht mehr.)

Alternativ im Terminal (danach normal per Doppelklick starten):

    xattr -dr com.apple.quarantine /Applications/Dropboard.app

Per Dropbox synchronisierte Kopien sollten meist ohne diese Sperre starten.

## Bedienung

- Eselsohr oben rechts: dort landet alles.
- Bild (Finder, Safari, Screenshot-Vorschau) aufs Eselsohr ziehen und sofort loslassen = schnell ablegen.
- Bild aufs Eselsohr ziehen und kurz halten = das Board klappt auf; dort an der gewünschten Stelle loslassen.
- Klick aufs Eselsohr = Ansichtsmodus (Board ansehen, ohne etwas abzulegen). Schließen mit Esc oder erneutem Klick.
  - Bild ziehen = umsortieren; Bild anklicken und Backspace = löschen.
  - **Doppelklick auf ein Bild = beschneiden.** Das ganze Bild erscheint gerade, außerhalb des Rahmens abgedunkelt.
    An den Ecken und Kanten ziehen ändert den Ausschnitt (mit gedrückter ⇧-Taste bleibt das Seitenverhältnis),
    im Rahmen ziehen verschiebt das Bild darunter, **R** zeigt wieder das ganze Bild.
    Übernehmen mit Return, Doppelklick oder Klick neben das Bild; Esc bricht ab.
    Die Originaldatei bleibt unverändert, der Ausschnitt lässt sich jederzeit wieder ändern.
- Menüleisten-Symbol (Blatt mit Eselsohr) anklicken:
  - „Board öffnen“ – wie ein Klick aufs Eselsohr.
  - „Eselsohr ausblenden“ – versteckt das Eselsohr, z. B. für Bildschirmaufnahmen und Präsentationen.
    Schneller per Tastenkürzel **⌃⌥⌘E** (Control-Option-Command-E), auch nochmal zum Einblenden.
    Nach einem Neustart ist das Eselsohr immer wieder da.
  - „Ecke“ – Eselsohr oben rechts, oben links, unten rechts oder unten links.
  - „Verzögerung bis Aufklappen“ – wie lange man ein Bild aufs Eselsohr halten muss, bis das Board aufgeht
    (Standard 300 ms).
  - „Beim Anmelden starten“ – Dropboard startet automatisch nach dem Anmelden (nur sinnvoll, wenn die App im
    Ordner „Programme“ liegt; ggf. in Systemeinstellungen → Allgemein → Anmeldeobjekte bestätigen).
  - **„Board exportieren“** – „Als PNG“, „Als PDF“ oder „Originale als Ordner“ exportiert sofort, ohne Nachfrage,
    auf den Schreibtisch (Datei „Dropboard <Datum Uhrzeit>“) und zeigt die Datei im Finder.
    Darunter: Auflösung (72, 150, 300 oder 600 dpi; Standard 300), Bereich („Nur Inhalt“ = alle Bilder mit etwas
    Papierrand, oder „Ganze Fläche“) und Exportordner („Schreibtisch“ oder „Anderer Ordner…“ zum Auswählen).
    Sehr große Exporte werden automatisch auf höchstens 16 384 Pixel pro Seite begrenzt (die DPI sinkt dann etwas).
    Im Board (nach Klick aufs Eselsohr) exportiert **⌘E** im zuletzt gewählten Format; das Board schließt dabei.
  - „Board-Ordner im Finder zeigen“ – dort liegen die Bildkopien.
  - **„Dropboard beenden“**.
- Fehlt das Symbol in der Menüleiste (zu viele Symbole oder in den Systemeinstellungen → Menüleiste ausgeblendet),
  lässt sich Dropboard im Terminal mit `pkill Dropboard` beenden.

## Wo liegen die Daten?

- Board und Bildkopien: `~/Library/Application Support/Dropboard/Boards/default/`
  (`board.json` und Ordner `images/`)
- Protokoll: `~/Library/Logs/Dropboard/dropboard.log`

Deinstallieren: App beenden, `Dropboard.app` aus „Programme“ löschen, optional die beiden Ordner oben.
