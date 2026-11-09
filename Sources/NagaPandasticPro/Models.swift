import Foundation
import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Fiziksel tuş kimliği (HID usage page + usage)

struct ButtonID: Hashable, Codable {
    var usagePage: UInt32
    var usage: UInt32

    static let keyboardPage: UInt32 = 0x07
    static let buttonPage: UInt32 = 0x09

    init(usagePage: UInt32, usage: UInt32) {
        self.usagePage = usagePage
        self.usage = usage
    }

    init?(key: String) {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let p = UInt32(parts[0]), let u = UInt32(parts[1]) else { return nil }
        self.init(usagePage: p, usage: u)
    }

    /// Sözlük anahtarı olarak kullanılan metin ("7:30")
    var key: String { "\(usagePage):\(usage)" }

    var technicalName: String {
        switch usagePage {
        case Self.keyboardPage:
            return "Klavye kodu: \(HIDKeyMap.name(forHIDUsage: usage)) (0x\(String(usage, radix: 16, uppercase: true)))"
        case Self.buttonPage:
            return "Fare düğmesi \(usage)"
        default:
            return "HID \(usagePage):\(usage)"
        }
    }
}

struct ButtonSlot: Identifiable, Codable, Hashable {
    enum Group: String, Codable { case side, mouse, learned }
    var id: ButtonID
    var name: String
    var group: Group
}

// MARK: - Eylem türleri

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case passthrough, disabled, keyCombo, macro, text, openApp, openURL, shell,
         media, mouse, scroll, dpi, nextProfile, setProfile, hypershift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passthrough: return "Varsayılan (değiştirme)"
        case .disabled: return "Devre dışı"
        case .keyCombo: return "Klavye tuşu / kısayol"
        case .macro: return "Makro (sıralı işlemler)"
        case .text: return "Metin yaz"
        case .openApp: return "Uygulama aç"
        case .openURL: return "Web sitesi / link aç"
        case .shell: return "Terminal komutu çalıştır"
        case .media: return "Medya / sistem tuşu"
        case .mouse: return "Fare tıklaması"
        case .scroll: return "Kaydırma"
        case .dpi: return "DPI ayarla"
        case .nextProfile: return "Sonraki profile geç"
        case .setProfile: return "Belirli profile geç"
        case .hypershift: return "Hypershift (2. katman)"
        }
    }

    var symbol: String {
        switch self {
        case .passthrough: return "arrow.uturn.backward"
        case .disabled: return "nosign"
        case .keyCombo: return "keyboard"
        case .macro: return "list.bullet.rectangle"
        case .text: return "text.cursor"
        case .openApp: return "app.badge"
        case .openURL: return "globe"
        case .shell: return "terminal"
        case .media: return "playpause"
        case .mouse: return "cursorarrow.click"
        case .scroll: return "arrow.up.and.down"
        case .dpi: return "speedometer"
        case .nextProfile: return "arrow.triangle.2.circlepath"
        case .setProfile: return "person.crop.rectangle"
        case .hypershift: return "shift"
        }
    }

    var supportsRepeat: Bool {
        switch self {
        case .keyCombo, .macro, .text, .media, .mouse, .scroll: return true
        default: return false
        }
    }
}

enum MediaKey: Int32, Codable, CaseIterable, Identifiable {
    case playPause = 16, next = 17, previous = 18
    case volumeUp = 0, volumeDown = 1, mute = 7
    case brightnessUp = 2, brightnessDown = 3
    case keyboardLightUp = 21, keyboardLightDown = 22

    var id: Int32 { rawValue }
    var title: String {
        switch self {
        case .playPause: return "Oynat / Duraklat"
        case .next: return "Sonraki parça"
        case .previous: return "Önceki parça"
        case .volumeUp: return "Ses aç"
        case .volumeDown: return "Ses kıs"
        case .mute: return "Sessiz"
        case .brightnessUp: return "Ekran parlaklığı +"
        case .brightnessDown: return "Ekran parlaklığı −"
        case .keyboardLightUp: return "Klavye ışığı +"
        case .keyboardLightDown: return "Klavye ışığı −"
        }
    }
}

enum MouseButtonKind: Int, Codable, CaseIterable, Identifiable {
    case left = 0, right = 1, middle = 2, back = 3, forward = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .left: return "Sol tık"
        case .right: return "Sağ tık"
        case .middle: return "Orta tık"
        case .back: return "Geri (4. tuş)"
        case .forward: return "İleri (5. tuş)"
        }
    }
}

enum ScrollDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .up: return "Yukarı"
        case .down: return "Aşağı"
        case .left: return "Sola"
        case .right: return "Sağa"
        }
    }
}

enum RepeatMode: String, Codable, CaseIterable, Identifiable {
    case once, whileHeld, toggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: return "Tek sefer (basılı tutma aynen aktarılır)"
        case .whileHeld: return "Basılı tuttukça tekrarla"
        case .toggle: return "Bas–başlat / bas–durdur"
        }
    }
}

// MARK: - Klavye kombinasyonu

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// CGEventFlags ham değeri (yalnızca ⌃⌥⇧⌘ fn)
    var modifiers: UInt64

    init(keyCode: UInt16, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ keyCode: UInt16, _ flags: CGEventFlags = []) {
        self.init(keyCode: keyCode, modifiers: flags.rawValue)
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        let f = flags
        if f.contains(.maskSecondaryFn) { s += "fn " }
        for m in ModifierKey.all where f.contains(m.flag) && ModifierKey.flag(forKeyCode: keyCode) != m.flag {
            s += m.symbol
        }
        return s + KeyNames.name(forKeyCode: keyCode)
    }

    static func cgFlags(from m: NSEvent.ModifierFlags) -> UInt64 {
        var f: CGEventFlags = []
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f.rawValue
    }
}

struct ModifierKey {
    let keyCode: UInt16
    let flag: CGEventFlags
    let symbol: String

    static let all: [ModifierKey] = [
        ModifierKey(keyCode: 0x3B, flag: .maskControl, symbol: "⌃"),
        ModifierKey(keyCode: 0x3A, flag: .maskAlternate, symbol: "⌥"),
        ModifierKey(keyCode: 0x38, flag: .maskShift, symbol: "⇧"),
        ModifierKey(keyCode: 0x37, flag: .maskCommand, symbol: "⌘"),
    ]

    static func flag(forKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case 0x3B, 0x3E: return .maskControl
        case 0x3A, 0x3D: return .maskAlternate
        case 0x38, 0x3C: return .maskShift
        case 0x37, 0x36: return .maskCommand
        case 0x3F: return .maskSecondaryFn
        default: return nil
        }
    }
}

// MARK: - Makro

struct MacroStep: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case keyTap, keyDown, keyUp, text, delay, click, openURL, openApp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keyTap: return "Tuşa bas-bırak"
            case .keyDown: return "Tuşu basılı tut"
            case .keyUp: return "Tuşu bırak"
            case .text: return "Metin yaz"
            case .delay: return "Bekle"
            case .click: return "Fare tıklaması"
            case .openURL: return "Link aç"
            case .openApp: return "Uygulama aç"
            }
        }
        var symbol: String {
            switch self {
            case .keyTap: return "keyboard"
            case .keyDown: return "arrow.down.to.line"
            case .keyUp: return "arrow.up.to.line"
            case .text: return "text.cursor"
            case .delay: return "timer"
            case .click: return "cursorarrow.click"
            case .openURL: return "globe"
            case .openApp: return "app.badge"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var combo: KeyCombo? = nil
    var text: String = ""
    var delayMs: Int = 50
    var mouse: MouseButtonKind = .left
}

// MARK: - Tuş eylemi

struct ButtonAction: Codable, Hashable {
    var kind: ActionKind = .passthrough
    var combo: KeyCombo? = nil
    var text: String = ""
    var appPath: String = ""
    var url: String = ""
    var command: String = ""
    var media: MediaKey = .playPause
    var mouse: MouseButtonKind = .left
    var scroll: ScrollDirection = .down
    var scrollAmount: Int = 3
    var dpi: Int = 1600
    var profileID: UUID? = nil
    var macro: [MacroStep] = []
    var repeatMode: RepeatMode = .once
    var repeatIntervalMs: Int = 100
    var label: String = ""

    var summary: String {
        if !label.isEmpty { return label }
        switch kind {
        case .passthrough: return "Varsayılan"
        case .disabled: return "Kapalı"
        case .keyCombo: return combo?.display ?? "Kısayol yok"
        case .macro: return "Makro · \(macro.count) adım"
        case .text: return text.isEmpty ? "Metin" : "“\(text.prefix(14))”"
        case .openApp:
            return appPath.isEmpty ? "Uygulama" : URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        case .openURL:
            return URL(string: url)?.host ?? (url.isEmpty ? "Link" : url)
        case .shell: return "Komut"
        case .media: return media.title
        case .mouse: return mouse.title
        case .scroll: return "Kaydır \(scroll.title.lowercased())"
        case .dpi: return "\(dpi) DPI"
        case .nextProfile: return "Sonraki profil"
        case .setProfile: return "Profil değiştir"
        case .hypershift: return "Hypershift"
        }
    }
}

// MARK: - Aydınlatma

struct RGB: Codable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = UInt8(clamping: Int((ns.redComponent * 255).rounded()))
        g = UInt8(clamping: Int((ns.greenComponent * 255).rounded()))
        b = UInt8(clamping: Int((ns.blueComponent * 255).rounded()))
    }

    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    static let razerGreen = RGB(r: 0x44, g: 0xD6, b: 0x2C)
    static let white = RGB(r: 255, g: 255, b: 255)
}

enum LightZone: String, Codable, CaseIterable, Identifiable {
    case logo, wheel, keypad
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logo: return "Logo"
        case .wheel: return "Tekerlek"
        case .keypad: return "Yan tuşlar"
        }
    }
    /// Razer LED kimlikleri (OpenRazer protokolü)
    var ledID: UInt8 {
        switch self {
        case .wheel: return 0x01
        case .logo: return 0x04
        case .keypad: return 0x05
        }
    }
}

enum LightEffect: String, Codable, CaseIterable, Identifiable {
    case off, staticColor, breathing, breathingDual, breathingRandom, spectrum, waveLeft, waveRight, reactive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Kapalı"
        case .staticColor: return "Sabit renk"
        case .breathing: return "Nefes (tek renk)"
        case .breathingDual: return "Nefes (iki renk)"
        case .breathingRandom: return "Nefes (rastgele)"
        case .spectrum: return "Spektrum döngüsü"
        case .waveLeft: return "Dalga ←"
        case .waveRight: return "Dalga →"
        case .reactive: return "Tepkisel (tıklayınca)"
        }
    }
    var usesColor1: Bool { [.staticColor, .breathing, .breathingDual, .reactive].contains(self) }
    var usesColor2: Bool { self == .breathingDual }
    var usesSpeed: Bool { [.reactive, .waveLeft, .waveRight].contains(self) }
}

struct ZoneLighting: Codable, Hashable {
    var effect: LightEffect = .staticColor
    var color1: RGB = .razerGreen
    var color2: RGB = RGB(r: 0, g: 120, b: 255)
    var speed: Int = 2          // 1 (yavaş) … 3 (hızlı)
    var brightness: Double = 100 // 0…100
}

struct LightingConfig: Codable, Hashable {
    var sync: Bool = true
    var logo = ZoneLighting()
    var wheel = ZoneLighting()
    var keypad = ZoneLighting()

    subscript(zone: LightZone) -> ZoneLighting {
        get {
            switch zone {
            case .logo: return logo
            case .wheel: return wheel
            case .keypad: return keypad
            }
        }
        set {
            switch zone {
            case .logo: logo = newValue
            case .wheel: wheel = newValue
            case .keypad: keypad = newValue
            }
        }
    }
}

// MARK: - Profil ve uygulama ayarları

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bindings: [String: ButtonAction] = [:]
    var shiftBindings: [String: ButtonAction] = [:]
    var lighting = LightingConfig()
    var applyDPI = false
    var dpiValue = 1600
    var appBundleIDs: [String] = []
}

struct AppConfig: Codable {
    var profiles: [Profile]
    var selectedProfileID: UUID
    var buttons: [ButtonSlot]
    var enabled = true
    var autoSwitchByApp = true
    var showDockIcon = true

    static let defaultButtons: [ButtonSlot] = {
        // 12'li yan panel varsayılan olarak 1 2 3 4 5 6 7 8 9 0 - = gönderir
        let usages: [UInt32] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E]
        var slots = usages.enumerated().map { i, u in
            ButtonSlot(id: ButtonID(usagePage: ButtonID.keyboardPage, usage: u), name: "\(i + 1)", group: .side)
        }
        let mouse: [(UInt32, String)] = [(1, "Sol tık"), (2, "Sağ tık"), (3, "Tekerlek tıklaması"), (4, "Geri tuşu"), (5, "İleri tuşu")]
        slots += mouse.map { ButtonSlot(id: ButtonID(usagePage: ButtonID.buttonPage, usage: $0.0), name: $0.1, group: .mouse) }
        return slots
    }()

    static func makeDefault() -> AppConfig {
        let general = Profile(name: "Genel")
        var gaming = Profile(name: "Oyun")
        gaming.lighting.logo.color1 = RGB(r: 255, g: 30, b: 30)
        gaming.lighting.wheel.color1 = RGB(r: 255, g: 30, b: 30)
        gaming.lighting.keypad.color1 = RGB(r: 255, g: 30, b: 30)
        return AppConfig(profiles: [general, gaming], selectedProfileID: general.id, buttons: defaultButtons)
    }
}
