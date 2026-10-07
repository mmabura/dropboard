import AppKit
import Carbon.HIToolbox

/// Globaler Hotkey „Eselsohr ausblenden“ (Briefing: „Ausblenden: Hotkey oder Menüleisten-Schalter“).
///
/// Belegung (im Prototyp fest, kein Recorder): ⌃⌥⌘E.
/// Warum nicht ⌥⌘D: ⌥⌘D ist der System-Kurzbefehl „Dock ein-/ausblenden“ (Systemeinstellungen → Tastatur →
/// Tastaturkurzbefehle → Launchpad & Dock). Er kollidiert also. ⌃⌥⌘E hat keine bekannte Systembelegung
/// (E wie Eselsohr; drei Modifier, damit es auch in Apps kaum belegt ist).
/// ⚠️ VERIFIZIEREN: dass ⌃⌥⌘E auf macOS 26 keine Systembelegung hat (Systemeinstellungen → Tastatur →
/// Tastaturkurzbefehle durchsehen). Ist die Kombination schon von einer anderen App per RegisterEventHotKey belegt,
/// liefert RegisterEventHotKey einen Fehler (eventHotKeyExistsErr) → Log `[SETTINGS] Hotkey … FEHLER`.
enum HideHotKey {
    static let keyCode = UInt32(kVK_ANSI_E)
    static let carbonModifiers = UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
    /// Nur Anzeige im Menü (NSMenuItem.keyEquivalent): Kleinbuchstabe, sonst zeigt das Menü zusätzlich ⇧.
    static let menuKeyEquivalent = "e"
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
    static let display = "⌃⌥⌘E"
    /// Doppelte Auslösung (Hotkey + Menü-Tastenkürzel bei offenem Menü) innerhalb dieser Zeit ignorieren.
    static let debounce: TimeInterval = 0.3
}

/// Carbon-Hotkey ohne Bedienungshilfen-/Eingabeüberwachungs-Berechtigung: `RegisterEventHotKey` +
/// `InstallEventHandler` (kEventClassKeyboard / kEventHotKeyPressed) auf dem Application-Event-Target.
/// Kein NSEvent-Global-Monitor (der bräuchte Bedienungshilfen, Report 02/README Ansichtsmodus).
///
/// ⚠️ VERIFIZIEREN: dass RegisterEventHotKey auf macOS 26 ohne jede Berechtigungsabfrage funktioniert (erwartet: ja;
/// seit macOS 15 sind nur Hotkeys abgelehnt, deren Modifier allein ⌥ bzw. ⌥⇧ sind – hier sind ⌃ und ⌘ dabei).
/// ⚠️ VERIFIZIEREN: dass der Carbon-Handler in einer NSApplication-Run-Loop (AppKit) auf dem Main-Thread läuft.
@MainActor
final class GlobalHotKey {
    /// FourCharCode „DRPB“ als Signatur der Hotkey-ID.
    static let signature: OSType = 0x4452_5042

    let id: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false

    init(id: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
    }

    /// Registriert den Hotkey. Rückgabe: (ok, Status-Text fürs Log).
    func register(keyCode: UInt32, modifiers: UInt32) -> (ok: Bool, status: String) {
        guard !isRegistered else { return (true, "bereits registriert") }

        // ⚠️ VERIFIZIEREN: Signaturen InstallEventHandler(EventTargetRef!, EventHandlerUPP!, Int,
        // UnsafePointer<EventTypeSpec>!, UnsafeMutableRawPointer!, UnsafeMutablePointer<EventHandlerRef?>!) -> OSStatus.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()   // AppController hält das Objekt für die App-Laufzeit
        var handler: EventHandlerRef?
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), dropboardHotKeyHandler, 1, &spec,
                                                context, &handler)
        guard installStatus == 0 else {
            return (false, "InstallEventHandler OSStatus=\(installStatus)")
        }
        handlerRef = handler

        // ⚠️ VERIFIZIEREN: RegisterEventHotKey(UInt32, UInt32, EventHotKeyID, EventTargetRef!, OptionBits,
        // UnsafeMutablePointer<EventHotKeyRef?>!) -> OSStatus.
        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: id)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
                                                 OptionBits(0), &ref)
        guard registerStatus == 0, let hotKey = ref else {
            if let h = handlerRef { RemoveEventHandler(h) }
            handlerRef = nil
            let hint = registerStatus == OSStatus(eventHotKeyExistsErr) ? " (Kombination schon von einer anderen App belegt)" : ""
            return (false, "RegisterEventHotKey OSStatus=\(registerStatus)\(hint)")
        }
        hotKeyRef = hotKey
        isRegistered = true
        return (true, "ok")
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let h = handlerRef { RemoveEventHandler(h) }
        hotKeyRef = nil
        handlerRef = nil
        isRegistered = false
    }

    /// Vom C-Callback (Main-Thread) aufgerufen.
    fileprivate func fire(hotKeyID: UInt32, signature: OSType) -> Bool {
        guard signature == GlobalHotKey.signature, hotKeyID == id else { return false }
        action()
        return true
    }
}

/// C-Callback ohne Captures; der Kontext (GlobalHotKey) kommt über `userData` (Unmanaged, nicht retained).
// ⚠️ VERIFIZIEREN: EventHandlerUPP = @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus;
// GetEventParameter(EventRef!, EventParamName, EventParamType, UnsafeMutablePointer<EventParamType>!, Int,
// UnsafeMutablePointer<Int>!, UnsafeMutableRawPointer!) -> OSStatus.
private let dropboardHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == 0 else { return status }
    let id = hotKeyID.id
    let signature = hotKeyID.signature
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    // Carbon-Events der Application-Target laufen auf dem Main-Thread (siehe ⚠️ oben); assumeIsolated wie in main.swift.
    let handled = MainActor.assumeIsolated { hotKey.fire(hotKeyID: id, signature: signature) }
    return handled ? 0 : OSStatus(eventNotHandledErr)
}
