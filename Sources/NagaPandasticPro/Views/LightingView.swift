import SwiftUI

struct LightingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var razer: RazerController
    @State private var zone: LightZone = .logo

    static let swatches: [RGB] = [
        RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 110, b: 0), RGB(r: 255, g: 220, b: 0),
        RGB.razerGreen, RGB(r: 0, g: 230, b: 200), RGB(r: 0, g: 120, b: 255),
        RGB(r: 120, g: 40, b: 255), RGB(r: 255, g: 0, b: 170), RGB.white,
    ]

    private var lighting: Binding<LightingConfig> {
        Binding(get: { model.selectedProfile.lighting },
                set: { newValue in model.updateSelectedProfile { $0.lighting = newValue } })
    }

    private var zoneBinding: Binding<ZoneLighting> {
        Binding(
            get: {
                let l = lighting.wrappedValue
                return l.sync ? l.logo : l[zone]
            },
            set: { v in
                var l = lighting.wrappedValue
                if l.sync {
                    l.logo = v; l.wheel = v; l.keypad = v
                } else {
                    l[zone] = v
                }
                lighting.wrappedValue = l
            })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 14) {
                MousePreview(lighting: lighting.wrappedValue, highlighted: lighting.wrappedValue.sync ? nil : zone)
                    .frame(width: 210, height: 330)
                Text("Önizleme").font(.caption).foregroundStyle(.secondary)
                Text("Profil: \(model.selectedProfile.name)").font(.callout)
            }
            .padding(24)
            .frame(width: 280)

            Divider()

            Form {
                Section {
                    Toggle("Tüm bölgeler aynı", isOn: lighting.sync)
                    if !lighting.wrappedValue.sync {
                        Picker("Bölge", selection: $zone) {
                            ForEach(LightZone.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Bölgeler")
                }

                Section("Efekt") {
                    Picker("Efekt", selection: zoneBinding.effect) {
                        ForEach(LightEffect.allCases) { Text($0.title).tag($0) }
                    }
                    let effect = zoneBinding.wrappedValue.effect
                    if effect.usesColor1 {
                        ColorPicker(effect.usesColor2 ? "1. renk" : "Renk", selection: colorBinding(\.color1), supportsOpacity: false)
                    }
                    if effect.usesColor2 {
                        ColorPicker("2. renk", selection: colorBinding(\.color2), supportsOpacity: false)
                    }
                    if effect.usesSpeed {
                        Picker("Hız", selection: zoneBinding.speed) {
                            Text("Yavaş").tag(1)
                            Text("Normal").tag(2)
                            Text("Hızlı").tag(3)
                        }
                        .pickerStyle(.segmented)
                    }
                    if effect != .off {
                        HStack {
                            Image(systemName: "sun.min")
                            Slider(value: zoneBinding.brightness, in: 0...100)
                            Image(systemName: "sun.max.fill")
                            Text("%\(Int(zoneBinding.wrappedValue.brightness))").monospacedDigit().frame(width: 44)
                        }
                    }
                }

                if zoneBinding.wrappedValue.effect.usesColor1 {
                    Section("Hızlı renkler") {
                        HStack(spacing: 10) {
                            ForEach(Self.swatches, id: \.self) { c in
                                Circle()
                                    .fill(c.color)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(zoneBinding.wrappedValue.color1 == c ? 0.9 : 0.15), lineWidth: 2))
                                    .onTapGesture { zoneBinding.wrappedValue.color1 = c }
                            }
                        }
                    }
                }

                Section("Cihaz") {
                    HStack {
                        Circle().fill(razer.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(razer.message).font(.callout)
                        Spacer()
                        Button("Cihaza yeniden uygula") { model.reapplyLighting() }
                            .disabled(!razer.isConnected)
                    }
                    Text("Değişiklikler anında fareye gönderilir ve her profil kendi ışık ayarını saklar. Profil değiştiğinde ışıklar da değişir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func colorBinding(_ key: WritableKeyPath<ZoneLighting, RGB>) -> Binding<Color> {
        Binding(get: { zoneBinding.wrappedValue[keyPath: key].color },
                set: { zoneBinding.wrappedValue[keyPath: key] = RGB(color: $0) })
    }
}

/// Basit, canlandırılmış fare önizlemesi
struct MousePreview: View {
    let lighting: LightingConfig
    let highlighted: LightZone?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    // Gövde
                    RoundedRectangle(cornerRadius: w * 0.42)
                        .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.08)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: w * 0.42).strokeBorder(Color.white.opacity(0.08)))
                    // Sol/sağ tuş ayrımı
                    Rectangle().fill(Color.black.opacity(0.6))
                        .frame(width: 2, height: h * 0.30)
                        .position(x: w / 2, y: h * 0.16)
                    // Tekerlek
                    zoneGlow(.wheel, t: t, shape: Capsule(), size: CGSize(width: w * 0.10, height: h * 0.13))
                        .position(x: w / 2, y: h * 0.17)
                    // Logo
                    zoneGlow(.logo, t: t, shape: Circle(), size: CGSize(width: w * 0.22, height: w * 0.22))
                        .position(x: w / 2, y: h * 0.70)
                    // Yan tuş takımı (3×4)
                    keypad(t: t)
                        .frame(width: w * 0.30, height: h * 0.34)
                        .position(x: w * 0.13, y: h * 0.47)
                }
            }
        }
    }

    private func keypad(t: Double) -> some View {
        let c = color(for: .keypad, t: t)
        return VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: 0.12))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c, lineWidth: 1.5))
                            .shadow(color: c.opacity(0.8), radius: 3)
                    }
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5)))
        .overlay(outline(.keypad))
    }

    private func zoneGlow<S: Shape>(_ zone: LightZone, t: Double, shape: S, size: CGSize) -> some View {
        let c = color(for: zone, t: t)
        return shape
            .fill(c)
            .frame(width: size.width, height: size.height)
            .shadow(color: c, radius: 10)
            .overlay(outline(zone))
    }

    @ViewBuilder
    private func outline(_ zone: LightZone) -> some View {
        if highlighted == zone {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1, dash: [3]))
                .padding(-5)
        }
    }

    private func color(for zone: LightZone, t: Double) -> Color {
        let z = lighting.sync ? lighting.logo : lighting[zone]
        let level = z.brightness / 100
        let offset: Double = zone == .wheel ? 0 : zone == .keypad ? 0.33 : 0.66
        switch z.effect {
        case .off:
            return Color(white: 0.15)
        case .staticColor:
            return z.color1.color.opacity(level)
        case .breathing:
            return z.color1.color.opacity(level * Self.breath(t))
        case .breathingDual:
            let first = Int(t / 4) % 2 == 0
            return (first ? z.color1 : z.color2).color.opacity(level * Self.breath(t))
        case .breathingRandom:
            let hue = (Double(Int(t / 4)) * 0.618).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 1, brightness: 1).opacity(level * Self.breath(t))
        case .spectrum:
            return Color(hue: (t / 8).truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1).opacity(level)
        case .waveLeft, .waveRight:
            let speed = Double(z.speed) / 3
            let dir: Double = z.effect == .waveRight ? 1 : -1
            let hue = (t * speed / 3 + dir * offset).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue < 0 ? hue + 1 : hue, saturation: 1, brightness: 1).opacity(level)
        case .reactive:
            return z.color1.color.opacity(level * 0.35)
        }
    }

    private static func breath(_ t: Double) -> Double {
        0.15 + 0.85 * (0.5 - 0.5 * cos(t * 2 * .pi / 4))
    }
}
