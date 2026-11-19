// PinPhoto — one 📌 through a pile of photos, with a bit of physics.
//
// Paste this whole file into ContentView.swift (replacing everything in it).
// MyAppApp.swift stays as it was.

import Cocoa
import UniformTypeIdentifiers

// MARK: - Small vector helpers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (p: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: p.x * k, y: p.y * k) }
    func rotated(by t: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(t) - y * sin(t), y: x * sin(t) + y * cos(t))
    }
    var length: CGFloat { hypot(x, y) }
}

private func clamp(_ v: CGFloat, _ limit: CGFloat) -> CGFloat { max(-limit, min(limit, v)) }

// MARK: - Floating panel

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - One photo (a square transparent window; the photo is a rotated layer inside it)

final class PhotoView: NSView {
    weak var owner: PhotoController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Only the rotated photo itself is clickable, not the transparent corners of the window
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner = owner else { return nil }
        let p = convert(point, from: superview)
        return owner.contains(viewPoint: p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { owner?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(event) }

    override func magnify(with event: NSEvent) { owner?.scale(by: 1 + event.magnification) }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            owner?.adjustOpacity(by: event.scrollingDeltaY * 0.01)
        } else {
            owner?.scale(by: 1 + event.scrollingDeltaY * 0.01)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.bringToFront(nil)                // right-clicking a photo lifts it off the pile
        return owner?.makeMenu()
    }

    // Drop more images onto a photo to pin them too
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AppDelegate.shared?.pin(from: sender.draggingPasteboard) ?? false
    }
}

final class PhotoController: NSObject {
    let panel: PinPanel
    let view = PhotoView(frame: .zero)
    weak var host: AppDelegate?
    var onClose: ((PhotoController) -> Void)?

    // Geometry / physics state
    var size: CGSize                 // photo size in points
    let baseSize: CGSize
    var r0: CGPoint                  // photo centre relative to the pin when theta == 0
    var theta: CGFloat               // rotation around the pin (radians)
    var omega: CGFloat = 0           // angular velocity (rad/s)
    var isDragging = false
    var lastAngle: CGFloat = 0
    var lastEventTime: TimeInterval = 0
    /// How far a photo may lean against the pile. It tips and swings, but never turns over.
    let swingLimit: CGFloat = 55 * .pi / 180

    // Layers: frameLayer (rotates, has the shadow) > contentLayer (the image) > holeLayer (pin hole)
    let frameLayer = CALayer()
    let contentLayer = CALayer()
    let holeLayer = CALayer()

    init(image: NSImage, isFirst: Bool, host: AppDelegate) {
        self.host = host
        var s = image.size
        if s.width < 1 || s.height < 1 { s = CGSize(width: 300, height: 300) }
        let k = min(1, 420 / max(s.width, s.height))
        s = CGSize(width: s.width * k, height: s.height * k)
        size = s
        baseSize = s

        // The pin goes in along the top edge, so a photo hangs from it instead of being
        // skewered through the middle
        let topInset = min(12, s.height * 0.4)
        let hang = -(s.height / 2 - topInset)
        if isFirst {
            r0 = CGPoint(x: 0, y: hang)
            theta = 0
        } else {
            // Along the same top edge, a little off-centre, with a slight tilt
            r0 = CGPoint(x: CGFloat.random(in: -0.18...0.18) * s.width,
                         y: hang + CGFloat.random(in: -4...4))
            theta = CGFloat.random(in: -0.12...0.12)
        }

        panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                // the photo layer draws its own shadow
        panel.isReleasedWhenClosed = false

        view.owner = self
        view.wantsLayer = true
        panel.contentView = view

        let scale = NSScreen.main?.backingScaleFactor ?? 2

        frameLayer.backgroundColor = NSColor.white.cgColor
        frameLayer.cornerRadius = 6
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.45
        frameLayer.shadowRadius = 8
        frameLayer.shadowOffset = CGSize(width: 0, height: -3)

        contentLayer.cornerRadius = 6
        contentLayer.masksToBounds = true
        contentLayer.contentsGravity = .resize
        contentLayer.contentsScale = scale
        contentLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? image

        // The hole the pin goes through
        holeLayer.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        holeLayer.cornerRadius = 5
        holeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        holeLayer.borderWidth = 1
        holeLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        view.layer?.addSublayer(frameLayer)
        frameLayer.addSublayer(contentLayer)
        contentLayer.addSublayer(holeLayer)

        layout()
        panel.orderFrontRegardless()
    }

    /// Places the window and rotates the photo so it hangs from the pin.
    func layout() {
        let side = hypot(size.width, size.height) + 40
        let pin = host?.needlePoint ?? .zero
        let r = r0.rotated(by: theta)
        let c = pin + r
        let frame = NSRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        // A window can only sit on whole pixels, so the frame is as close as the screen
        // allows. Hang the photo off the pin as the window actually landed — otherwise the
        // hole slides off the needle as the photo swings.
        let origin = panel.frame.origin

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.bounds = CGRect(origin: .zero, size: size)
        frameLayer.position = CGPoint(x: pin.x - origin.x + r.x, y: pin.y - origin.y + r.y)
        frameLayer.setAffineTransform(CGAffineTransform(rotationAngle: theta))
        contentLayer.frame = frameLayer.bounds
        // The pin sits at (-r0) from the photo's centre, in the photo's own axes
        holeLayer.position = CGPoint(x: size.width / 2 - r0.x, y: size.height / 2 - r0.y)
        CATransaction.commit()
    }

    func contains(viewPoint p: CGPoint) -> Bool {
        // frameLayer.position is the photo's centre, wherever the window let us put it
        let q = (p - frameLayer.position).rotated(by: -theta)
        return abs(q.x) <= size.width / 2 && abs(q.y) <= size.height / 2
    }

    // MARK: physics

    /// `a` is the pin's acceleration in screen points/s². The photo feels the opposite
    /// force at its centre, which twists it around the pin.
    func step(dt: CGFloat, pinAccel a: CGPoint) {
        guard !isDragging else { return }
        let r = r0.rotated(by: theta)
        let torque = -(r.x * a.y - r.y * a.x)
        let inertia = (size.width * size.width + size.height * size.height) / 12 + (r.x * r.x + r.y * r.y)
        omega += (torque / inertia) * dt
        omega *= exp(-2.5 * dt)                  // friction against the pile
        omega = clamp(omega, 15)
        if abs(omega) < 0.002 { omega = 0 }
        theta += omega * dt
        if theta > swingLimit { theta = swingLimit; omega = 0 }
        if theta < -swingLimit { theta = -swingLimit; omega = 0 }
    }

    // MARK: mouse — grab a photo and swing it around the pin

    private func angleToPin() -> CGFloat {
        let m = NSEvent.mouseLocation
        let p = host?.pinPoint ?? .zero
        return atan2(m.y - p.y, m.x - p.x)
    }

    /// Lifts this photo above the others; the pin stays on top of everything.
    @objc func bringToFront(_ sender: Any?) {
        panel.orderFrontRegardless()
        host?.bringPinToFront()
    }

    func mouseDown(_ e: NSEvent) {
        bringToFront(nil)
        isDragging = true
        omega = 0
        lastAngle = angleToPin()
        lastEventTime = e.timestamp
    }

    func mouseDragged(_ e: NSEvent) {
        let a = angleToPin()
        var d = a - lastAngle
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        theta += d
        let dt = max(e.timestamp - lastEventTime, 1.0 / 240)
        omega = omega * 0.5 + CGFloat(Double(d) / dt) * 0.5
        lastAngle = a
        lastEventTime = e.timestamp
        if theta > swingLimit { theta = swingLimit; omega = 0 }
        if theta < -swingLimit { theta = -swingLimit; omega = 0 }
        layout()
    }

    func mouseUp(_ e: NSEvent) {
        isDragging = false
        if e.timestamp - lastEventTime > 0.1 { omega = 0 }   // held still → no flick
        omega = clamp(omega, 15)
    }

    // MARK: size / opacity / menu

    func scale(by factor: CGFloat) {
        let newW = min(4000, max(60, size.width * factor))
        let k = newW / size.width
        size = CGSize(width: size.width * k, height: size.height * k)
        r0 = r0 * k
        layout()
    }

    func adjustOpacity(by delta: CGFloat) {
        panel.alphaValue = min(1, max(0.1, panel.alphaValue + delta))
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let front = NSMenuItem(title: "Bring to Front", action: #selector(bringToFront(_:)), keyEquivalent: "")
        front.target = self
        menu.addItem(front)
        menu.addItem(.separator())

        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(pct)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = Int((panel.alphaValue * 100).rounded()) == pct ? .on : .off
            sub.addItem(item)
        }
        opacity.submenu = sub
        menu.addItem(opacity)

        let reset = NSMenuItem(title: "Reset Size", action: #selector(resetSize), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        let close = NSMenuItem(title: "Unpin", action: #selector(closePin), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc func setOpacity(_ sender: NSMenuItem) { panel.alphaValue = CGFloat(sender.tag) / 100 }
    @objc func resetSize() { scale(by: baseSize.width / size.width) }
    @objc func closePin() { close() }

    func close() {
        panel.orderOut(nil)
        onClose?(self)
    }
}

// MARK: - The pushpin: needle goes into the photos, head sits on top

final class PinHeadView: NSView {
    var onDrag: ((CGFloat, CGFloat) -> Void)?

    // The needle tip is the view's centre (that's the point the photos hang from).
    private var tip: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var head: CGPoint { CGPoint(x: bounds.midX - 11, y: bounds.midY + 15) }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - head.x, p.y - head.y) <= 15 ? self : nil
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, -event.deltaY)    // AppKit screen deltaY points down
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: head.x - 15, y: head.y - 15, width: 30, height: 30), cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)      // clear panel: wipe the last needle before the next

        // Needle: silver, casting a short shadow onto the photo it goes into
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -3), blur: 3,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setStrokeColor(NSColor(white: 0.88, alpha: 1).cgColor)
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        ctx.move(to: head)
        ctx.addLine(to: tip)
        ctx.strokePath()
        ctx.restoreGState()

        // Head: soft shadow first…
        let headRect = NSRect(x: head.x - 11, y: head.y - 11, width: 22, height: 22)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 4, height: -7), blur: 7,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: headRect).fill()
        ctx.restoreGState()

        // …then the glossy red ball and its highlight
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.45, alpha: 1),
            ending: NSColor(calibratedRed: 0.62, green: 0.04, blue: 0.08, alpha: 1))
        gradient?.draw(in: NSBezierPath(ovalIn: headRect), relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(ovalIn: NSRect(x: head.x - 6.5, y: head.y + 2, width: 6, height: 4)).fill()
    }
}

// MARK: - Transparent drop target laid over the menu bar button / used in the drop zone

class DropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        AppDelegate.shared?.pin(from: sender.draggingPasteboard) ?? false
    }

    // Let clicks fall through so the menu still opens
    override func mouseDown(with event: NSEvent) {
        if let button = superview as? NSButton { button.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override var mouseDownCanMoveWindow: Bool { !(superview is NSButton) }
}

// MARK: - The drop zone: a small pile of photos with the pin in at the top of the pile

final class DropZoneView: DropView {
    /// The top photo of the pile.
    private var card: CGRect {
        let w: CGFloat = 104, h: CGFloat = 64
        return CGRect(x: bounds.midX - w / 2, y: 42, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // The plate the target sits on
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        plate.fill()
        NSColor.systemOrange.setStroke()
        plate.lineWidth = 2
        plate.stroke()

        // The pile, oldest photo furthest back
        drawCard(card.offsetBy(dx: -4, dy: 3), angle: -6, in: ctx)
        drawCard(card.offsetBy(dx: 3, dy: -1), angle: 3.5, in: ctx)

        // The pin goes into the top edge of the top photo — at the top of the pile,
        // never in the middle of it
        let tip = CGPoint(x: card.midX, y: card.maxY - 3)
        let head = CGPoint(x: tip.x, y: 130)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -2), blur: 3,
                      color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setStrokeColor(NSColor(white: 0.86, alpha: 1).cgColor)
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        ctx.move(to: head)
        ctx.addLine(to: tip)
        ctx.strokePath()
        ctx.restoreGState()

        drawCard(card, angle: 0, in: ctx)          // the top photo hides the needle below its edge
        drawHead(at: head, in: ctx)

        // Caption, under the pile
        let caption = NSAttributedString(string: "Drop photos to pin", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let s = caption.size()
        caption.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: 12))
    }

    private func drawCard(_ rect: CGRect, angle: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: angle * .pi / 180)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        ctx.setShadow(offset: .zero, blur: 0, color: NSColor.clear.cgColor)
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        edge.lineWidth = 0.5
        edge.stroke()
        ctx.restoreGState()
    }

    private func drawHead(at head: CGPoint, in ctx: CGContext) {
        let ball = NSRect(x: head.x - 10, y: head.y - 10, width: 20, height: 20)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -4), blur: 5,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(calibratedRed: 0.8, green: 0.1, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: ball).fill()
        ctx.restoreGState()

        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.45, alpha: 1),
            ending: NSColor(calibratedRed: 0.62, green: 0.04, blue: 0.08, alpha: 1))
        gradient?.draw(in: NSBezierPath(ovalIn: ball), relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(ovalIn: NSRect(x: head.x - 6, y: head.y + 1.5, width: 5.5, height: 3.8)).fill()
    }
}

func makeDropZone() -> NSPanel {
    let size = NSSize(width: 168, height: 156)
    let panel = PinPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true

    let zone = DropZoneView(frame: NSRect(origin: .zero, size: size))
    zone.autoresizingMask = [.width, .height]
    panel.contentView = zone

    if let screen = NSScreen.main?.visibleFrame {
        panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
    }
    return panel
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    // With SwiftUI's @NSApplicationDelegateAdaptor, NSApp.delegate is SwiftUI's own wrapper,
    // so `NSApp.delegate as? AppDelegate` is nil. Use this instead.
    static weak var shared: AppDelegate?

    /// One level above the photos, so a photo brought forward can never cover the pin.
    static let pinLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    var pins: [PhotoController] = []
    var statusItem: NSStatusItem!
    var clickThrough = false
    var dropZone: NSPanel?

    // The one pin
    var pinPoint = CGPoint.zero          // where the needle goes through
    var pinTarget = CGPoint.zero         // where the user is dragging it to
    var pinVel = CGPoint.zero
    var pinAccel = CGPoint.zero
    var stackPin: PinPanel?
    var timer: Timer?

    /// Where the needle tip really is. Its window can only sit on whole pixels, so the
    /// photos hang from this instead of from `pinPoint`, and the hole stays on the needle.
    var needlePoint: CGPoint {
        guard let origin = stackPin?.frame.origin else { return pinPoint }
        return CGPoint(x: origin.x + 40, y: origin.y + 40)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "📌"
        if let button = statusItem.button {
            let drop = DropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }

        let menu = NSMenu()
        menu.addItem(item("Pin Photo…", #selector(openPhotos), "o"))
        menu.addItem(item("Pin from Clipboard", #selector(pinClipboard), "v"))
        menu.addItem(item("Show Drop Zone", #selector(toggleDropZone(_:)), "d"))
        menu.addItem(.separator())
        menu.addItem(item("Click-Through Mode", #selector(toggleClickThrough(_:)), "t"))
        menu.addItem(item("Unpin All", #selector(unpinAll), "u"))
        menu.addItem(.separator())
        menu.addItem(item("Quit PinPhoto", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    // MARK: pinning

    func pin(_ image: NSImage) {
        let isFirst = pins.isEmpty
        if isFirst {
            let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            pinPoint = CGPoint(x: area.midX, y: area.midY + 60)
            pinTarget = pinPoint
            pinVel = .zero
            pinAccel = .zero
            showStackPin()
            startPhysics()
        }
        let pc = PhotoController(image: image, isFirst: isFirst, host: self)
        pc.panel.ignoresMouseEvents = clickThrough
        pc.onClose = { [weak self] c in
            guard let self = self else { return }
            self.pins.removeAll { $0 === c }
            if self.pins.isEmpty {
                self.stackPin?.orderOut(nil)
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        pins.append(pc)
        bringPinToFront()
    }

    func pin(url: URL) {
        if let img = NSImage(contentsOf: url) { pin(img) }
    }

    /// Pins whatever images are on a drag/clipboard pasteboard (jpg/png files, or raw image data).
    @discardableResult
    func pin(from pb: NSPasteboard) -> Bool {
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true,
                                            .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
        if !urls.isEmpty {
            urls.forEach(pin(url:))
            return true
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            imgs.forEach(pin(_:))
            return true
        }
        return false
    }

    func bringPinToFront() {
        guard let pin = stackPin else { return }
        pin.level = Self.pinLevel                  // in case anything reset it to `.floating`
        pin.orderFrontRegardless()
        pin.contentView?.needsDisplay = true     // a clear panel must not come back blank
    }

    // MARK: the pin window

    func showStackPin() {
        if stackPin == nil {
            let side: CGFloat = 80
            let p = PinPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            p.isFloatingPanel = true        // this resets the level, so set the level after it
            p.level = Self.pinLevel
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isReleasedWhenClosed = false

            let head = PinHeadView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            head.onDrag = { [weak self] dx, dy in
                guard let self = self else { return }
                self.pinTarget = self.onScreen(CGPoint(x: self.pinTarget.x + dx,
                                                       y: self.pinTarget.y + dy))
            }
            p.contentView = head
            stackPin = p
        }
        placePinWindow()
        bringPinToFront()
    }

    private func placePinWindow() {
        stackPin?.setFrameOrigin(NSPoint(x: pinPoint.x - 40, y: pinPoint.y - 40))
    }

    /// Keeps the pin on a screen. Its head sits 15 pt above the needle, so a pin dragged
    /// past the edge had no visible part left to grab — it was simply gone.
    private func onScreen(_ p: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return p }
        return CGPoint(x: min(max(p.x, visible.minX + 30), visible.maxX - 30),
                       y: min(max(p.y, visible.minY + 30), visible.maxY - 30))
    }

    // MARK: physics loop

    func startPhysics() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let dt: CGFloat = 1.0 / 60.0

        // The pin follows the cursor with a little weight, which also gives us a smooth acceleration
        let old = pinPoint
        pinPoint = CGPoint(x: pinPoint.x + (pinTarget.x - pinPoint.x) * 0.45,
                           y: pinPoint.y + (pinTarget.y - pinPoint.y) * 0.45)
        let v = (pinPoint - old) * (1 / dt)
        let rawA = (v - pinVel) * (1 / dt)
        pinVel = v
        pinAccel = pinAccel * 0.5 + rawA * 0.5
        pinAccel = CGPoint(x: clamp(pinAccel.x, 20000), y: clamp(pinAccel.y, 20000))

        let moved = (pinPoint - old).length > 0.001
        if moved { placePinWindow() }        // move the pin first, then hang the photos off it
        for p in pins {
            let before = p.omega
            p.step(dt: dt, pinAccel: pinAccel)
            if moved || before != 0 || p.omega != 0 { p.layout() }
        }
    }

    // MARK: menu actions

    @objc func toggleDropZone(_ sender: NSMenuItem) {
        if let zone = dropZone, zone.isVisible {
            zone.orderOut(nil)
            sender.state = .off
        } else {
            if dropZone == nil { dropZone = makeDropZone() }
            dropZone?.orderFrontRegardless()
            sender.state = .on
        }
    }

    @objc func openPhotos() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach(pin(url:)) }
    }

    @objc func pinClipboard() {
        if !pin(from: NSPasteboard.general) { NSSound.beep() }
    }

    @objc func toggleClickThrough(_ sender: NSMenuItem) {
        clickThrough.toggle()
        sender.state = clickThrough ? .on : .off
        pins.forEach { $0.panel.ignoresMouseEvents = clickThrough }
    }

    @objc func unpinAll() { pins.map { $0 }.forEach { $0.close() } }

    // "Open With" / drop onto the app icon
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(pin(url:)) }
}
