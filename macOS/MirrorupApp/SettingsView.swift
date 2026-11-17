import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Camera") {
                Picker("Source", selection: $model.source) {
                    ForEach(CameraSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Toggle("Start streaming when Mirrorup opens", isOn: $model.autoStartStreaming)
            }

            Section("Camera extension") {
                ExtensionSettingsRow(manager: model.extensionManager)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtensionSettingsRow: View {
    let manager: ExtensionManager

    var body: some View {
        LabeledContent("Status") {
            Text(manager.state.summary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        if manager.state == .awaitingApproval {
            Text(ExtensionManager.approvalInstructions)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open System Settings") { manager.openApprovalSettings() }
        }
        HStack {
            Button(manager.state == .active ? "Reinstall" : "Install") { manager.activate() }
                .disabled(isBusy)
            Button("Uninstall", role: .destructive) { manager.deactivate() }
                .disabled(isBusy || manager.state == .notInstalled)
            Spacer()
            Button("Refresh") { manager.refresh() }
                .disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        manager.state == .activating || manager.state == .deactivating || manager.state == .checking
    }
}
