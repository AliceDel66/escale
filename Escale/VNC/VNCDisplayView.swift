import AppKit
import SwiftUI
import EscaleCore

/// Vue d'affichage du bureau distant : dessine le framebuffer (mise à l'échelle), traduit clavier et souris en
/// événements RFB. Le moteur est confiné à cette vue et à `VNCSession` ; rien d'autre ne touche au protocole.
@MainActor
final class VNCDisplayView: NSView {
    weak var session: VNCSession?
    var scaling: VNCScaling = .fit { didSet { if scaling != oldValue { needsLayout = true; enclosingScrollView?.needsLayout = true; needsDisplay = true } } }

    /// Lissage demandé par l'utilisateur : force l'interpolation linéaire même en agrandissement.
    var smoothing = false { didSet { if smoothing != oldValue { needsDisplay = true } } }

    private var image: CGImage?
    private var imageSize = CGSize.zero
    private var redrawScheduled = false
    private var cursor: NSCursor?
    private var cursorHidden = false
    private(set) var framesDrawn = 0

    // Entrée
    private var pressed: [UInt16: UInt32] = [:]
    private var buttons: UInt8 = 0
    private var scrollAccumulator: CGFloat = 0
    private var horizontalAccumulator: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var lastPoint: (x: Int, y: Int)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setAccessibilityLabel(String(localized: "Bureau distant"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    // MARK: Géométrie

    /// Rectangle (en coordonnées de la vue) occupé par l'image distante.
    func imageRect() -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        switch scaling {
        case .actual:
            return CGRect(x: max(0, (bounds.width - imageSize.width) / 2), y: max(0, (bounds.height - imageSize.height) / 2),
                          width: imageSize.width, height: imageSize.height)
        case .fit:
            let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let w = imageSize.width * s, h = imageSize.height * s
            return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        }
    }

    /// Point de la vue → pixel distant (borné à l'écran).
    func remotePoint(from p: CGPoint) -> (x: Int, y: Int) {
        let r = imageRect()
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let x = (p.x - r.minX) * imageSize.width / r.width, y = (p.y - r.minY) * imageSize.height / r.height
        return (Int(max(0, min(imageSize.width - 1, x.rounded(.down)))), Int(max(0, min(imageSize.height - 1, y.rounded(.down)))))
    }

    /// Point de la vue d'un pixel distant (centre du pixel) : sert à l'auto-test.
    func viewPoint(forRemoteX x: Int, y: Int) -> CGPoint {
        let r = imageRect()
        guard imageSize.width > 0 else { return .zero }
        return CGPoint(x: r.minX + (CGFloat(x) + 0.5) * r.width / imageSize.width, y: r.minY + (CGFloat(y) + 0.5) * r.height / imageSize.height)
    }

    override func layout() {
        super.layout()
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.contentSize
        let target: CGSize
        switch scaling {
        case .fit: target = visible
        case .actual: target = CGSize(width: max(visible.width, imageSize.width), height: max(visible.height, imageSize.height))
        }
        scroll.hasHorizontalScroller = scaling == .actual
        scroll.hasVerticalScroller = scaling == .actual
        if frame.size != target { setFrameSize(target) }
    }

    // MARK: Image

    func sessionDidConnect() {
        remoteSizeChanged()
        window?.makeFirstResponder(self)
    }

    func framebufferChanged() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        // Au plus ~30 images par seconde : les rafales de rectangles sont fusionnées.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    func remoteSizeChanged() {
        redraw()
        needsLayout = true
        enclosingScrollView?.needsLayout = true
    }

    /// Copie le framebuffer dans une image et redessine.
    func redraw() {
        redrawScheduled = false
        guard let fb = session?.framebuffer else { return }
        let snap = fb.snapshot()
        guard snap.width > 0, snap.height > 0 else { return }
        let data = Data(snap.bgra)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        image = CGImage(width: snap.width, height: snap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: snap.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        let size = CGSize(width: snap.width, height: snap.height)
        if size != imageSize { imageSize = size; needsLayout = true; enclosingScrollView?.needsLayout = true }
        needsDisplay = true
    }

    /// Image courante (auto-test : pixels réellement affichés).
    var currentImage: CGImage? { image }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect()
        ctx.saveGState()
        // La vue est inversée (y vers le bas) : on remet l'image à l'endroit.
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = interpolationQuality
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
        framesDrawn += 1
    }

    /// Échelle réelle en pixels de l'écran par pixel distant (Retina : `backingScaleFactor` points → pixels).
    var devicePixelsPerRemotePixel: CGFloat {
        let r = imageRect()
        guard imageSize.width > 0 else { return 1 }
        return r.width / imageSize.width * (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    /// Qualité d'interpolation : plus proche voisin à partir de ×2 ou pour une échelle entière (pixels nets, comme un
    /// visualiseur VNC), linéaire en réduction et pour les échelles fractionnaires, linéaire partout si « Lissage ».
    var interpolationQuality: CGInterpolationQuality {
        Self.interpolationQuality(scale: devicePixelsPerRemotePixel, smoothing: smoothing)
    }

    nonisolated static func interpolationQuality(scale: CGFloat, smoothing: Bool) -> CGInterpolationQuality {
        if smoothing || scale < 1 { return .high }
        if scale >= 2 || abs(scale - scale.rounded()) < 0.001 { return .none }
        return .high
    }

    // MARK: Curseur

    func setRemoteCursor(_ c: RFBCursor?) {
        guard let c else { cursor = nil; cursorHidden = true; window?.invalidateCursorRects(for: self); return }
        cursorHidden = false
        let data = Data(c.bgra)
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        if let provider = CGDataProvider(data: data as CFData),
           let cg = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent) {
            let ns = NSImage(cgImage: cg, size: NSSize(width: c.width, height: c.height))
            cursor = NSCursor(image: ns, hotSpot: NSPoint(x: c.hotspotX, y: c.hotspotY))
        } else { cursor = nil }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if let cursor { addCursorRect(bounds, cursor: cursor) }
        else if cursorHidden { addCursorRect(bounds, cursor: Self.invisibleCursor) }
    }

    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    // MARK: Fenêtre et suivi de la souris

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus), name: NSWindow.didResignKeyNotification, object: window)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { window.makeFirstResponder(self) } }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func resignFirstResponder() -> Bool { releaseAll(); return super.resignFirstResponder() }
    @objc private func windowLostFocus() { releaseAll() }

    /// Relâche touches et boutons enfoncés (perte du focus) : rien ne reste « collé » côté serveur.
    func releaseAll() {
        for (_, sym) in pressed { session?.sendKey(sym, down: false) }
        pressed.removeAll()
        if buttons != 0, let s = session, let p = lastPoint { s.sendPointer(x: p.x, y: p.y, buttons: 0) }
        buttons = 0
    }

    // MARK: Clavier

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    private func key(_ event: NSEvent, down: Bool) {
        guard let session else { return }
        let code = event.keyCode
        if !down {
            if let sym = pressed.removeValue(forKey: code) { session.sendKey(sym, down: false) }
            return
        }
        let flags = event.modifierFlags
        let ctrlCmd = flags.contains(.control) || flags.contains(.command)
        guard let sym = RFBKeysym.keysym(keyCode: code, characters: event.characters, base: event.charactersIgnoringModifiers,
                                         controlOrCommand: ctrlCmd) else { return }
        // Un caractère composé avec ⌥ (« { » sur AZERTY) : le serveur ne doit pas le voir précédé d'un Alt enfoncé.
        let composed = flags.contains(.option) && !ctrlCmd && event.characters != event.charactersIgnoringModifiers
        let alts: [UInt32] = composed ? [UInt16(58), 61].compactMap { pressed[$0] } : []
        for a in alts { session.sendKey(a, down: false) }
        pressed[code] = sym
        session.sendKey(sym, down: true)
        for a in alts { session.sendKey(a, down: true) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let session, let sym = RFBKeysym.modifierKeys[event.keyCode] else { return }
        let code = event.keyCode
        if code == 57 { // Verr. Maj : bascule, envoyée en appui + relâchement
            session.sendKey(sym, down: true); session.sendKey(sym, down: false)
            return
        }
        let flag: NSEvent.ModifierFlags
        switch code {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        default: flag = .command
        }
        if pressed[code] != nil || !event.modifierFlags.contains(flag) {
            if pressed.removeValue(forKey: code) != nil { session.sendKey(sym, down: false) }
        } else {
            pressed[code] = sym
            session.sendKey(sym, down: true)
        }
    }

    // MARK: Souris

    private func pointer(_ event: NSEvent) {
        let p = remotePoint(from: convert(event.locationInWindow, from: nil))
        lastPoint = p
        session?.sendPointer(x: p.x, y: p.y, buttons: buttons)
    }

    private func setButton(_ bit: UInt8, _ on: Bool, _ event: NSEvent) {
        if on { buttons |= bit } else { buttons &= ~bit }
        pointer(event)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); setButton(1, true, event) }
    override func mouseUp(with event: NSEvent) { setButton(1, false, event) }
    override func rightMouseDown(with event: NSEvent) { setButton(4, true, event) }
    override func rightMouseUp(with event: NSEvent) { setButton(4, false, event) }
    override func otherMouseDown(with event: NSEvent) { setButton(2, true, event) }
    override func otherMouseUp(with event: NSEvent) { setButton(2, false, event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    /// Molette : boutons 4 (haut) et 5 (bas) du protocole, un cran par tranche de défilement ; horizontale : 6 et 7.
    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        let p = remotePoint(from: convert(event.locationInWindow, from: nil))
        lastPoint = p
        func notches(_ delta: CGFloat, up: UInt8, down: UInt8, acc: inout CGFloat) {
            acc += delta
            while abs(acc) >= step {
                let bit = acc > 0 ? up : down
                acc += acc > 0 ? -step : step
                session?.sendPointer(x: p.x, y: p.y, buttons: buttons | bit)
                session?.sendPointer(x: p.x, y: p.y, buttons: buttons)
            }
        }
        notches(event.scrollingDeltaY, up: 8, down: 16, acc: &scrollAccumulator)
        notches(event.scrollingDeltaX, up: 32, down: 64, acc: &horizontalAccumulator)
    }
}

/// Conteneur défilant (mode 100 %) autour de la vue d'affichage.
@MainActor
final class VNCScrollView: NSScrollView {
    let display = VNCDisplayView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        documentView = display
        drawsBackground = true
        backgroundColor = .black
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    override func layout() {
        super.layout()
        display.needsLayout = true
        display.layout()
    }
}

struct VNCDisplayRepresentable: NSViewRepresentable {
    let session: VNCSession
    let scaling: VNCScaling
    let smoothing: Bool

    func makeNSView(context: Context) -> VNCScrollView {
        let v = VNCScrollView(frame: .zero)
        v.display.session = session
        v.display.scaling = scaling
        v.display.smoothing = smoothing
        session.display = v.display
        return v
    }

    func updateNSView(_ v: VNCScrollView, context: Context) {
        v.display.session = session
        v.display.scaling = scaling
        v.display.smoothing = smoothing
        session.display = v.display
        v.needsLayout = true
    }
}
