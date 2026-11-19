// PinPhoto — pin photos on top of every window. Menu bar app (📌).
// Build: ./build.sh   (needs Xcode command line tools)

import Cocoa
import UniformTypeIdentifiers

// MARK: - Panel that floats above everything

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Image view with pinch / scroll / right-click handling

final class PinView: NSImageView {
    weak var owner: PinController?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Click a photo in the stack to bring it to the front
    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        super.mouseDown(with: event)
    }

    override func magnify(with event: NSEvent) {
        owner?.scale(by: 1 + event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            owner?.adjustOpacity(by: event.scrollingDeltaY * 0.01)
        } else {
            owner?.scale(by: 1 + event.scrollingDeltaY * 0.01)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.makeMenu() }

    // Drop more images onto a pinned photo to pin them too
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (NSApp.delegate as? AppDelegate)?.pin(from: sender.draggingPasteboard) ?? false
    }
}

// MARK: - The 📌 that holds the stack together: drag it to move every photo at once

final class PinHandle: NSTextField {
    var onDrag: ((CGFloat, CGFloat) -> Void)?

    convenience init() {
        self.init(labelWithString: "📌")
        font = .systemFont(ofSize: 22)
        alignment = .center
        frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowBlurRadius = 3
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.orderFrontRegardless() }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX, -event.deltaY)   // AppKit screen deltaY points down
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// MARK: - Transparent drop target laid over the menu bar button

final class DropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (NSApp.delegate as? AppDelegate)?.pin(from: sender.draggingPasteboard) ?? false
    }
    // Let clicks fall through so the menu still opens
    override func mouseDown(with event: NSEvent) {
        if let button = superview as? NSButton { button.mouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override var mouseDownCanMoveWindow: Bool { !(superview is NSButton) }
}

// MARK: - Small floating "drop photos here" window

func makeDropZone() -> NSPanel {
    let panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 120),
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

    let zone = DropView(frame: NSRect(x: 0, y: 0, width: 150, height: 120))
    zone.wantsLayer = true
    zone.layer?.cornerRadius = 14
    zone.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    zone.layer?.borderWidth = 2
    zone.layer?.borderColor = NSColor.systemOrange.cgColor

    let label = NSTextField(labelWithString: "📌\nDrop photos\nto pin")
    label.alignment = .center
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.maximumNumberOfLines = 3
    label.frame = zone.bounds.insetBy(dx: 8, dy: 14)
    label.autoresizingMask = [.width, .height]
    zone.addSubview(label)

    panel.contentView = zone
    if let screen = NSScreen.main?.visibleFrame {
        panel.setFrameOrigin(NSPoint(x: screen.maxX - 170, y: screen.minY + 20))
    }
    return panel
}

// MARK: - One pinned photo

final class PinController: NSObject, NSWindowDelegate {
    let panel: PinPanel
    let imageView = PinView()
    var onClose: ((PinController) -> Void)?

    init(image: NSImage, stackIndex: Int = 0) {
        var size = image.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 300, height: 300) }
        let maxSide: CGFloat = 420
        let s = min(1, maxSide / max(size.width, size.height))
        size = NSSize(width: size.width * s, height: size.height * s)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        // Stack: each new photo lands offset down-right from the last, newest on top
        let step = CGFloat(stackIndex % 12) * 30
        let origin = NSPoint(x: screen.midX - size.width / 2 - 100 + step,
                             y: screen.midY - size.height / 2 + 100 - step)

        panel = PinPanel(contentRect: NSRect(origin: origin, size: size),
                         styleMask: [.borderless, .resizable, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.aspectRatio = size
        panel.minSize = NSSize(width: 60, height: 60)
        panel.delegate = self

        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.owner = self
        imageView.registerForDraggedTypes([.fileURL, .tiff, .png])
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        panel.contentView = imageView

        panel.orderFrontRegardless()
    }

    func scale(by factor: CGFloat) {
        let old = panel.frame
        let w = min(4000, max(60, old.width * factor))
        let h = w * old.height / old.width
        panel.setFrame(NSRect(x: old.midX - w / 2, y: old.midY - h / 2, width: w, height: h),
                       display: true)
    }

    func adjustOpacity(by delta: CGFloat) {
        panel.alphaValue = min(1, max(0.1, panel.alphaValue + delta))
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
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

    @objc func resetSize() {
        guard let img = imageView.image else { return }
        let f = panel.frame
        let s = min(1, 420 / max(img.size.width, img.size.height))
        let w = img.size.width * s
        let h = img.size.height * s
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
    }

    @objc func closePin() { panel.close() }

    func windowWillClose(_ notification: Notification) { onClose?(self) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pins: [PinController] = []
    var statusItem: NSStatusItem!
    var clickThrough = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let ct = item("Click-Through Mode", #selector(toggleClickThrough(_:)), "t")
        menu.addItem(ct)
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

    func pin(_ image: NSImage) {
        let pc = PinController(image: image, stackIndex: pins.count)
        pc.panel.ignoresMouseEvents = clickThrough
        pc.onClose = { [weak self] c in
            guard let self = self else { return }
            self.pins.removeAll { $0 === c }
            if self.pins.isEmpty { self.stackPin?.orderOut(nil) }
        }
        pins.append(pc)
        showStackPin(over: pins[0].panel.frame)
    }

    // MARK: the one 📌 holding the whole stack together

    var stackPin: PinPanel?

    func showStackPin(over frame: NSRect) {
        if stackPin == nil {
            let size: CGFloat = 36
            let p = PinPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isReleasedWhenClosed = false

            let handle = PinHandle()
            handle.font = .systemFont(ofSize: 28)
            handle.frame = NSRect(x: 0, y: 0, width: size, height: size)
            handle.onDrag = { [weak self] dx, dy in self?.moveStack(dx, dy) }
            p.contentView = handle
            stackPin = p
        }
        // Place the pin at the top centre of the first photo, only when it newly appears
        if stackPin?.isVisible != true {
            stackPin?.setFrameOrigin(NSPoint(x: frame.midX - 18, y: frame.maxY - 26))
        }
        stackPin?.orderFrontRegardless()
    }

    func moveStack(_ dx: CGFloat, _ dy: CGFloat) {
        for w in pins.map({ $0.panel }) + (stackPin.map { [$0] } ?? []) {
            var o = w.frame.origin
            o.x += dx
            o.y += dy
            w.setFrameOrigin(o)
        }
    }

    func pin(url: URL) {
        if let img = NSImage(contentsOf: url) { pin(img) }
    }

    /// Pins whatever images are on a drag/clipboard pasteboard (files like .jpg/.png, or raw image data).
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

    var dropZone: NSPanel?

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
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let first = imgs.first {
            pin(first)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.forEach(pin(url:))
        } else {
            NSSound.beep()
        }
    }

    @objc func toggleClickThrough(_ sender: NSMenuItem) {
        clickThrough.toggle()
        sender.state = clickThrough ? .on : .off
        pins.forEach { $0.panel.ignoresMouseEvents = clickThrough }
    }

    @objc func unpinAll() { pins.map { $0 }.forEach { $0.panel.close() } }

    // "Open With" / drop onto the app icon
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(pin(url:)) }
}
