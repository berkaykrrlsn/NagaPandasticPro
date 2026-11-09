import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { Optional(model.config.selectedProfileID) },
                                        set: { if let id = $0 { model.selectProfile(id) } })) {
                    ForEach(model.config.profiles) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if p.id == model.activeProfileID {
                                Text("etkin").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.25)))
                            }
                            if !p.appBundleIDs.isEmpty {
                                Image(systemName: "app.connected.to.app.below.fill").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { _ = model.addProfile() } label: { Image(systemName: "plus") }
                        .help("Yeni profil")
                    Button { _ = model.addProfile(copying: model.selectedProfile) } label: { Image(systemName: "plus.square.on.square") }
                        .help("Seçili profili çoğalt")
                    Button { model.deleteProfile(model.config.selectedProfileID) } label: { Image(systemName: "minus") }
                        .help("Profili sil")
                        .disabled(model.config.profiles.count <= 1)
                    Spacer()
                    Menu {
                        Button("Profili dışa aktar…") { model.exportProfile(model.selectedProfile) }
                        Button("Profil içe aktar…") { model.importProfile() }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 240)

            Divider()

            ProfileDetail()
                .id(model.config.selectedProfileID)
        }
    }
}

private struct ProfileDetail: View {
    @EnvironmentObject var model: AppModel

    private var profile: Binding<Profile> {
        Binding(get: { model.selectedProfile },
                set: { newValue in model.updateSelectedProfile { $0 = newValue } })
    }

    var body: some View {
        Form {
            Section("Profil") {
                TextField("Ad", text: profile.name)
                LabeledContent("Atanmış tuş") {
                    Text("\(profile.wrappedValue.bindings.count) normal · \(profile.wrappedValue.shiftBindings.count) Hypershift")
                }
            }

            Section {
                Toggle("Öndeki uygulamaya göre profili otomatik değiştir", isOn: $model.config.autoSwitchByApp)
                if profile.wrappedValue.appBundleIDs.isEmpty {
                    Text("Bu profile bağlı uygulama yok.").foregroundStyle(.secondary)
                }
                ForEach(profile.wrappedValue.appBundleIDs, id: \.self) { bundleID in
                    HStack {
                        AppIconView(bundleID: bundleID)
                        Spacer()
                        Button(role: .destructive) {
                            profile.wrappedValue.appBundleIDs.removeAll { $0 == bundleID }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Uygulama ekle…", action: addApp)
                    Menu("Açık olanlardan") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "?") {
                                if let id = app.bundleIdentifier, !profile.wrappedValue.appBundleIDs.contains(id) {
                                    profile.wrappedValue.appBundleIDs.append(id)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Uygulamaya özel profil")
            } footer: {
                Text("Örneğin bir oyun ya da Photoshop öne geldiğinde bu profil (tuşlar, ışık ve DPI) otomatik devreye girer; uygulamadan çıkınca seçili profile dönülür.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !profile.wrappedValue.appBundleIDs.contains(id) {
                profile.wrappedValue.appBundleIDs.append(id)
            }
        }
    }
}

struct AppIconView: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 22, height: 22)
                Text(url.deletingPathExtension().lastPathComponent)
            } else {
                Image(systemName: "questionmark.app").frame(width: 22, height: 22)
                Text(bundleID)
            }
        }
    }
}
