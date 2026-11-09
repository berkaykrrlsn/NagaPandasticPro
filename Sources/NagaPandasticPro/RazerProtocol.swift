import Foundation
import IOKit
import IOKit.hid

// Razer HID kontrol protokolü (OpenRazer / OpenRGB belgelerine dayanır).
// 90 baytlık "feature report":
//  [0] durum  [1] transaction id  [2-3] kalan paket  [4] protokol
//  [5] veri boyu  [6] komut sınıfı  [7] komut id  [8..87] argümanlar  [88] CRC  [89] 0

enum RazerIDs {
    static let vendorID = 0x1532
    /// Naga V3 Pro: kablolu ve HyperSpeed alıcı. Diğer Naga modelleri ürün adından tanınır.
    static let nagaProductIDs: Set<Int> = [0x00A7, 0x00A8]

    static func isNaga(_ device: IOHIDDevice?) -> Bool {
        guard let device else { return false }
        let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        guard vid == vendorID else { return false }
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        if nagaProductIDs.contains(pid) { return true }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        return name.localizedCaseInsensitiveContains("naga")
    }

    static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
    }

    static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }
}

struct RazerReport {
    var bytes: [UInt8]

    init(commandClass: UInt8, commandID: UInt8, dataSize: UInt8? = nil, args: [UInt8] = [], transactionID: UInt8 = 0x1F) {
        bytes = [UInt8](repeating: 0, count: 90)
        bytes[1] = transactionID
        bytes[5] = dataSize ?? UInt8(args.count)
        bytes[6] = commandClass
        bytes[7] = commandID
        for (i, a) in args.prefix(80).enumerated() { bytes[8 + i] = a }
        updateCRC()
    }

    init(raw: [UInt8]) { bytes = raw }

    mutating func setTransactionID(_ id: UInt8) {
        bytes[1] = id
        updateCRC()
    }

    mutating func updateCRC() {
        var crc: UInt8 = 0
        for i in 2..<88 { crc ^= bytes[i] }
        bytes[88] = crc
    }

    var status: UInt8 { bytes[0] }
    var commandClass: UInt8 { bytes[6] }
    var commandID: UInt8 { bytes[7] }
    func arg(_ i: Int) -> UInt8 { bytes[8 + i] }
}

enum RazerCommands {
    static let varstore: UInt8 = 0x01

    static func firmware() -> RazerReport { RazerReport(commandClass: 0x00, commandID: 0x81, dataSize: 0x02) }
    static func battery() -> RazerReport { RazerReport(commandClass: 0x07, commandID: 0x80, dataSize: 0x02) }
    static func charging() -> RazerReport { RazerReport(commandClass: 0x07, commandID: 0x84, dataSize: 0x02) }

    static func dpi(_ value: Int) -> RazerReport {
        let v = UInt16(clamping: max(100, min(30000, value)))
        let hi = UInt8(v >> 8), lo = UInt8(v & 0xFF)
        return RazerReport(commandClass: 0x04, commandID: 0x05, dataSize: 0x07,
                           args: [varstore, hi, lo, hi, lo, 0x00, 0x00])
    }

    static func brightness(_ percent: Double, led: UInt8) -> RazerReport {
        let v = UInt8(clamping: Int((max(0, min(100, percent)) / 100 * 255).rounded()))
        return RazerReport(commandClass: 0x0F, commandID: 0x04, dataSize: 0x03, args: [varstore, led, v])
    }

    /// Genişletilmiş matris efekti (komut 0x0F / 0x02)
    static func effect(_ z: ZoneLighting, led: UInt8) -> RazerReport {
        let a = z.color1, b = z.color2
        let args: [UInt8]
        switch z.effect {
        case .off:
            args = [varstore, led, 0x00, 0x00, 0x00, 0x00]
        case .staticColor:
            args = [varstore, led, 0x01, 0x00, 0x00, 0x01, a.r, a.g, a.b]
        case .breathing:
            args = [varstore, led, 0x02, 0x01, 0x00, 0x01, a.r, a.g, a.b]
        case .breathingDual:
            args = [varstore, led, 0x02, 0x02, 0x00, 0x02, a.r, a.g, a.b, b.r, b.g, b.b]
        case .breathingRandom:
            args = [varstore, led, 0x02, 0x00, 0x00, 0x00]
        case .spectrum:
            args = [varstore, led, 0x03, 0x00, 0x00, 0x00]
        case .waveLeft, .waveRight:
            let dir: UInt8 = z.effect == .waveRight ? 0x01 : 0x02
            let speeds: [UInt8] = [0x60, 0x28, 0x10]   // yavaş, normal, hızlı
            args = [varstore, led, 0x04, dir, speeds[max(0, min(2, z.speed - 1))], 0x00]
        case .reactive:
            let s = UInt8(max(1, min(4, 5 - z.speed)))   // 1 = kısa, 4 = uzun
            args = [varstore, led, 0x05, 0x00, s, 0x01, a.r, a.g, a.b]
        }
        return RazerReport(commandClass: 0x0F, commandID: 0x02, args: args)
    }
}

/// Naga'yı bulur, kontrol arayüzünü seçer ve komut gönderir.
final class RazerController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName = ""
    @Published private(set) var productID = 0
    @Published private(set) var firmware = ""
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var message = "Cihaz aranıyor…"

    private let io = DispatchQueue(label: "NagaPandasticPro.razer", qos: .userInitiated)
    private var manager: IOHIDManager?
    private var rescanWork: DispatchWorkItem?
    private var batteryTimer: Timer?

    // yalnızca `io` kuyruğunda
    private var control: IOHIDDevice?
    private var transactionID: UInt8 = 0x1F
    private var lastLighting: LightingConfig?
    private var lastDPI: Int?

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: RazerIDs.vendorID] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<RazerController>.fromOpaque(ctx).takeUnretainedValue().scheduleRescan()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<RazerController>.fromOpaque(ctx).takeUnretainedValue().scheduleRescan()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        scheduleRescan()

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func rescan() {
        guard let manager else { return }
        let nagas = Self.devices(of: manager).filter { RazerIDs.isNaga($0) }
        let sorted = nagas.sorted { Self.score($0) > Self.score($1) }
        io.async { [weak self] in self?.selectControl(from: sorted) }
    }

    func apply(lighting: LightingConfig) {
        io.async { [weak self] in
            guard let self else { return }
            self.lastLighting = lighting
            self.sendLighting(lighting)
        }
    }

    func setDPI(_ value: Int) {
        io.async { [weak self] in
            guard let self else { return }
            self.lastDPI = value
            if self.control != nil, self.transact(RazerCommands.dpi(value)) == nil {
                self.publish(message: "DPI ayarlanamadı")
            }
        }
    }

    func refreshBattery() {
        io.async { [weak self] in
            guard let self, self.control != nil else { return }
            let level = self.transact(RazerCommands.battery()).map { Int($0.arg(1)) * 100 / 255 }
            let charging = self.transact(RazerCommands.charging()).map { $0.arg(1) == 1 } ?? false
            DispatchQueue.main.async {
                self.batteryPercent = level
                self.isCharging = charging
            }
        }
    }

    // MARK: - io kuyruğu

    private func selectControl(from candidates: [IOHIDDevice]) {
        control = nil
        for dev in candidates {
            _ = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            for tid: UInt8 in [0x1F, 0x3F, 0xFF] {
                var probe = RazerCommands.firmware()
                probe.setTransactionID(tid)
                if let resp = transact(probe, on: dev, transactionID: tid) {
                    control = dev
                    transactionID = tid
                    let name = RazerIDs.stringProperty(dev, kIOHIDProductKey)
                    let pid = RazerIDs.intProperty(dev, kIOHIDProductIDKey)
                    let fw = "v\(resp.arg(0)).\(resp.arg(1))"
                    DispatchQueue.main.async {
                        self.isConnected = true
                        self.deviceName = name.isEmpty ? "Razer Naga" : name
                        self.productID = pid
                        self.firmware = fw
                        self.message = "Bağlı"
                    }
                    if let l = lastLighting { sendLighting(l) }
                    if let d = lastDPI { _ = transact(RazerCommands.dpi(d)) }
                    refreshBattery()
                    return
                }
            }
        }
        let msg = candidates.isEmpty
            ? "Naga bulunamadı. USB kablosu veya HyperSpeed alıcısını kontrol edin."
            : "Naga bulundu ancak kontrol arayüzü yanıt vermedi (Bluetooth modunda ışık kontrolü desteklenmez)."
        DispatchQueue.main.async {
            self.isConnected = false
            self.batteryPercent = nil
            self.message = msg
        }
    }

    private func sendLighting(_ l: LightingConfig) {
        guard control != nil else { return }
        var failed = false
        for zone in LightZone.allCases {
            let z = l.sync ? l.logo : l[zone]
            if transact(RazerCommands.effect(z, led: zone.ledID)) == nil { failed = true }
            if transact(RazerCommands.brightness(z.effect == .off ? 0 : z.brightness, led: zone.ledID)) == nil { failed = true }
        }
        publish(message: failed ? "Bazı ışık bölgeleri yanıt vermedi" : "Bağlı")
    }

    private func transact(_ report: RazerReport) -> RazerReport? {
        guard let control else { return nil }
        var r = report
        r.setTransactionID(transactionID)
        return transact(r, on: control, transactionID: transactionID)
    }

    private func transact(_ report: RazerReport, on device: IOHIDDevice, transactionID: UInt8) -> RazerReport? {
        let out = report.bytes
        let set = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, out, out.count)
        guard set == kIOReturnSuccess else { return nil }
        for _ in 0..<12 {
            usleep(2500)
            var buffer = [UInt8](repeating: 0, count: 90)
            var length = CFIndex(buffer.count)
            let get = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &buffer, &length)
            guard get == kIOReturnSuccess, length >= 90 else { return nil }
            let resp = RazerReport(raw: buffer)
            switch resp.status {
            case 0x02 where resp.commandClass == report.commandClass:
                return resp
            case 0x00, 0x01:      // henüz yanıt yok / meşgul
                continue
            default:              // başarısız, zaman aşımı, desteklenmiyor
                return nil
            }
        }
        return nil
    }

    private func publish(message: String) {
        DispatchQueue.main.async { self.message = message }
    }

    // MARK: - Yardımcılar

    static func devices(of manager: IOHIDManager) -> [IOHIDDevice] {
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        let count = CFSetGetCount(set)
        guard count > 0 else { return [] }
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(set, &values)
        return values.compactMap { ptr in
            ptr.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    /// Kontrol komutlarını kabul etmesi en olası arayüz önce denenir.
    private static func score(_ d: IOHIDDevice) -> Int {
        let page = RazerIDs.intProperty(d, kIOHIDPrimaryUsagePageKey)
        let usage = RazerIDs.intProperty(d, kIOHIDPrimaryUsageKey)
        if page == 0x01 && usage == 0x02 { return 3 }   // fare arayüzü (interface 0)
        if page >= 0xFF00 { return 2 }                  // üretici arayüzü
        if page == 0x01 && usage == 0x06 { return 1 }   // klavye arayüzü
        return 0
    }
}
