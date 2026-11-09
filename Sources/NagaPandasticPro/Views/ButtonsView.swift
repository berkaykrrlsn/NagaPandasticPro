import SwiftUI

struct ButtonsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: ButtonID? = ButtonID(usagePage: ButtonID.keyboardPage, usage: 0x1E)
    @State private var layer: AppModel.Layer = .base

    private var profileID: UUID { model.config.selectedProfileID }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sideGrid
                    otherButtons
                    learnBox
                }
                .padding(20)
            }
            .frame(width: 340)

            Divider()

            Group {
                if let sel = selected, let slot = model.config.buttons.first(where: { $0.id == sel }) {
                    ActionEditor(slot: slot, layer: layer, action: actionBinding(sel))
                        .id("\(sel.key)-\(layer.rawValue)-\(profileID.uuidString)")
                } else {
                    ContentUnavailableView("Bir tuş seçin", systemImage: "hand.point.up.left",
                                           description: Text("Soldan düzenlemek istediğiniz tuşa tıklayın."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(model.$learnedButton.compactMap { $0 }) { id in selected = id }
    }

    private func actionBinding(_ id: ButtonID) -> Binding<ButtonAction> {
        Binding(
            get: { model.action(for: id, layer: layer, profileID: profileID) },
            set: { model.setAction($0, for: id, layer: layer, profileID: profileID) }
        )
    }

    // MARK: Bölümler

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Profil", selection: $model.config.selectedProfileID) {
                ForEach(model.config.profiles) { Text($0.name).tag($0.id) }
            }
            Picker("Katman", selection: $layer) {
                ForEach(AppModel.Layer.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if layer == .shift {
                Text("Hypershift katmanı: “Hypershift” atanmış bir tuşu basılı tutarken geçerli olan atamalar. Boş bırakılan tuşlar normal katmanı kullanır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sideGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Yan tuş paneli").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.config.buttons.filter { $0.group == .side }) { slot in
                    ButtonTile(slot: slot,
                               action: model.action(for: slot.id, layer: layer, profileID: profileID),
                               isSelected: selected == slot.id,
                               isFlashing: model.recentButton == slot.id)
                        .onTapGesture { selected = slot.id }
                }
            }
        }
    }

    private var otherButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diğer tuşlar").font(.headline)
            ForEach(model.config.buttons.filter { $0.group != .side }) { slot in
                let action = model.action(for: slot.id, layer: layer, profileID: profileID)
                HStack {
                    Image(systemName: slot.group == .learned ? "sparkles" : "computermouse")
                        .frame(width: 18)
                    Text(slot.name)
                    Spacer()
                    Text(action.summary)
                        .font(.caption)
                        .foregroundStyle(action.kind == .passthrough ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected == slot.id ? Color.accentColor.opacity(0.22)
                              : model.recentButton == slot.id ? Color.green.opacity(0.25)
                              : Color.secondary.opacity(0.08))
                )
                .contentShape(Rectangle())
                .onTapGesture { selected = slot.id }
            }
        }
    }

    private var learnBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLearning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Naga üzerinde bir tuşa basın…")
                    Spacer()
                    Button("İptal") { model.cancelLearning() }
                }
            } else {
                Button {
                    model.startLearning()
                } label: {
                    Label("Tuş öğren (listede olmayan tuş ekle)", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            Text("Yan panel değiştirildiyse (6 veya 2 tuşlu) ya da Naga farklı kod gönderiyorsa, tuşu buradan tanıtın.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

struct ButtonTile: View {
    let slot: ButtonSlot
    let action: ButtonAction
    let isSelected: Bool
    let isFlashing: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(slot.name).font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                if action.kind != .passthrough {
                    Image(systemName: action.kind.symbol).font(.caption)
                }
            }
            Text(action.kind == .passthrough ? "—" : action.summary)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(action.kind == .passthrough ? Color.secondary : Color.primary)
        }
        .padding(8)
        .frame(height: 74)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFlashing ? Color.green.opacity(0.35)
                      : isSelected ? Color.accentColor.opacity(0.25)
                      : Color.secondary.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isFlashing)
    }
}
