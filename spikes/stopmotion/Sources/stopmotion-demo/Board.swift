import AppKit
import QuartzCore
import StopMotionCore

/// Layer-Hosting-View (Report 03, Abschnitt 3): erst `layer` setzen, dann `wantsLayer = true`.
/// Keine Subviews. Die Karten sind Standalone-CALayer.
@MainActor
final class BoardView: NSView {
    var onKey: (@MainActor (NSEvent) -> Void)?
    var onBackingChange: (@MainActor () -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.name = "root"
        root.backgroundColor = CGColor(red: 0.965, green: 0.953, blue: 0.925, alpha: 1)   // Off-White
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let onKey { onKey(event) } else { super.keyDown(with: event) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingChange?()
    }
}

/// "Bewegung reduzieren": Systemeinstellung (beim Start gelesen, per Notification aktualisiert) ODER manueller Schalter (Taste M).
@MainActor
final class MotionPreferences: NSObject {
    private(set) var system: Bool
    var manual = false
    var onChange: (@MainActor () -> Void)?

    var effective: Bool { system || manual }

    override init() {
        system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.init()
        // Die Notification kommt nur über NSWorkspace.shared.notificationCenter, nicht über NotificationCenter.default (Report 03).
        // Der Observer lebt so lange wie die App; deshalb kein removeObserver im deinit.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func displayOptionsChanged(_ note: Notification) {
        system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        onChange?()
    }
}

@MainActor
final class Card {
    let id: Int
    let layer: CALayer
    var pose: Pose

    init(id: Int, layer: CALayer, pose: Pose) {
        self.id = id
        self.layer = layer
        self.pose = pose
    }
}

@MainActor
final class DemoController {
    static let boardSize = CGSize(width: 900, height: 600)
    static let cardSize = CGSize(width: 200, height: 140)

    let view = BoardView(frame: CGRect(origin: .zero, size: DemoController.boardSize))
    let content = CALayer()
    let prefs = MotionPreferences()
    private(set) var rng: SplitMix64
    private var cards: [Card] = []
    private var nextID = 1
    private let startUptime = ProcessInfo.processInfo.systemUptime

    // Terrakotta, Ocker, Salbei, Schiefer
    private let palette: [CGColor] = [
        CGColor(red: 0.82, green: 0.42, blue: 0.33, alpha: 1),
        CGColor(red: 0.89, green: 0.69, blue: 0.27, alpha: 1),
        CGColor(red: 0.55, green: 0.69, blue: 0.55, alpha: 1),
        CGColor(red: 0.36, green: 0.47, blue: 0.62, alpha: 1),
    ]

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)

        StopMotion.batch {
            content.name = "content"
            content.frame = CGRect(origin: .zero, size: Self.boardSize)
            view.layer?.addSublayer(content)
        }

        let starts: [(CGPoint, Double)] = [
            (CGPoint(x: 250, y: 400), 1.5), (CGPoint(x: 460, y: 330), -1.0),
            (CGPoint(x: 660, y: 410), 2.0), (CGPoint(x: 450, y: 170), -1.5),
        ]
        for (i, start) in starts.enumerated() {
            addCard(color: palette[i % palette.count], pose: Pose(position: start.0, rotation: start.1))
        }

        view.onKey = { [weak self] event in self?.handleKey(event) }
        view.onBackingChange = { [weak self] in self?.updateContentsScale() }
        prefs.onChange = { [weak self] in
            guard let self else { return }
            self.log("reduce motion changed by system: system=\(self.prefs.system) manual=\(self.prefs.manual) effective=\(self.prefs.effective)")
        }
        log("seed=\(seed) pid=\(ProcessInfo.processInfo.processIdentifier) cards=\(cards.count)")
        log("reduce motion at start: system=\(prefs.system) effective=\(prefs.effective)")
        log("keys: 1 drop | 2 reveal | 3 move | 4 delete+respawn | R realtime reveal | M toggle reduce motion | I idle check | Esc quit")
    }

    // MARK: Karten

    private func makeCardLayer(color: CGColor) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: Self.cardSize)
        layer.backgroundColor = color
        layer.contentsScale = CGFloat(backingScale)
        layer.allowsEdgeAntialiasing = true   // ⚠️ VERIFIZIEREN (V14): saubere Kanten bei Rotation zusammen mit hartem Schatten.

        // Harter Schatten ohne Blur. ⚠️ VERIFIZIEREN (V13): negatives y = nach unten bei nicht geflipptem Layer.
        layer.shadowColor = CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 2, height: -2)
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)

        // Dunklerer Streifen oben, damit Kipp und Jitter erkennbar sind.
        let stripe = CALayer()
        stripe.frame = CGRect(x: 0, y: Self.cardSize.height - 18, width: Self.cardSize.width, height: 18)
        stripe.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        layer.addSublayer(stripe)
        return layer
    }

    @discardableResult
    private func addCard(color: CGColor, pose: Pose) -> Card {
        let id = nextID
        nextID += 1
        let layer = makeCardLayer(color: color)
        layer.name = "card\(id)"
        let card = Card(id: id, layer: layer, pose: pose)
        StopMotion.batch {
            content.addSublayer(layer)
            StopMotion.setModel(pose, on: layer)
        }
        cards.append(card)
        return card
    }

    private func updateContentsScale() {
        let scale = CGFloat(backingScale)
        StopMotion.batch {
            content.contentsScale = scale
            for card in cards { card.layer.contentsScale = scale }
        }
        log("backing scale changed: \(backingScale)")
    }

    // ⚠️ VERIFIZIEREN: Für den Jitter-Raster genügt window.backingScaleFactor (1.0 oder 2.0); Apple rät sonst zu den Backing-Konvertierungsmethoden (Report 03).
    private var backingScale: Double { Double(view.window?.backingScaleFactor ?? 2.0) }

    private var options: PlanOptions {
        PlanOptions(jitter: true, reduceMotion: prefs.effective, backingScale: backingScale)
    }

    private func randomPosition() -> CGPoint {
        let w = Self.boardSize.width, h = Self.boardSize.height
        let mx = Self.cardSize.width / 2 + 40, my = Self.cardSize.height / 2 + 40
        return CGPoint(x: rng.nextDouble(in: Double(mx), Double(w - mx)).rounded(),
                       y: rng.nextDouble(in: Double(my), Double(h - my)).rounded())
    }

    private func randomTilt() -> Double {
        let magnitude = rng.nextDouble(in: 1, 2)
        return rng.nextUnit() < 0.5 ? -magnitude : magnitude
    }

    private func randomCard() -> Card? {
        guard !cards.isEmpty else { return nil }
        return cards[min(cards.count - 1, Int(rng.nextUnit() * Double(cards.count)))]
    }

    // MARK: Tasten

    func handleKey(_ event: NSEvent) {
        if event.isARepeat { return }
        if event.keyCode == 53 {   // ⚠️ VERIFIZIEREN: 53 = kVK_Escape
            NSApp.terminate(nil)
            return
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        switch key {
        case "1": dropRandomCard()
        case "2": revealAll()
        case "3": moveRandomCard()
        case "4": deleteAndRespawn()
        case "r": realtimeReveal()
        case "m": toggleReduceMotion()
        case "i": idleCheck()
        default: break
        }
    }

    // MARK: Stop-Motion-Sequenzen

    private func dropRandomCard() {
        guard let card = randomCard() else { return }
        var target = card.pose
        target.rotation = randomTilt()
        card.pose = target
        let plan = StopMotionSequences.drop(target: target, options: options, using: &rng)
        StopMotion.apply(plan, to: card.layer)
        logSequence("drop", plan, "card\(card.id)")
    }

    private func revealAll() {
        let opts = options
        var count = 0
        var total: StopMotionPlan?
        StopMotion.batch {
            for card in cards {
                let plan = StopMotionSequences.reveal(target: card.pose, options: opts, using: &rng)
                StopMotion.apply(plan, to: card.layer)
                total = plan
                count += 1
            }
        }
        if let total { logSequence("reveal", total, "\(count) cards") }
    }

    private func moveRandomCard() {
        guard let card = randomCard() else { return }
        var target = card.pose
        target.position = randomPosition()
        let plan = StopMotionSequences.move(from: card.pose, to: target, options: options, using: &rng)
        card.pose = target
        StopMotion.apply(plan, to: card.layer)
        logSequence("move", plan, "card\(card.id)")
    }

    private func deleteAndRespawn() {
        guard let card = randomCard() else { return }
        let plan = StopMotionSequences.delete(from: card.pose, options: options, using: &rng)
        cards.removeAll { $0 === card }
        StopMotion.apply(plan, to: card.layer)
        logSequence("delete", plan, "card\(card.id)")

        // Nach dem Ende der Delete-Sequenz: Layer entfernen, neue Karte erzeugen und droppen.
        afterDelay(plan.duration + 0.05) { [self] in
            StopMotion.batch { card.layer.removeFromSuperlayer() }
            let target = Pose(position: randomPosition(), rotation: randomTilt())
            let fresh = addCard(color: palette[Int(rng.nextUnit() * Double(palette.count)) % palette.count], pose: target)
            let dropPlan = StopMotionSequences.drop(target: target, options: options, using: &rng)
            StopMotion.apply(dropPlan, to: fresh.layer)
            logSequence("drop (respawn)", dropPlan, "card\(fresh.id)")
        }
    }

    // MARK: Realtime, Reduce Motion, Idle-Check

    private func realtimeReveal() {
        let animated = RealtimeMotion.reveal(content: content, boardSize: Self.boardSize, reduceMotion: prefs.effective)
        log("seq=realtime-reveal path=RealtimeMotion duration=\(animated ? "0.200" : "0.000")s animated=\(animated) reduceMotion=\(prefs.effective)")
    }

    private func toggleReduceMotion() {
        prefs.manual.toggle()
        log("reduce motion manual=\(prefs.manual) system=\(prefs.system) effective=\(prefs.effective)")
    }

    private func idleCheck() {
        var keys: [String] = []
        collectAnimations(in: view.layer, into: &keys)
        log("idle check: \(keys.count) active animation(s) on all layers \(keys.isEmpty ? "" : keys.joined(separator: ", "))")
        log("idle check: expected 0 about 0.5 s after the last sequence. Then CPU/Idle Wake Ups via Activity Monitor or `top -pid \(ProcessInfo.processInfo.processIdentifier)`.")
    }

    private func collectAnimations(in layer: CALayer?, into keys: inout [String]) {
        guard let layer else { return }
        // ⚠️ VERIFIZIEREN: animationKeys() liefert nur Animationen, die noch am Layer hängen (nach Ablauf mit isRemovedOnCompletion == true entfernt).
        for key in layer.animationKeys() ?? [] { keys.append("\(layer.name ?? "layer"):\(key)") }
        collectAnimations(in: layer.mask, into: &keys)
        for sub in layer.sublayers ?? [] { collectAnimations(in: sub, into: &keys) }
    }

    // MARK: Logging

    private func logSequence(_ name: String, _ plan: StopMotionPlan, _ target: String) {
        log("seq=\(name) path=StopMotion target=\(target) frames=\(plan.frames.count) duration=\(String(format: "%.3f", plan.duration))s animated=\(plan.isAnimated) reduceMotion=\(prefs.effective) (system=\(prefs.system) manual=\(prefs.manual))")
    }

    private func log(_ message: String) {
        let t = ProcessInfo.processInfo.systemUptime - startUptime
        print(String(format: "[%8.3f] ", t) + message)
        fflush(stdout)
    }
}
