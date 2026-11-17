import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Picker("Camera", selection: $model.source) {
                    ForEach(CameraSource.allCases) { source in
                        Text(model.title(for: source)).tag(source)
                    }
                }
                Toggle("Start streaming when Mirrorup opens", isOn: $model.autoStartStreaming)
                Toggle("Open at login", isOn: $model.opensAtLogin)
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if model.loginItemStatus == .requiresApproval {
                    Text("Allow Mirrorup in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ExtensionSettings(manager: model.extensionManager)
            } header: {
                Text("Mirrorup Camera")
            } footer: {
                Text("The camera extension publishes “Mirrorup Camera” to FaceTime, browsers and other video apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 330)
        .task { model.refreshSystemPermissions() }
    }
}

private struct ExtensionSettings: View {
    let manager: ExtensionManager

    var body: some View {
        LabeledContent("Status", value: manager.state.summary)
        if manager.state == .awaitingApproval {
            LabeledContent {
                Button("Open System Settings") { manager.openApprovalSettings() }
            } label: {
                Text(ExtensionManager.approvalInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabeledContent("Manage") {
            HStack {
                Button(manager.state == .active ? "Reinstall" : "Install") { manager.activate() }
                Button("Uninstall", role: .destructive) { manager.deactivate() }
                    .disabled(manager.state == .notInstalled)
            }
            .disabled(manager.isBusy)
        }
        .task { manager.refresh() }
    }
}
