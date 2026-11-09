import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActionEditor: View {
    @EnvironmentObject var model: AppModel
    let slot: ButtonSlot
    let layer: AppModel.Layer
    @Binding var action: ButtonAction
    @State private var slotName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Tuş adı", text: $slotName)
                        .onSubmit { model.renameSlot(slot.id, to: slotName) }
                        .onChange(of: slotName) { _, v in model.renameSlot(slot.id, to: v) }
                    if slot.group == .learned {
                        Button(role: .destructive) { model.removeSlot(slot.id) } label: {
                            Image(systemName: "trash")
                        }
                        .help("Öğrenilen tuşu kaldır")
                    }
                }
                Text(slot.id.technicalName + (layer == .shift ? " · Hypershift katmanı" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if slot.id == ButtonID(usagePage: ButtonID.buttonPage, usage: 1) && action.kind != .passthrough {
                    Label("Sol tık değiştirilirse Naga ile normal tıklama yapılamaz.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("Tuş")
            }

            Section("Eylem") {
                Picker("Eylem türü", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { k in
                        Label(k.title, systemImage: k.symbol).tag(k)
                    }
                }
                details
            }

            if action.kind.supportsRepeat {
                Section("Tekrar") {
                    Picker("Davranış", selection: $action.repeatMode) {
                        ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                    }
                    if action.repeatMode != .once {
                        Stepper(value: $action.repeatIntervalMs, in: 10...5000, step: 10) {
                            Text("Aralık: \(action.repeatIntervalMs) ms")
                        }
                    }
                }
            }

            Section("Görünüm") {
                TextField("Özel etiket (isteğe bağlı)", text: $action.label)
            }

            Section {
                HStack {
                    Button {
                        model.engine.runner.test(action)
                    } label: {
                        Label("Test et", systemImage: "play.fill")
                    }
                    .disabled(action.kind == .passthrough || action.kind == .disabled || action.kind == .hypershift)
                    Spacer()
                    Button("Varsayılana döndür", role: .destructive) { action = ButtonAction() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { slotName = slot.name }
    }

    @ViewBuilder
    private var details: some View {
        switch action.kind {
        case .passthrough:
            Text("Tuş, Naga'nın kendi gönderdiği kodu kullanır (12'li panelde 1–9, 0, -, =).")
                .foregroundStyle(.secondary)
        case .disabled:
            Text("Bu tuşa basıldığında hiçbir şey olmaz.").foregroundStyle(.secondary)
        case .keyCombo:
            ShortcutRecorderView(combo: $action.combo)
            ShortcutPresetsMenu(combo: $action.combo)
            ManualKeyPicker(combo: $action.combo)
            Text("İpucu: “Tek sefer” modunda Naga tuşunu basılı tuttuğunuz sürece kısayol da basılı kalır (oyunlar için ideal).")
                .font(.caption).foregroundStyle(.secondary)
        case .macro:
            MacroEditor(steps: $action.macro)
        case .text:
            TextEditor(text: $action.text)
                .font(.body)
                .frame(minHeight: 90)
            Text("Emoji ve Türkçe karakterler desteklenir. Satır sonu Return tuşu olarak gönderilir.")
                .font(.caption).foregroundStyle(.secondary)
        case .openApp:
            AppPickerRow(path: $action.appPath)
        case .openURL:
            TextField("https://ornek.com", text: $action.url)
            Menu("Hazır linkler") {
                ForEach(Self.urlPresets, id: \.0) { item in
                    Button(item.0) { action.url = item.1 }
                }
            }
        case .shell:
            TextField("Komut (zsh)", text: $action.command, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...6)
            Text("Örnekler:  open ~/Downloads   ·   pmset displaysleepnow   ·   osascript -e 'set volume output volume 30'")
                .font(.caption).foregroundStyle(.secondary)
        case .media:
            Picker("Tuş", selection: $action.media) {
                ForEach(MediaKey.allCases) { Text($0.title).tag($0) }
            }
        case .mouse:
            Picker("Düğme", selection: $action.mouse) {
                ForEach(MouseButtonKind.allCases) { Text($0.title).tag($0) }
            }
        case .scroll:
            Picker("Yön", selection: $action.scroll) {
                ForEach(ScrollDirection.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $action.scrollAmount, in: 1...30) {
                Text("Miktar: \(action.scrollAmount) satır")
            }
        case .dpi:
            DPIControl(value: $action.dpi)
        case .nextProfile:
            Text("Profiller arasında sırayla geçer.").foregroundStyle(.secondary)
        case .setProfile:
            Picker("Profil", selection: $action.profileID) {
                Text("Seçin").tag(UUID?.none)
                ForEach(model.config.profiles) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
        case .hypershift:
            Text("Bu tuş basılı tutulduğu sürece tüm tuşlar “Hypershift” katmanındaki atamaları kullanır. Böylece 12 tuş 24 farklı işlev görebilir.")
                .foregroundStyle(.secondary)
        }
    }

    static let urlPresets: [(String, String)] = [
        ("YouTube", "https://youtube.com"),
        ("Google", "https://google.com"),
        ("Gmail", "https://mail.google.com"),
        ("Claude", "https://claude.ai"),
        ("GitHub", "https://github.com"),
        ("Spotify Web", "https://open.spotify.com"),
        ("Twitch", "https://twitch.tv"),
        ("Discord", "https://discord.com/app"),
    ]
}

// MARK: - DPI

struct DPIControl: View {
    @Binding var value: Int
    static let presets = [400, 800, 1200, 1600, 3200, 6400, 12800]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int(($0 / 50).rounded()) * 50 }),
                       in: 100...30000)
                TextField("", value: $value, format: .number)
                    .frame(width: 70)
                Text("DPI")
            }
            HStack {
                ForEach(Self.presets, id: \.self) { p in
                    Button("\(p)") { value = p }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(value == p ? Color.accentColor : nil)
                }
            }
        }
    }
}

// MARK: - Kısayol kaydedici

struct ShortcutRecorderView: View {
    @Binding var combo: KeyCombo?
    var compact = false
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?

    var body: some View {
        HStack {
            Text(recording ? "Tuşlara basın…" : (combo?.display ?? "Kısayol yok"))
                .font(.system(size: compact ? 13 : 16, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, compact ? 3 : 6)
                .frame(minWidth: compact ? 90 : 160, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(recording ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                )
            if !compact { Spacer() }
            Button(recording ? "Durdur" : "Kaydet") {
                recording ? stop() : start()
            }
            .controlSize(compact ? .small : .regular)
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Temizle")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        recording = true
        pendingModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            combo = KeyCombo(keyCode: event.keyCode, modifiers: KeyCombo.cgFlags(from: event.modifierFlags))
            stop()
        case .flagsChanged:
            guard let flag = ModifierKey.flag(forKeyCode: event.keyCode) else { return }
            let isDown = KeyCombo.cgFlags(from: event.modifierFlags) & flag.rawValue != 0
            if isDown {
                pendingModifier = event.keyCode
            } else if pendingModifier == event.keyCode {
                // Yalnızca değiştirici tuşa basılıp bırakıldı → tek başına ata (ör. Shift)
                combo = KeyCombo(keyCode: event.keyCode, modifiers: 0)
                stop()
            }
        default:
            break
        }
    }
}

struct ShortcutPreset {
    let title: String
    let combo: KeyCombo
}

struct ShortcutPresetsMenu: View {
    @Binding var combo: KeyCombo?

    static let groups: [(String, [ShortcutPreset])] = [
        ("Düzenleme", [
            ShortcutPreset(title: "Kopyala", combo: KeyCombo(0x08, .maskCommand)),
            ShortcutPreset(title: "Yapıştır", combo: KeyCombo(0x09, .maskCommand)),
            ShortcutPreset(title: "Kes", combo: KeyCombo(0x07, .maskCommand)),
            ShortcutPreset(title: "Geri al", combo: KeyCombo(0x06, .maskCommand)),
            ShortcutPreset(title: "Yinele", combo: KeyCombo(0x06, [.maskCommand, .maskShift])),
            ShortcutPreset(title: "Tümünü seç", combo: KeyCombo(0x00, .maskCommand)),
            ShortcutPreset(title: "Kaydet", combo: KeyCombo(0x01, .maskCommand)),
            ShortcutPreset(title: "Bul", combo: KeyCombo(0x03, .maskCommand)),
        ]),
        ("Pencere & Sistem", [
            ShortcutPreset(title: "Spotlight", combo: KeyCombo(0x31, .maskCommand)),
            ShortcutPreset(title: "Uygulama değiştir (⌘⇥)", combo: KeyCombo(0x30, .maskCommand)),
            ShortcutPreset(title: "Mission Control", combo: KeyCombo(0x7E, .maskControl)),
            ShortcutPreset(title: "Uygulama pencereleri", combo: KeyCombo(0x7D, .maskControl)),
            ShortcutPreset(title: "Soldaki masaüstü", combo: KeyCombo(0x7B, .maskControl)),
            ShortcutPreset(title: "Sağdaki masaüstü", combo: KeyCombo(0x7C, .maskControl)),
            ShortcutPreset(title: "Masaüstünü göster (F11)", combo: KeyCombo(0x67)),
            ShortcutPreset(title: "Pencereyi kapat", combo: KeyCombo(0x0D, .maskCommand)),
            ShortcutPreset(title: "Uygulamayı gizle", combo: KeyCombo(0x04, .maskCommand)),
            ShortcutPreset(title: "Küçült", combo: KeyCombo(0x2E, .maskCommand)),
            ShortcutPreset(title: "Uygulamadan çık", combo: KeyCombo(0x0C, .maskCommand)),
            ShortcutPreset(title: "Ekranı kilitle", combo: KeyCombo(0x0C, [.maskControl, .maskCommand])),
            ShortcutPreset(title: "Zorla çık", combo: KeyCombo(0x35, [.maskAlternate, .maskCommand])),
        ]),
        ("Ekran görüntüsü", [
            ShortcutPreset(title: "Tüm ekran", combo: KeyCombo(0x14, [.maskCommand, .maskShift])),
            ShortcutPreset(title: "Seçili alan", combo: KeyCombo(0x15, [.maskCommand, .maskShift])),
            ShortcutPreset(title: "Ekran görüntüsü araçları", combo: KeyCombo(0x17, [.maskCommand, .maskShift])),
        ]),
        ("Tarayıcı", [
            ShortcutPreset(title: "Yeni sekme", combo: KeyCombo(0x11, .maskCommand)),
            ShortcutPreset(title: "Kapatılan sekmeyi geri aç", combo: KeyCombo(0x11, [.maskCommand, .maskShift])),
            ShortcutPreset(title: "Sonraki sekme", combo: KeyCombo(0x30, .maskControl)),
            ShortcutPreset(title: "Önceki sekme", combo: KeyCombo(0x30, [.maskControl, .maskShift])),
            ShortcutPreset(title: "Yenile", combo: KeyCombo(0x0F, .maskCommand)),
            ShortcutPreset(title: "Geri", combo: KeyCombo(0x21, .maskCommand)),
            ShortcutPreset(title: "İleri", combo: KeyCombo(0x1E, .maskCommand)),
            ShortcutPreset(title: "Adres çubuğu", combo: KeyCombo(0x25, .maskCommand)),
        ]),
    ]

    var body: some View {
        Menu("Hazır kısayollar") {
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.title) { preset in
                        Button("\(preset.title)   \(preset.combo.display)") { combo = preset.combo }
                    }
                }
            }
        }
    }
}

struct ManualKeyPicker: View {
    @Binding var combo: KeyCombo?

    var body: some View {
        DisclosureGroup("Elle seç") {
            Picker("Tuş", selection: keyBinding) {
                ForEach(KeyNames.pickerKeys, id: \.code) { k in
                    Text(k.name).tag(k.code)
                }
            }
            HStack {
                Text("Değiştiriciler")
                Spacer()
                ForEach(ModifierKey.all, id: \.keyCode) { m in
                    Toggle(m.symbol, isOn: modifierBinding(m.flag))
                        .toggleStyle(.button)
                }
            }
        }
    }

    private var keyBinding: Binding<UInt16> {
        Binding(get: { combo?.keyCode ?? 0x12 },
                set: { combo = KeyCombo(keyCode: $0, modifiers: combo?.modifiers ?? 0) })
    }

    private func modifierBinding(_ flag: CGEventFlags) -> Binding<Bool> {
        Binding(get: { (combo?.modifiers ?? 0) & flag.rawValue != 0 },
                set: { on in
                    var c = combo ?? KeyCombo(keyCode: 0x12)
                    if on { c.modifiers |= flag.rawValue } else { c.modifiers &= ~flag.rawValue }
                    combo = c
                })
    }
}

// MARK: - Uygulama seçici

struct AppPickerRow: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 10) {
            if path.isEmpty {
                Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.secondary)
                Text("Uygulama seçilmedi").foregroundStyle(.secondary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Menu("Açık olanlardan") {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? "?") { path = app.bundleURL?.path ?? path }
                }
            }
            .fixedSize()
            Button("Seç…", action: choose)
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

// MARK: - Makro düzenleyici

struct MacroEditor: View {
    @Binding var steps: [MacroStep]
    @State private var liveRecording = false
    @State private var monitor: Any?
    @State private var lastEventTime: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if steps.isEmpty {
                Text("Henüz adım yok. Adım ekleyin veya canlı kaydedin.")
                    .foregroundStyle(.secondary)
            }
            ForEach($steps) { $step in
                MacroStepRow(step: $step,
                             onUp: { move(step.id, by: -1) },
                             onDown: { move(step.id, by: 1) },
                             onDelete: { steps.removeAll { $0.id == step.id } })
            }
            HStack {
                Menu {
                    ForEach(MacroStep.Kind.allCases) { k in
                        Button { steps.append(MacroStep(kind: k)) } label: { Label(k.title, systemImage: k.symbol) }
                    }
                } label: {
                    Label("Adım ekle", systemImage: "plus")
                }
                .fixedSize()
                Button {
                    liveRecording ? stopLive() : startLive()
                } label: {
                    Label(liveRecording ? "Kaydı durdur" : "Canlı kaydet", systemImage: liveRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(liveRecording ? Color.red : nil)
                Spacer()
                if !steps.isEmpty {
                    Button("Temizle", role: .destructive) { steps.removeAll() }
                }
            }
            if liveRecording {
                Text("Kayıt sürüyor: klavyede yazdıklarınız ve bekleme süreleri adım olarak ekleniyor.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stopLive() }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard steps.indices.contains(j) else { return }
        steps.swapAt(i, j)
    }

    private func startLive() {
        stopLive()
        liveRecording = true
        lastEventTime = ProcessInfo.processInfo.systemUptime
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            record(event)
            return nil
        }
    }

    private func stopLive() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        liveRecording = false
    }

    private func record(_ event: NSEvent) {
        if event.type == .keyDown && event.isARepeat { return }
        let now = event.timestamp
        let gap = Int(((now - lastEventTime) * 1000).rounded())
        lastEventTime = now
        if gap > 15 && !steps.isEmpty {
            steps.append(MacroStep(kind: .delay, delayMs: min(gap, 10_000)))
        }
        let combo = KeyCombo(keyCode: event.keyCode)
        switch event.type {
        case .keyDown:
            steps.append(MacroStep(kind: .keyDown, combo: combo))
        case .keyUp:
            steps.append(MacroStep(kind: .keyUp, combo: combo))
        case .flagsChanged:
            guard let flag = ModifierKey.flag(forKeyCode: event.keyCode) else { return }
            let down = KeyCombo.cgFlags(from: event.modifierFlags) & flag.rawValue != 0
            steps.append(MacroStep(kind: down ? .keyDown : .keyUp, combo: combo))
        default:
            break
        }
    }
}

struct MacroStepRow: View {
    @Binding var step: MacroStep
    var onUp: () -> Void
    var onDown: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: step.kind.symbol).frame(width: 18)
            Text(step.kind.title).frame(width: 110, alignment: .leading).font(.callout)
            content
            Spacer(minLength: 4)
            Button(action: onUp) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
            Button(action: onDown) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder
    private var content: some View {
        switch step.kind {
        case .keyTap, .keyDown, .keyUp:
            ShortcutRecorderView(combo: $step.combo, compact: true)
        case .text:
            TextField("Metin", text: $step.text)
        case .openURL:
            TextField("https://…", text: $step.text)
        case .openApp:
            TextField("/Applications/Uygulama.app", text: $step.text)
        case .delay:
            TextField("", value: $step.delayMs, format: .number).frame(width: 70)
            Text("ms")
        case .click:
            Picker("", selection: $step.mouse) {
                ForEach(MouseButtonKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }
}
