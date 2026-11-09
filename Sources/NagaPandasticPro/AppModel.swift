import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import IOKit.hid
import ApplicationServices
import UniformTypeIdentifiers
import Carbon

// MARK: - Kalıcı depolama

enum ConfigStorage {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NagaPandasticPro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { folder.appendingPathComponent("config.json") }

    static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) { return config }
        // Okunamayan dosyayı yedekle, üzerine yazılmasın
        let backup = folder.appendingPathComponent("config-yedek-\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: backup)
        return nil
    }

    static func encode(_ value: some Encodable) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    static func save(_ config: AppConfig) {
        guard let data = encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - İzinler

final class PermissionsModel: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    private var timer: Timer?

    var allGranted: Bool { accessibility && inputMonitoring }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if ax != accessibility { accessibility = ax }
        if im != inputMonitoring { inputMonitoring = im }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPane("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openPane("Privacy_ListenEvent")
    }

    func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Ana model

final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Layer: String, CaseIterable, Identifiable {
        case base, shift
        var id: String { rawValue }
        var title: String { self == .base ? "Normal" : "Hypershift" }
    }

    @Published var config: AppConfig {
        didSet { configDidChange(from: oldValue) }
    }
    @Published private(set) var activeProfileID: UUID
    @Published private(set) var engineStatus = InputEngine.Status()
    @Published private(set) var recentButton: ButtonID?
    @Published private(set) var isLearning = false
    @Published private(set) var learnedButton: ButtonID?

    let engine = InputEngine()
    let razer = RazerController()
    let permissions = PermissionsModel()

    private var saveWork: DispatchWorkItem?
    private var lightingWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var frontmostBundleID: String?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {
        let loaded = ConfigStorage.load() ?? AppConfig.makeDefault()
        config = loaded
        activeProfileID = loaded.selectedProfileID
    }

    // MARK: Başlatma

    func start() {
        guard !started else { return }
        started = true

        engine.onStatusChange = { [weak self] s in self?.engineStatus = s }
        engine.onButtonActivity = { [weak self] id in self?.flash(id) }
        engine.runner.onNextProfile = { [weak self] in self?.cycleProfile() }
        engine.runner.onSetProfile = { [weak self] id in self?.selectProfile(id) }
        engine.runner.onSetDPI = { [weak self] value in self?.razer.setDPI(value) }

        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
            self?.recomputeActiveProfile()
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                KeyNames.resetCache()
                self?.objectWillChange.send()
            })

        recomputeActiveProfile()
        pushToEngine()
        engine.start()
        razer.start()
        applyHardware(for: activeProfile)
        applyDockPolicy()
    }

    // MARK: Profiller

    var activeProfile: Profile {
        config.profiles.first { $0.id == activeProfileID } ?? config.profiles[0]
    }

    var selectedProfile: Profile {
        config.profiles.first { $0.id == config.selectedProfileID } ?? config.profiles[0]
    }

    func profileIndex(_ id: UUID) -> Int? {
        config.profiles.firstIndex { $0.id == id }
    }

    func updateSelectedProfile(_ change: (inout Profile) -> Void) {
        guard let i = profileIndex(config.selectedProfileID) else { return }
        change(&config.profiles[i])
    }

    func selectProfile(_ id: UUID) {
        guard profileIndex(id) != nil else { return }
        config.selectedProfileID = id
    }

    func cycleProfile() {
        guard let i = profileIndex(config.selectedProfileID), !config.profiles.isEmpty else { return }
        config.selectedProfileID = config.profiles[(i + 1) % config.profiles.count].id
    }

    @discardableResult
    func addProfile(copying source: Profile? = nil) -> UUID {
        var p = source ?? Profile(name: "Yeni profil")
        p.id = UUID()
        if source != nil {
            p.name += " (kopya)"
            p.appBundleIDs = []
        }
        config.profiles.append(p)
        config.selectedProfileID = p.id
        return p.id
    }

    func deleteProfile(_ id: UUID) {
        guard config.profiles.count > 1, let i = profileIndex(id) else { return }
        config.profiles.remove(at: i)
        if !config.profiles.contains(where: { $0.id == config.selectedProfileID }) {
            config.selectedProfileID = config.profiles[0].id
        }
    }

    // MARK: Tuş atamaları

    func action(for id: ButtonID, layer: Layer, profileID: UUID) -> ButtonAction {
        guard let i = profileIndex(profileID) else { return ButtonAction() }
        let p = config.profiles[i]
        return (layer == .base ? p.bindings[id.key] : p.shiftBindings[id.key]) ?? ButtonAction()
    }

    func setAction(_ action: ButtonAction, for id: ButtonID, layer: Layer, profileID: UUID) {
        guard let i = profileIndex(profileID) else { return }
        let value: ButtonAction? = action == ButtonAction() ? nil : action
        switch layer {
        case .base: config.profiles[i].bindings[id.key] = value
        case .shift: config.profiles[i].shiftBindings[id.key] = value
        }
    }

    func renameSlot(_ id: ButtonID, to name: String) {
        guard let i = config.buttons.firstIndex(where: { $0.id == id }) else { return }
        config.buttons[i].name = name
    }

    func removeSlot(_ id: ButtonID) {
        config.buttons.removeAll { $0.id == id && $0.group == .learned }
        for i in config.profiles.indices {
            config.profiles[i].bindings[id.key] = nil
            config.profiles[i].shiftBindings[id.key] = nil
        }
    }

    // MARK: Öğrenme modu

    func startLearning() {
        isLearning = true
        learnedButton = nil
        engine.beginLearning { [weak self] id in self?.finishLearning(id) }
    }

    func cancelLearning() {
        isLearning = false
        engine.cancelLearning()
    }

    private func finishLearning(_ id: ButtonID) {
        isLearning = false
        if !config.buttons.contains(where: { $0.id == id }) {
            let name: String
            if id.usagePage == ButtonID.keyboardPage {
                name = "Tuş \(HIDKeyMap.name(forHIDUsage: id.usage))"
            } else {
                name = "Fare tuşu \(id.usage)"
            }
            config.buttons.append(ButtonSlot(id: id, name: name, group: .learned))
        }
        learnedButton = id
    }

    private func flash(_ id: ButtonID) {
        recentButton = id
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.recentButton == id { self?.recentButton = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Değişiklik akışı

    private func configDidChange(from old: AppConfig) {
        scheduleSave()
        let previousActive = old.profiles.first { $0.id == activeProfileID }
        recomputeActiveProfile()
        pushToEngine()

        let current = activeProfile
        if let previousActive, previousActive.id == current.id {
            if previousActive.lighting != current.lighting { scheduleLighting(current.lighting) }
            if previousActive.applyDPI != current.applyDPI || previousActive.dpiValue != current.dpiValue,
               current.applyDPI {
                razer.setDPI(current.dpiValue)
            }
        }
        if old.showDockIcon != config.showDockIcon { applyDockPolicy() }
    }

    private func recomputeActiveProfile() {
        var target = config.selectedProfileID
        if config.autoSwitchByApp, let bundle = frontmostBundleID,
           let match = config.profiles.first(where: { $0.appBundleIDs.contains(bundle) }) {
            target = match.id
        }
        if !config.profiles.contains(where: { $0.id == target }) {
            target = config.profiles[0].id
        }
        if target != activeProfileID {
            activeProfileID = target
            pushToEngine()
            applyHardware(for: activeProfile)
        }
    }

    private func pushToEngine() {
        engine.update(profile: activeProfile, enabled: config.enabled)
    }

    private func applyHardware(for profile: Profile) {
        razer.apply(lighting: profile.lighting)
        if profile.applyDPI { razer.setDPI(profile.dpiValue) }
    }

    func reapplyLighting() {
        razer.apply(lighting: activeProfile.lighting)
    }

    private func scheduleLighting(_ lighting: LightingConfig) {
        lightingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.razer.apply(lighting: lighting) }
        lightingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { ConfigStorage.save(snapshot) }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(config.showDockIcon ? .regular : .accessory)
    }

    // MARK: Girişte başlat

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("NagaPandasticPro: giriş öğesi değiştirilemedi: \(error)")
            }
            objectWillChange.send()
        }
    }

    // MARK: Dışa / içe aktarma

    func exportProfile(_ profile: Profile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).nagaprofile.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = ConfigStorage.encode(profile) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  var p = try? JSONDecoder().decode(Profile.self, from: data) else { continue }
            p.id = UUID()
            config.profiles.append(p)
        }
    }
}
