#!/usr/bin/env bash
# Baut Dropboard.app (+ .zip + .dmg) aus dem SwiftPM-Executable. Nur macOS, nur Command Line Tools (kein Xcode).
#
#   app/scripts/build-app.sh [--version X.Y[.Z]] [--arm64-only] [--no-hardened-runtime] [--publish] [--install]
#
# Ergebnis in app/dist/:  Dropboard.app, Dropboard-<version>.zip, Dropboard-<version>.dmg
#   --version X.Y        Version (CFBundleShortVersionString). Ohne: aus `git describe --tags`, sonst 0.1.<Commits>.
#                        Build-Nummer (CFBundleVersion) ist immer `git rev-list --count HEAD`.
#   --arm64-only         keinen x86_64-Build versuchen (sonst: Versuch, bei Fehler Warnung und arm64-only weiter).
#   --no-hardened-runtime  ohne `--options runtime` signieren.
#   --publish            nach "~/Library/CloudStorage/Dropbox/_PROJECTS/CLAUDE CODE/Dropboard/" kopieren
#                        (versions/v<version>/Dropboard-v<version>.app, Dropboard-latest.zip/.dmg, Dropboard-README.md).
#   --install            nach /Applications/Dropboard.app kopieren (laufende Instanz wird vorher beendet).
#
# Signatur: nur ad-hoc (`codesign -s -`), keine Notarisierung (auf dem Mac mini gibt es keine Signier-Identität).
set -euo pipefail

APP_NAME="Dropboard"
BUNDLE_ID="app.dropboard.Dropboard"
MIN_MACOS="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
PKG_DIR="$APP_DIR/Packaging"
DIST_DIR="$APP_DIR/dist"
NOISE_PNG="$APP_DIR/Sources/Dropboard/Resources/noise.png"
DROPBOX_PARENT="$HOME/Library/CloudStorage/Dropbox/_PROJECTS/CLAUDE CODE"
PUBLISH_DIR="$DROPBOX_PARENT/$APP_NAME"
INSTALL_PATH="/Applications/$APP_NAME.app"

VERSION=""
ARM64_ONLY=0
HARDENED=1
PUBLISH=0
INSTALL=0

say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNUNG: %s\n' "$*" >&2; }
die()  { printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || die "--version braucht einen Wert, z. B. --version 0.2"
            VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#--version=}"; shift ;;
        --arm64-only) ARM64_ONLY=1; shift ;;
        --no-hardened-runtime) HARDENED=0; shift ;;
        --publish) PUBLISH=1; shift ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unbekanntes Argument: $1" ;;
    esac
done

# ---------------------------------------------------------------- Voraussetzungen
[[ "$(uname -s)" == "Darwin" ]] || die "Nur auf macOS lauffähig (uname: $(uname -s))."
for tool in swift lipo sips iconutil codesign ditto hdiutil plutil xattr otool; do
    command -v "$tool" >/dev/null 2>&1 || die "Werkzeug fehlt: $tool (Command Line Tools installiert? xcode-select --install)"
done
[[ -f "$PKG_DIR/Info.plist" ]]       || die "fehlt: $PKG_DIR/Info.plist"
[[ -f "$PKG_DIR/AppIcon-1024.png" ]] || die "fehlt: $PKG_DIR/AppIcon-1024.png (python3 app/Packaging/make_icon.py)"
[[ -f "$PKG_DIR/Zuerst-lesen.md" ]]  || die "fehlt: $PKG_DIR/Zuerst-lesen.md"
[[ -f "$NOISE_PNG" ]]                || die "fehlt: $NOISE_PNG"
if [[ $PUBLISH -eq 1 && ! -d "$DROPBOX_PARENT" ]]; then
    die "Dropbox-Ordner nicht gefunden: \"$DROPBOX_PARENT\" – nichts veröffentlicht, nichts angelegt."
fi

# ---------------------------------------------------------------- Version
BUILD_NUMBER="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unbekannt)"
DIRTY=""
if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null || true)" ]]; then DIRTY=" (mit uncommitteten Änderungen)"; fi
if [[ -z "$VERSION" ]]; then
    if DESC="$(git -C "$REPO_DIR" describe --tags --long --match 'v[0-9]*' 2>/dev/null)"; then
        # v1.2-3-gabc1234 → Tag 1.2, Abstand 3
        TAG="${DESC%-*-g*}"; TAG="${TAG#v}"
        DIST="${DESC%-g*}"; DIST="${DIST##*-}"
        if [[ "$DIST" == "0" ]]; then
            VERSION="$TAG"
        elif [[ "$TAG" =~ ^[0-9]+\.[0-9]+$ ]]; then
            VERSION="$TAG.$DIST"
        else
            VERSION="$TAG"
            warn "$DIST Commits seit Tag v$TAG – Version bleibt $TAG (mit --version überschreiben)."
        fi
    else
        VERSION="0.1.$BUILD_NUMBER"
    fi
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "Ungültige Version \"$VERSION\" (erwartet X.Y oder X.Y.Z)."

say "Dropboard $VERSION (Build $BUILD_NUMBER, Commit $COMMIT$DIRTY)"
[[ -n "$DIRTY" ]] && warn "Arbeitskopie hat uncommittete Änderungen – der Build entspricht nicht exakt Commit $COMMIT."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dropboard-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- Kompilieren
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    arm64)  OTHER_ARCH="x86_64" ;;
    x86_64) OTHER_ARCH="arm64" ;;
    *) die "Unbekannte Host-Architektur: $HOST_ARCH" ;;
esac

say "swift build -c release ($HOST_ARCH)"
swift build --package-path "$APP_DIR" -c release
HOST_BIN="$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/$APP_NAME"
[[ -x "$HOST_BIN" ]] || die "Executable nicht gefunden: $HOST_BIN"

EXE="$WORK/$APP_NAME"
if [[ $ARM64_ONLY -eq 1 ]]; then
    info "--arm64-only: kein $OTHER_ARCH-Versuch"
    cp "$HOST_BIN" "$EXE"
else
    # ⚠️ VERIFIZIEREN: Cross-Build per --triple mit reinen Command Line Tools ist ungetestet.
    TRIPLE="$OTHER_ARCH-apple-macosx$MIN_MACOS"
    CROSS_SCRATCH="$APP_DIR/.build/cross-$OTHER_ARCH"
    CROSS_LOG="$WORK/cross-build.log"
    say "Versuch: swift build -c release --triple $TRIPLE"
    if swift build --package-path "$APP_DIR" -c release --triple "$TRIPLE" --scratch-path "$CROSS_SCRATCH" \
            >"$CROSS_LOG" 2>&1; then
        CROSS_BIN="$(swift build --package-path "$APP_DIR" -c release --triple "$TRIPLE" \
            --scratch-path "$CROSS_SCRATCH" --show-bin-path)/$APP_NAME"
        if [[ -x "$CROSS_BIN" ]] && lipo -create -output "$EXE" "$HOST_BIN" "$CROSS_BIN"; then
            info "Universal-Binary: $(lipo -archs "$EXE")"
        else
            warn "$OTHER_ARCH gebaut, aber lipo fehlgeschlagen – weiter nur mit $HOST_ARCH."
            cp "$HOST_BIN" "$EXE"
        fi
    else
        warn "$OTHER_ARCH-Build fehlgeschlagen – weiter nur mit $HOST_ARCH. Letzte Zeilen:"
        tail -n 15 "$CROSS_LOG" >&2 || true
        cp "$HOST_BIN" "$EXE"
    fi
fi
ARCHS="$(lipo -archs "$EXE")"

# Abhängigkeiten außerhalb des Systems wären auf dem Laptop nicht vorhanden → nur melden.
# (otool -L: Abhängigkeiten stehen in Zeilen mit führendem Tab; Kopfzeilen je Architektur nicht.)
FOREIGN_LIBS="$(otool -L "$EXE" | grep -E $'^\t' | awk '{print $1}' \
    | grep -v -E '^(/usr/lib/|/System/Library/)' | sort -u | tr '\n' ' ' || true)"
[[ -n "$FOREIGN_LIBS" ]] && warn "Executable lädt Bibliotheken außerhalb von /usr/lib und /System: $FOREIGN_LIBS"

# ---------------------------------------------------------------- Bundle
APP="$DIST_DIR/$APP_NAME.app"
say "Bundle $APP"
mkdir -p "$DIST_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUILD__|$BUILD_NUMBER|g" -e "s|__YEAR__|$(date +%Y)|g" \
    "$PKG_DIR/Info.plist" >"$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist ungültig"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
    || die "CFBundleIdentifier in Info.plist ist nicht $BUNDLE_ID"
grep -q '__[A-Z]*__' "$APP/Contents/Info.plist" && die "Info.plist enthält noch Platzhalter"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# Icon: alle Größen 16…512 und @2x (bis 1024) aus der 1024er-PNG
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PKG_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PKG_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Noise-Textur flach in Contents/Resources (ResourceLocator sucht dort zuerst; Bundle.module wird nicht benutzt).
# Das SwiftPM-Ressourcen-Bundle wird bewusst NICHT mitkopiert: nicht nötig, und ein verschachteltes .bundle
# ohne Code bringt nur zusätzliche Fragen bei codesign.
cp "$NOISE_PNG" "$APP/Contents/Resources/noise.png"

# ---------------------------------------------------------------- Signieren (ad-hoc)
say "Ad-hoc-Signatur"
xattr -cr "$APP"   # Finder-Infos/Resource-Forks würden codesign mit „detritus not allowed“ abbrechen lassen
SIGNED_RUNTIME="nein"
if [[ $HARDENED -eq 1 ]]; then
    # ⚠️ VERIFIZIEREN: Hardened Runtime mit Ad-hoc-Signatur (-s -) auf dem Mac mini. Bei Fehler: ohne Runtime.
    if codesign --force --sign - --timestamp=none --options runtime "$APP"; then
        SIGNED_RUNTIME="ja"
    else
        warn "Signieren mit --options runtime fehlgeschlagen – neuer Versuch ohne Hardened Runtime."
        codesign --force --sign - --timestamp=none "$APP"
    fi
else
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict --verbose=2 "$APP" || die "codesign --verify ist fehlgeschlagen"
SIG_SUMMARY="$(codesign -dv "$APP" 2>&1 | grep -E '^(Signature|CodeDirectory|Identifier)' | tr '\n' ' ' || true)"
info 'Gatekeeper (nur Info, bei Ad-hoc ist "rejected" erwartet):'
spctl -a -vv "$APP" 2>&1 | sed 's/^/      /' || true

# ---------------------------------------------------------------- ZIP und DMG
fill_readme() {   # $1 = Ziel
    sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUILD__|$BUILD_NUMBER|g" -e "s|__DATE__|$(date +%Y-%m-%d)|g" \
        -e "s|__ARCHS__|$ARCHS|g" "$PKG_DIR/Zuerst-lesen.md" >"$1"
}

ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"
say "ZIP $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
say "DMG $DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Programme"
fill_readme "$STAGE/Zuerst lesen.txt"
rm -f "$DMG"
ok=0
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null; then
        ok=1; break
    fi
    warn "hdiutil create fehlgeschlagen (Versuch $attempt/3)"; sleep 2
done
[[ $ok -eq 1 ]] || die "DMG konnte nicht erstellt werden"

README_OUT="$DIST_DIR/$APP_NAME-README.md"
fill_readme "$README_OUT"

# ---------------------------------------------------------------- Veröffentlichen (Dropbox, nineTracker-Muster)
PUBLISHED_APP=""
if [[ $PUBLISH -eq 1 ]]; then
    say "Veröffentlichen nach \"$PUBLISH_DIR\""
    VERSION_DIR="$PUBLISH_DIR/versions/v$VERSION"
    PUBLISHED_APP="$VERSION_DIR/$APP_NAME-v$VERSION.app"
    mkdir -p "$VERSION_DIR"
    if [[ -e "$PUBLISHED_APP" ]]; then
        warn "Version v$VERSION existiert schon – wird ersetzt: $PUBLISHED_APP"
        rm -rf "$PUBLISHED_APP"
    fi
    ditto "$APP" "$PUBLISHED_APP"
    cp -f "$ZIP" "$PUBLISH_DIR/$APP_NAME-latest.zip"
    cp -f "$DMG" "$PUBLISH_DIR/$APP_NAME-latest.dmg"
    cp -f "$README_OUT" "$PUBLISH_DIR/$APP_NAME-README.md"
    # ⚠️ VERIFIZIEREN: Dropbox kann eigene xattrs setzen; Signatur der Kopie nur informativ prüfen.
    if codesign --verify --strict "$PUBLISHED_APP" 2>/dev/null; then
        info "Signatur der veröffentlichten Kopie: gültig"
    else
        warn "Signatur der veröffentlichten Kopie meldet einen Fehler (Dropbox-Attribute?) – ZIP/DMG nutzen."
    fi
fi

# ---------------------------------------------------------------- Installieren
if [[ $INSTALL -eq 1 ]]; then
    say "Installieren nach $INSTALL_PATH"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        info "Laufende Instanz von $APP_NAME wird beendet (pkill -x $APP_NAME) – auch eine per swift run gestartete."
        pkill -x "$APP_NAME" || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.5
        done
        pgrep -x "$APP_NAME" >/dev/null 2>&1 && die "$APP_NAME läuft noch – bitte manuell beenden und erneut versuchen."
    fi
    rm -rf "$INSTALL_PATH"
    ditto "$APP" "$INSTALL_PATH"
    info "Installiert. Start: open \"$INSTALL_PATH\""
fi

# ---------------------------------------------------------------- Zusammenfassung
size_of() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
say "Fertig: $APP_NAME $VERSION (Build $BUILD_NUMBER, Commit $COMMIT$DIRTY)"
info "App:          $APP ($(size_of "$APP"))"
info "ZIP:          $ZIP ($(size_of "$ZIP"))"
info "DMG:          $DMG ($(size_of "$DMG"))"
info "README:       $README_OUT"
info "Architektur:  $(lipo -info "$APP/Contents/MacOS/$APP_NAME")"
info "Signatur:     ad-hoc, Hardened Runtime: $SIGNED_RUNTIME; $SIG_SUMMARY"
[[ -n "$PUBLISHED_APP" ]] && info "Dropbox:      $PUBLISHED_APP (+ $APP_NAME-latest.zip/.dmg, $APP_NAME-README.md)"
[[ $INSTALL -eq 1 ]] && info "Installiert:  $INSTALL_PATH"
exit 0
