import SwiftUI
import AppKit

struct PerformanceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var razer: RazerController

    private var profile: Binding<Profile> {
        Binding(get: { model.selectedProfile },
                set: { newValue in model.updateSelectedProfile { $0 = newValue } })
    }

    var body: some View {
        Form {
            Section("Cihaz") {
                LabeledContent("Durum") {
                    HStack(spacing: 6) {
                        Circle().fill(razer.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(razer.isConnected ? "Bağlı" : "Bağlı değil")
                    }
                }
                if razer.isConnected {
                    LabeledContent("Model", value: razer.deviceName)
                    LabeledContent("Ürün kimliği", value: String(format: "0x%04X", razer.productID))
                    LabeledContent("Yazılım", value: razer.firmware)
                    LabeledContent("Pil") {
                        if let b = razer.batteryPercent {
                            HStack {
                                ProgressView(value: Double(b), total: 100).frame(width: 120)
                                Text("%\(b)\(razer.isCharging ? " · şarj oluyor" : "")")
                            }
                        } else {
                            Text("—")
                        }
                    }
                }
                Text(razer.message).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Yeniden tara") { razer.rescan() }
                    Button("Pili yenile") { razer.refreshBattery() }.disabled(!razer.isConnected)
                }
            }

            Section {
                Toggle("Bu profil etkinleşince DPI'ı ayarla", isOn: profile.applyDPI)
                DPIControl(value: profile.dpiValue)
                    .disabled(!profile.wrappedValue.applyDPI)
                Button("Şimdi uygula") { razer.setDPI(profile.wrappedValue.dpiValue) }
                    .disabled(!razer.isConnected)
            } header: {
                Text("DPI · \(model.selectedProfile.name)")
            } footer: {
                Text("İpucu: Bir tuşa “DPI ayarla” eylemi atayarak (ör. basılı tutunca 400 DPI) keskin nişancı modu yapabilirsiniz. Farenin üstündeki DPI tuşları donanımda çalışır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var permissions: PermissionsModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Erişilebilirlik",
                              detail: "Tuşları yakalamak ve kısayol/tıklama göndermek için.",
                              granted: permissions.accessibility,
                              request: permissions.requestAccessibility)
                PermissionRow(title: "Girdi İzleme",
                              detail: "Basılan tuşun Naga'dan mı yoksa klavyeden mi geldiğini ayırt etmek için.",
                              granted: permissions.inputMonitoring,
                              request: permissions.requestInputMonitoring)
                HStack {
                    Text("İzin verdikten sonra uygulamayı yeniden başlatmanız gerekebilir.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Yeniden başlat") { permissions.relaunch() }
                }
            } header: {
                Text("İzinler")
            }

            Section("Motor") {
                Toggle("Tuş atamaları etkin", isOn: $model.config.enabled)
                StatusRow(title: "HID dinleyici", ok: model.engineStatus.hidActive)
                StatusRow(title: "Olay yakalayıcı (event tap)", ok: model.engineStatus.tapActive)
                StatusRow(title: "Naga'dan tuş algılandı", ok: model.engineStatus.nagaSeen)
            }

            Section("Genel") {
                Toggle("Oturum açılışında başlat", isOn: Binding(get: { model.launchAtLogin },
                                                                  set: { model.launchAtLogin = $0 }))
                Toggle("Dock'ta göster", isOn: $model.config.showDockIcon)
                Text("Pencere kapatıldığında NagaPandasticPro menü çubuğunda çalışmaya devam eder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Veriler") {
                LabeledContent("Ayar dosyası") {
                    Text(ConfigStorage.fileURL.path).font(.caption).textSelection(.enabled)
                }
                Button("Finder'da göster") {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStorage.fileURL])
                }
            }

            Section {
                Text("NagaPandasticPro, Razer ile bağlantılı olmayan bağımsız bir araçtır. Razer Synapse çalışıyorsa kapatın; iki uygulama aynı anda cihazı yönetmeye çalışabilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.seal.fill" : "xmark.seal.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
                .font(.title3)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("İzin ver…", action: request).buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool

    var body: some View {
        LabeledContent(title) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ok ? Color.green : Color.secondary)
        }
    }
}
