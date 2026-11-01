// ForceMiddleClick — turns a trackpad force click into a middle (scroll-wheel) click.
//
// A left mouse-down is held back for a moment. If the press reaches pressure
// stage 2 (force click) before it is released, moved, or times out, we emit a
// middle-button down/up instead. Otherwise the held mouse-down is replayed and
// everything behaves as normal.

import Cocoa
import ServiceManagement

private let kTag: Int64 = 0x464D_4331           // marks events we post, so the tap ignores them
private let kHoldDelay: TimeInterval = 0.4      // how long to wait for a force click
private let kDragSlop: CGFloat = 4              // movement (pt) that counts as a drag
private let kTypeGesture: UInt32 = 29           // trackpad gestures; pressure arrives wrapped in these
private let kTypeQuickLook: UInt32 = 33         // NSEvent.EventType.quickLook
private let kTypePressure: UInt32 = 34          // NSEvent.EventType.pressure

final class Clicker {
    private enum State { case idle, pending, middle, passthrough }

    private var state = State.idle
    private var heldDown: CGEvent?
    private var timer: Timer?
    private var tap: CFMachPort?
    private var lastStage = 0
    private let debug = ProcessInfo.processInfo.environment["FMC_DEBUG"] != nil

    var isRunning: Bool { tap != nil }

    var enabled = true {
        didSet {
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
        }
    }

    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventMask(kTypeGesture)) |
            (1 << CGEventMask(kTypeQuickLook)) |
            (1 << CGEventMask(kTypePressure))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                Unmanaged<Clicker>.fromOpaque(refcon!).takeUnretainedValue()
                    .handle(proxy, type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: enabled)
        return true
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let tap, enabled { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == kTag { return pass }

        let raw = type.rawValue
        var isPressure = false
        var stage = 0
        if raw == kTypeGesture || raw == kTypePressure || raw == kTypeQuickLook, let ns = NSEvent(cgEvent: event) {
            if ns.type == .pressure {
                isPressure = true
                stage = ns.stage
            } else if ns.type == .quickLook {
                isPressure = true
            }
        }
        if raw == kTypeGesture && !isPressure { return pass }
        if debug && type != .leftMouseDragged && (!isPressure || stage != lastStage) {
            NSLog("FMC type=\(raw) state=\(state) stage=\(stage)")
        }
        if isPressure { lastStage = stage }

        // A new press while we're mid-gesture means we missed an up; start over.
        if type == .leftMouseDown && state != .idle {
            if state == .middle { postMiddle(.otherMouseUp, at: event.location, proxy) }
            reset()
        }

        switch state {
        case .idle:
            guard type == .leftMouseDown else { return pass }
            heldDown = event.copy()
            state = .pending
            let t = Timer(timeInterval: kHoldDelay, repeats: false) { [weak self] _ in self?.release(nil) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            return nil

        case .pending:
            if isPressure {
                if stage >= 2 { beginMiddle(proxy) }
                return nil
            }
            if type == .leftMouseUp {
                release(proxy, then: event)
                state = .idle
                return nil
            }
            if type == .leftMouseDragged, let down = heldDown {
                let a = down.location, b = event.location
                if abs(a.x - b.x) > kDragSlop || abs(a.y - b.y) > kDragSlop {
                    release(proxy, then: event)
                }
                return nil
            }
            return pass

        case .middle:
            if isPressure { return nil }   // keeps Look Up / Quick Look from also firing
            if type == .leftMouseDragged {
                postMiddle(.otherMouseDragged, at: event.location, proxy)
                return nil
            }
            if type == .leftMouseUp {
                postMiddle(.otherMouseUp, at: event.location, proxy)
                state = .idle
                return nil
            }
            return pass

        case .passthrough:
            if type == .leftMouseUp { state = .idle }
            return pass
        }
    }

    private func beginMiddle(_ proxy: CGEventTapProxy) {
        guard let down = heldDown else { return }
        timer?.invalidate()
        timer = nil
        heldDown = nil
        state = .middle
        postMiddle(.otherMouseDown, at: down.location, proxy)
    }

    /// Replays the held mouse-down (and optionally the event that triggered the release), in order.
    private func release(_ proxy: CGEventTapProxy?, then next: CGEvent? = nil) {
        timer?.invalidate()
        timer = nil
        guard let down = heldDown else { return }
        heldDown = nil
        state = .passthrough
        for e in [down, next].compactMap({ $0 }) {
            e.setIntegerValueField(.eventSourceUserData, value: kTag)
            if let proxy { e.tapPostEvent(proxy) } else { e.post(tap: .cgSessionEventTap) }
        }
    }

    private func postMiddle(_ type: CGEventType, at p: CGPoint, _ proxy: CGEventTapProxy) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .center) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.eventSourceUserData, value: kTag)
        e.tapPostEvent(proxy)
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        heldDown = nil
        state = .idle
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clicker = Clicker()
    private var statusItem: NSStatusItem!
    private let permItem = NSMenuItem(title: "Grant Accessibility Permission…", action: #selector(openAccessibility), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "Force Middle Click")

        let menu = NSMenu()
        for item in [permItem, enabledItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshMenu()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) && clicker.start() {
            refreshMenu()
            return
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted(), self.clicker.start() else { return }
            t.invalidate()
            self.refreshMenu()
        }
    }

    private func refreshMenu() {
        permItem.isHidden = clicker.isRunning
        enabledItem.state = clicker.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusItem.button?.appearsDisabled = !clicker.enabled || !clicker.isRunning
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleEnabled() {
        clicker.enabled.toggle()
        refreshMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("FMC launch-at-login error: \(error)")
        }
        refreshMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
