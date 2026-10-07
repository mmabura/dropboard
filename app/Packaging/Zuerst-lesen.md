# Dropboard __VERSION__ (Build __BUILD__)

Prototyp, gebaut am __DATE__. Architekturen: __ARCHS__. Ad-hoc signiert, nicht notarisiert.
Läuft ab macOS 14.

## Installation

1. `Dropboard.app` in den Ordner „Programme“ ziehen (im DMG: auf den Pfeil-Ordner „Programme“ ziehen).
2. Dropboard per Doppelklick starten. Es erscheint kein Dock-Symbol und kein Fenster,
   nur das Eselsohr oben rechts am Bildschirm.

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
- Klick aufs Eselsohr = Ansichtsmodus (Board ansehen, ohne etwas abzulegen).
- Beenden: vorerst im Terminal `pkill Dropboard` (ein Menüleisten-Symbol mit „Beenden“ kommt in einer späteren Version).

## Wo liegen die Daten?

- Board und Bildkopien: `~/Library/Application Support/Dropboard/Boards/default/`
  (`board.json` und Ordner `images/`)
- Protokoll: `~/Library/Logs/Dropboard/dropboard.log`

Deinstallieren: App beenden, `Dropboard.app` aus „Programme“ löschen, optional die beiden Ordner oben.
