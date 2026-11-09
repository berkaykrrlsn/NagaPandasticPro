import Foundation
import AppKit
import CoreGraphics

/// İptal edilebilir tekrar döngüleri için belirteç
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false
    private let semaphore = DispatchSemaphore(value: 0)

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        semaphore.signal()
    }

    /// İptal edilirse hemen döner
    func sleep(ms: Int) {
        guard !isCancelled else { return }
        if semaphore.wait(timeout: .now() + .milliseconds(max(0, ms))) == .success {
            semaphore.signal()   // sonraki beklemeler de hemen dönsün
        }
    }
}

/// Eylemleri gerçekleştirir: tuş/fare olayı üretir, uygulama/link açar, makro çalıştırır.
final class ActionRunner {
    private let queue = DispatchQueue(label: "NagaPandasticPro.actions", qos: .userInteractive)
    private let worker = DispatchQueue(label: "NagaPandasticPro.worker", qos: .userInitiated, attributes: .concurrent)
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = InputEngine.syntheticMarker
        return s
    }()
    private var loops: [ButtonID: CancelToken] = [:]   // yalnızca `queue` üzerinde

    // Ana iş parçacığında çağrılır
    var onNextProfile: (() -> Void)?
    var onSetProfile: ((UUID) -> Void)?
    var onSetDPI: ((Int) -> Void)?

    func press(_ action: ButtonAction, id: ButtonID) {
        queue.async { self.performPress(action, id: id) }
    }

    func release(_ action: ButtonAction, id: ButtonID) {
        queue.async { self.performRelease(action, id: id) }
    }

    /// Arayüzdeki "Test et" düğmesi
    func test(_ action: ButtonAction) {
        let id = ButtonID(usagePage: 0xFFFF, usage: 0)
        queue.asyncAfter(deadline: .now() + 0.3) {
            if action.kind.supportsRepeat && action.repeatMode != .once {
                self.fireSync(action, token: nil)
            } else {
                self.performPress(action, id: id)
                usleep(40_000)
                self.performRelease(action, id: id)
            }
        }
    }

    func stopAllLoops() {
        queue.async {
            self.loops.values.forEach { $0.cancel() }
            self.loops.removeAll()
        }
    }

    // MARK: - Basma / bırakma

    private func performPress(_ a: ButtonAction, id: ButtonID) {
        let mode = a.kind.supportsRepeat ? a.repeatMode : .once
        switch mode {
        case .once:
            switch a.kind {
            case .keyCombo:
                if let c = a.combo { postCombo(c, down: true) }
            case .mouse:
                postMouse(a.mouse, down: true)
            case .macro, .text:
                worker.async { self.fireSync(a, token: nil) }
            default:
                fireSync(a, token: nil)
            }
        case .whileHeld:
            startLoop(a, id: id)
        case .toggle:
            if let token = loops.removeValue(forKey: id) {
                token.cancel()
            } else {
                startLoop(a, id: id)
            }
        }
    }

    private func performRelease(_ a: ButtonAction, id: ButtonID) {
        let mode = a.kind.supportsRepeat ? a.repeatMode : .once
        switch mode {
        case .once:
            switch a.kind {
            case .keyCombo:
                if let c = a.combo { postCombo(c, down: false) }
            case .mouse:
                postMouse(a.mouse, down: false)
            default:
                break
            }
        case .whileHeld:
            loops.removeValue(forKey: id)?.cancel()
        case .toggle:
            break
        }
    }

    private func startLoop(_ a: ButtonAction, id: ButtonID) {
        loops.removeValue(forKey: id)?.cancel()
        let token = CancelToken()
        loops[id] = token
        let interval = max(10, a.repeatIntervalMs)
        worker.async {
            while !token.isCancelled {
                self.fireSync(a, token: token)
                token.sleep(ms: interval)
            }
        }
    }

    /// Eylemi bir kez, bulunduğu iş parçacığında çalıştırır
    private func fireSync(_ a: ButtonAction, token: CancelToken?) {
        switch a.kind {
        case .passthrough, .disabled, .hypershift:
            break
        case .keyCombo:
            if let c = a.combo { tapCombo(c) }
        case .macro:
            runMacro(a.macro, token: token)
        case .text:
            typeText(a.text)
        case .openApp:
            openApp(a.appPath)
        case .openURL:
            openURL(a.url)
        case .shell:
            runShell(a.command)
        case .media:
            postMediaKey(a.media)
        case .mouse:
            postMouse(a.mouse, down: true)
            usleep(10_000)
            postMouse(a.mouse, down: false)
        case .scroll:
            postScroll(a.scroll, amount: a.scrollAmount)
        case .dpi:
            let v = a.dpi
            DispatchQueue.main.async { self.onSetDPI?(v) }
        case .nextProfile:
            DispatchQueue.main.async { self.onNextProfile?() }
        case .setProfile:
            if let p = a.profileID { DispatchQueue.main.async { self.onSetProfile?(p) } }
        }
    }

    // MARK: - Makro

    private func runMacro(_ steps: [MacroStep], token: CancelToken?) {
        var held: CGEventFlags = []   // makro içinde basılı tutulan değiştiriciler
        for step in steps {
            if token?.isCancelled == true { break }
            switch step.kind {
            case .keyTap:
                if let c = step.combo { tapCombo(c, base: held) }
            case .keyDown:
                if let c = step.combo {
                    postCombo(c, down: true, base: held)
                    if let f = ModifierKey.flag(forKeyCode: c.keyCode) { held.insert(f) }
                }
            case .keyUp:
                if let c = step.combo {
                    if let f = ModifierKey.flag(forKeyCode: c.keyCode) { held.remove(f) }
                    postCombo(c, down: false, base: held)
                }
            case .text:
                typeText(step.text)
            case .delay:
                if let token { token.sleep(ms: step.delayMs) } else { usleep(UInt32(max(0, step.delayMs)) * 1000) }
            case .click:
                postMouse(step.mouse, down: true)
                usleep(10_000)
                postMouse(step.mouse, down: false)
            case .openURL:
                openURL(step.text)
            case .openApp:
                openApp(step.text)
            }
            usleep(3_000)
        }
        // Makro iptal edildiyse basılı kalan değiştiricileri bırak
        for m in ModifierKey.all where held.contains(m.flag) {
            postKey(m.keyCode, down: false, flags: [])
        }
    }

    // MARK: - Klavye

    private func tapCombo(_ c: KeyCombo, base: CGEventFlags = []) {
        postCombo(c, down: true, base: base)
        usleep(10_000)
        postCombo(c, down: false, base: base)
    }

    private func postCombo(_ c: KeyCombo, down: Bool, base: CGEventFlags = []) {
        let comboFlags = c.flags
        let selfFlag = ModifierKey.flag(forKeyCode: c.keyCode)
        let mods = ModifierKey.all.filter { comboFlags.contains($0.flag) && $0.flag != selfFlag }
        let extra = Self.extraFlags(for: c.keyCode)
        var acc = base
        if comboFlags.contains(.maskSecondaryFn) { acc.insert(.maskSecondaryFn) }

        if down {
            for m in mods {
                acc.insert(m.flag)
                postKey(m.keyCode, down: true, flags: acc)
            }
            var f = acc.union(extra)
            if let selfFlag { f.insert(selfFlag) }
            postKey(c.keyCode, down: true, flags: f)
        } else {
            for m in mods { acc.insert(m.flag) }
            postKey(c.keyCode, down: false, flags: acc.union(extra))
            for m in mods.reversed() {
                acc.remove(m.flag)
                postKey(m.keyCode, down: false, flags: acc)
            }
        }
    }

    /// Ok tuşları ve F tuşları gerçek klavyede bu bayraklarla gelir
    /// (ör. ⌃← masaüstü değiştirme bunlar olmadan çalışmaz).
    private static func extraFlags(for keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case 0x7B...0x7E:
            return [.maskNumericPad, .maskSecondaryFn]
        case 0x72, 0x73, 0x74, 0x75, 0x77, 0x79,
             0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
             0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A:
            return [.maskSecondaryFn]
        default:
            return []
        }
    }

    private func postKey(_ code: UInt16, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: InputEngine.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                postKey(0x24, down: true, flags: []); postKey(0x24, down: false, flags: [])
            } else if ch == "\t" {
                postKey(0x30, down: true, flags: []); postKey(0x30, down: false, flags: [])
            } else {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.setIntegerValueField(.eventSourceUserData, value: InputEngine.syntheticMarker)
                    e.post(tap: .cghidEventTap)
                }
            }
            usleep(4_000)
        }
    }

    private func postMediaKey(_ key: MediaKey) {
        DispatchQueue.main.async {
            for down in [true, false] {
                let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
                let data1 = (Int(key.rawValue) << 16) | ((down ? 0xA : 0xB) << 8)
                let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            subtype: 8, data1: data1, data2: -1)
                ev?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Fare

    private func postMouse(_ b: MouseButtonKind, down: Bool) {
        let location = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType
        let button: CGMouseButton
        switch b {
        case .left:
            type = down ? .leftMouseDown : .leftMouseUp
            button = .left
        case .right:
            type = down ? .rightMouseDown : .rightMouseUp
            button = .right
        case .middle, .back, .forward:
            type = down ? .otherMouseDown : .otherMouseUp
            button = .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        if button == .center {
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b.rawValue))
        }
        e.setIntegerValueField(.eventSourceUserData, value: InputEngine.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    private func postScroll(_ dir: ScrollDirection, amount: Int) {
        let n = Int32(max(1, min(50, amount)))
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch dir {
        case .up: vertical = n
        case .down: vertical = -n
        case .left: horizontal = n
        case .right: horizontal = -n
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: InputEngine.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Uygulama, link, komut

    private func openApp(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    private func openURL(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private func runShell(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
