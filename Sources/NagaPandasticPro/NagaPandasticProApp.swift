import SwiftUI
import AppKit

@main
struct NagaPandasticProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("NagaPandasticPro", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.razer)
                .environmentObject(model.permissions)
                .frame(minWidth: 980, minHeight: 660)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.razer)
        } label: {
            Image(systemName: "computermouse.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// Pencere kapansa da menü çubuğunda çalışmaya devam et
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var razer: RazerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Tuş atamaları etkin", isOn: $model.config.enabled)
        Divider()
        Picker("Profil", selection: $model.config.selectedProfileID) {
            ForEach(model.config.profiles) { p in
                Text(p.name).tag(p.id)
            }
        }
        if model.activeProfileID != model.config.selectedProfileID {
            Text("Şu an etkin: \(model.activeProfile.name) (uygulamaya göre)")
        }
        Divider()
        if razer.isConnected {
            Text(razer.deviceName)
            if let b = razer.batteryPercent {
                Text("Pil: %\(b)\(razer.isCharging ? " · şarj oluyor" : "")")
            }
        } else {
            Text("Naga bağlı değil")
        }
        Divider()
        Button("NagaPandasticPro'u aç…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Çıkış") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Ana pencere

enum SidebarItem: String, CaseIterable, Identifiable {
    case buttons, lighting, profiles, performance, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .buttons: return "Tuş Atamaları"
        case .lighting: return "Aydınlatma"
        case .profiles: return "Profiller"
        case .performance: return "DPI & Cihaz"
        case .settings: return "Ayarlar & İzinler"
        }
    }
    var symbol: String {
        switch self {
        case .buttons: return "square.grid.3x3.fill"
        case .lighting: return "paintpalette.fill"
        case .profiles: return "person.2.fill"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var permissions: PermissionsModel
    @EnvironmentObject var razer: RazerController
    @State private var selection: SidebarItem? = .buttons

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            VStack(spacing: 0) {
                if !permissions.allGranted {
                    PermissionBanner { selection = .settings }
                }
                switch selection ?? .buttons {
                case .buttons: ButtonsView()
                case .lighting: LightingView()
                case .profiles: ProfilesView()
                case .performance: PerformanceView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(selection?.title ?? "NagaPandasticPro")
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(razer.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(razer.isConnected ? razer.deviceName : "Naga bağlı değil")
                    .font(.caption).lineLimit(1)
            }
            if let b = razer.batteryPercent {
                Label("%\(b)\(razer.isCharging ? " ⚡︎" : "")", systemImage: Self.batterySymbol(b))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Profil: \(model.activeProfile.name)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    static func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var permissions: PermissionsModel
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("İzin gerekli").font(.headline)
                Text("Tuş atamalarının çalışması için Erişilebilirlik ve Girdi İzleme izinleri verilmeli.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("İzinleri ayarla", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}
