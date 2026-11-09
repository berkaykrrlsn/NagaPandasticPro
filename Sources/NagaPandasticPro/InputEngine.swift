import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

/// Tuş yakalama motoru.
///
/// macOS, bir klavye/fare olayının hangi cihazdan geldiğini CGEvent üzerinde söylemez.
/// Bu yüzden iki kaynağı eşleştiriyoruz:
///  1. IOHIDManager (Girdi İzleme izni) → hangi fiziksel cihaz hangi tuşa bastı
///  2. CGEventTap  (Erişilebilirlik izni) → sisteme giden olayı yakala / engelle
/// Olay Naga'dan geldiyse yutulur ve atanan eylem çalıştırılır; değilse dokunulmaz.
final class InputEngine {
    static let syntheticMarker: Int64 = 0x4E41_4741   // "NAGA" – kendi ürettiğimiz olaylar

    struct Status: Equatable {
        var hidActive = false
        var tapActive = false
        var nagaSeen = false
    }

    private struct PendingPress {
        let signature: Int
        let id: ButtonID
        let fromNaga: Bool
        let time: CFAbsoluteTime
    }

    let runner = ActionRunner()
    /// Ana iş parçacığında çağrılır
    var onStatusChange: ((Status) -> Void)?
    var onButtonActivity: ((ButtonID) -> Void)?

    // `cond` ile korunan durum
    private let cond = NSCondition()
    private var pending: [PendingPress] = []
    private var candidateSignatures: Set<Int> = []
    private var profile: Profile?
    private var enabled = true
    private var learnHandler: ((ButtonID) -> Void)?
    private var status = Status()

    // Yalnızca tap iş parçacığında
    private var held: [Int: (id: ButtonID, action: ButtonAction)] = [:]
    private var shiftHolders: Set<Int> = []
    private var tapPort: CFMachPort?

    private var started = false

    // MARK: - Genel arayüz

    func start() {
        guard !started else { return }
        started = true

        let hid = Thread { [unowned self] in self.hidThreadMain() }
        hid.name = "NagaPandasticPro.HID"
        hid.qualityOfService = .userInteractive
        hid.start()

        let tap = Thread { [unowned self] in self.tapThreadMain() }
        tap.name = "NagaPandasticPro.EventTap"
        tap.qualityOfService = .userInteractive
        tap.start()
    }

    func update(profile: Profile?, enabled: Bool) {
        var signatures = Set<Int>()
        if let p = profile {
            for (key, action) in p.bindings where action.kind != .passthrough {
                if let id = ButtonID(key: key), let s = Self.signature(for: id) { signatures.insert(s) }
            }
            for (key, action) in p.shiftBindings where action.kind != .passthrough {
                if let id = ButtonID(key: key), let s = Self.signature(for: id) { signatures.insert(s) }
            }
        }
        cond.lock()
        self.profile = profile
        self.enabled = enabled
        candidateSignatures = signatures
        cond.unlock()
        if !enabled { runner.stopAllLoops() }
    }

    func beginLearning(_ handler: @escaping (ButtonID) -> Void) {
        cond.lock(); learnHandler = handler; cond.unlock()
    }

    func cancelLearning() {
        cond.lock(); learnHandler = nil; cond.unlock()
    }

    /// Klavye olayı → 0x10000 + tuş kodu, fare düğmesi → 0x20000 + düğme no
    static func signature(for id: ButtonID) -> Int? {
        switch id.usagePage {
        case ButtonID.keyboardPage:
            guard let code = HIDKeyMap.hidToKeyCode[id.usage] else { return nil }
            return 0x10000 + Int(code)
        case ButtonID.buttonPage:
            return 0x20000 + Int(id.usage)
        default:
            return nil
        }
    }

    // MARK: - HID iş parçacığı

    private func hidThreadMain() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06],   // tüm klavyeler
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02],   // tüm fareler
            [kIOHIDVendorIDKey: RazerIDs.vendorID],                         // tüm Razer arayüzleri
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<InputEngine>.fromOpaque(context).takeUnretainedValue().handleHID(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Girdi İzleme izni verilene kadar tekrar dene
        while IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { break }
            Thread.sleep(forTimeInterval: 2)
        }
        updateStatus { $0.hidActive = true }
        CFRunLoopRun()
    }

    private func handleHID(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let isKey = page == ButtonID.keyboardPage && usage >= 0x04 && usage <= 0xE7
        let isButton = page == ButtonID.buttonPage && usage >= 1 && usage <= 32
        guard isKey || isButton else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }   // yalnızca basma

        let fromNaga = RazerIDs.isNaga(IOHIDElementGetDevice(element))
        let id = ButtonID(usagePage: page, usage: usage)

        cond.lock()
        if fromNaga && !status.nagaSeen {
            status.nagaSeen = true
            publishStatusLocked()
        }
        // Öğrenme modu (sol tık hariç, yanlışlıkla yakalanmasın)
        if fromNaga, let handler = learnHandler, !(isButton && usage == 1) {
            learnHandler = nil
            cond.unlock()
            DispatchQueue.main.async { handler(id) }
            return
        }
        if let sig = Self.signature(for: id), candidateSignatures.contains(sig) {
            let now = CFAbsoluteTimeGetCurrent()
            pending.removeAll { now - $0.time > 0.25 }
            pending.append(PendingPress(signature: sig, id: id, fromNaga: fromNaga, time: now))
            cond.broadcast()
        }
        cond.unlock()

        if fromNaga, let cb = onButtonActivity {
            DispatchQueue.main.async { cb(id) }
        }
    }

    // MARK: - Event tap iş parçacığı

    private func tapThreadMain() {
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var port: CFMachPort?
        // Erişilebilirlik izni verilene kadar tekrar dene
        while port == nil {
            port = CGEvent.tapCreate(tap: .cghidEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: mask,
                                     callback: { _, type, event, context in
                                         guard let context else { return Unmanaged.passUnretained(event) }
                                         return Unmanaged<InputEngine>.fromOpaque(context)
                                             .takeUnretainedValue()
                                             .handleTap(type: type, event: event)
                                     },
                                     userInfo: context)
            if port == nil { Thread.sleep(forTimeInterval: 2) }
        }
        guard let port else { return }
        tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        updateStatus { $0.tapActive = true }
        CFRunLoopRun()
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }

        let isDown: Bool
        let signature: Int
        switch type {
        case .keyDown, .keyUp:
            isDown = type == .keyDown
            signature = 0x10000 + Int(event.getIntegerValueField(.keyboardEventKeycode))
        case .leftMouseDown, .leftMouseUp:
            isDown = type == .leftMouseDown
            signature = 0x20000 + 1
        case .rightMouseDown, .rightMouseUp:
            isDown = type == .rightMouseDown
            signature = 0x20000 + 2
        case .otherMouseDown, .otherMouseUp:
            isDown = type == .otherMouseDown
            signature = 0x20000 + Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        default:
            return pass
        }

        if !isDown {
            if held[signature] != nil {
                handleRelease(signature)
                return nil
            }
            return pass
        }

        // Otomatik tekrar: HID tarafında karşılığı yoktur, beklemeden karar ver
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return held[signature] != nil ? nil : pass
        }
        if held[signature] != nil { return nil }

        cond.lock()
        let active = enabled && candidateSignatures.contains(signature)
        cond.unlock()
        guard active, let match = takePending(signature: signature), match.fromNaga else { return pass }
        return handlePress(signature: signature, id: match.id) ? nil : pass
    }

    /// HID tarafından gelen eşleşen basmayı bekler (en fazla 30 ms)
    private func takePending(signature: Int) -> PendingPress? {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date(timeIntervalSinceNow: 0.03)
        while true {
            let now = CFAbsoluteTimeGetCurrent()
            pending.removeAll { now - $0.time > 0.25 }
            if let i = pending.firstIndex(where: { $0.signature == signature }) {
                return pending.remove(at: i)
            }
            if !cond.wait(until: deadline) { return nil }
        }
    }

    private func handlePress(signature: Int, id: ButtonID) -> Bool {
        cond.lock()
        let profile = self.profile
        cond.unlock()
        guard let profile else { return false }

        var action: ButtonAction?
        if !shiftHolders.isEmpty, let a = profile.shiftBindings[id.key], a.kind != .passthrough {
            action = a
        }
        if action == nil, let a = profile.bindings[id.key], a.kind != .passthrough {
            action = a
        }
        guard let action else { return false }

        held[signature] = (id, action)
        if action.kind == .hypershift {
            shiftHolders.insert(signature)
            return true
        }
        runner.press(action, id: id)
        return true
    }

    private func handleRelease(_ signature: Int) {
        guard let entry = held.removeValue(forKey: signature) else { return }
        if entry.action.kind == .hypershift {
            shiftHolders.remove(signature)
            return
        }
        runner.release(entry.action, id: entry.id)
    }

    // MARK: - Durum

    private func updateStatus(_ change: (inout Status) -> Void) {
        cond.lock()
        change(&status)
        publishStatusLocked()
        cond.unlock()
    }

    private func publishStatusLocked() {
        let s = status
        let cb = onStatusChange
        DispatchQueue.main.async { cb?(s) }
    }
}
