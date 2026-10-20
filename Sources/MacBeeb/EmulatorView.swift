import AppKit
import BeebCore
import BeebHost
import MetalKit
import SwiftUI

/// The BBC's screen. Takes keyboard focus and sends keys to the machine.
final class EmulatorNSView: MTKView {
    var host: EmulatorHost?
    var renderer: Renderer?
    private var capsLockOn = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        host?.send(.releaseAllKeys)
    }

    override func keyDown(with event: NSEvent) {
        // Command combinations belong to the menus.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if let key = KeyMap.physical[event.keyCode] {
            host?.send(.key(key, down: true))
        }
    }

    override func keyUp(with event: NSEvent) {
        if let key = KeyMap.physical[event.keyCode] {
            host?.send(.key(key, down: false))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == KeyMap.capsLock {
            // macOS only reports Caps Lock toggling, so tap the BBC key
            // whenever the Mac's state changes.
            let on = event.modifierFlags.contains(.capsLock)
            if on != capsLockOn {
                capsLockOn = on
                host?.send(.key(.capsLock, down: true))
                let host = self.host
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    host?.send(.key(.capsLock, down: false))
                }
            }
            return
        }
        guard let key = KeyMap.physical[event.keyCode] else { return }
        let flag: NSEvent.ModifierFlags = switch event.keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        default: .option
        }
        host?.send(.key(key, down: event.modifierFlags.contains(flag)))
    }
}

struct EmulatorView: NSViewRepresentable {
    let host: EmulatorHost
    let style: DisplayStyle
    /// Called with the renderer once it exists.
    var onRenderer: (Renderer) -> Void = { _ in }

    func makeNSView(context: Context) -> EmulatorNSView {
        let device = MTLCreateSystemDefaultDevice()
        let view = EmulatorNSView(frame: .zero, device: device)
        view.host = host
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
