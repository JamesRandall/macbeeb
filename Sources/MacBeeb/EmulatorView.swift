import AppKit
import BeebCore
import BeebHost
import MetalKit
import SwiftUI

/// The BBC's screen. Takes keyboard focus and sends keys to the machine.
final class EmulatorNSView: MTKView {
    var host: EmulatorHost?
    var renderer: Renderer?
    /// Called with the TV pixel under the mouse (nil when it leaves).
    var onHover: ((Int, Int)?) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover(tvPixel(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }

    /// The TV pixel at a point in the view, allowing for the letterboxing.
    func tvPixel(at point: CGPoint) -> (Int, Int)? {
        let size = bounds.size
        var width = size.width, height = size.width / Renderer.aspect
        if height > size.height {
            height = size.height
            width = height * Renderer.aspect
        }
        let u = (point.x - (size.width - width) / 2) / width
        let v = 1 - (point.y - (size.height - height) / 2) / height
        guard (0..<1).contains(u), (0..<1).contains(v) else { return nil }
        return (Int(u * CGFloat(EmulatorHost.Frame.width)), Int(v * CGFloat(EmulatorHost.Frame.height)))
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTranslator()
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        translator.reset()
        host?.send(.releaseAllKeys)
    }

    /// Rebuilt when the settings change (see `updateTranslator`).
    private var translator = KeyboardSettings.shared.translator

    /// Picks up keyboard settings changes; keys held across a change
    /// still release properly.
    func updateTranslator() {
        let settings = KeyboardSettings.shared
        withObservationTracking {
            translator.mode = settings.mode
            translator.customKeys = settings.translator.customKeys
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateTranslator() }
        }
    }

    private func perform(_ actions: [KeyboardTranslator.Action]) {
        for action in actions {
            switch action {
            case .key(let key, let down):
                host?.send(.key(key, down: down))
            case .tapCapsLock:
                host?.send(.key(.capsLock, down: true))
                let host = self.host
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    host?.send(.key(.capsLock, down: false))
                }
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // Command combinations belong to the menus.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        perform(translator.keyDown(keyCode: event.keyCode, characters: event.characters,
                                   modifiers: .init(event.modifierFlags), isRepeat: event.isARepeat))
    }

    override func keyUp(with event: NSEvent) {
        perform(translator.keyUp(keyCode: event.keyCode))
    }

    override func flagsChanged(with event: NSEvent) {
        perform(translator.flagsChanged(keyCode: event.keyCode, modifiers: .init(event.modifierFlags)))
    }
}

struct EmulatorView: NSViewRepresentable {
    let host: EmulatorHost
    let style: DisplayStyle
    /// Called with the renderer once it exists.
    var onRenderer: (Renderer) -> Void = { _ in }
    var onHover: ((Int, Int)?) -> Void = { _ in }

    func makeNSView(context: Context) -> EmulatorNSView {
        let device = MTLCreateSystemDefaultDevice()
        let view = EmulatorNSView(frame: .zero, device: device)
        view.host = host
        view.onHover = onHover
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        if let device {
            view.renderer = Renderer(device: device, pixelFormat: view.colorPixelFormat, host: host)
        }
        view.delegate = view.renderer
        if let renderer = view.renderer {
            renderer.style = style
            onRenderer(renderer)
        }
        return view
    }

    func updateNSView(_ view: EmulatorNSView, context: Context) {
        view.renderer?.style = style
    }
}
