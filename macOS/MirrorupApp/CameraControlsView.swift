import AppKit
import MirrorupCapture
import SwiftUI

/// Camera controls in the popover: a compact row (autofocus, brightness, battery, shutter) and a
/// "Picture" disclosure for everything else. Only what the camera offers in its current mode is shown.
/// Values are read when the popover opens and after each change; nothing is polled.
struct CameraControlsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuickControls(model: model)
            PictureControls(model: model)
            if let message = model.controlMessage {
                ControlMessageView(message: message)
            }
        }
        .disabled(model.isApplyingControl)
    }
}

// MARK: - Quick row

private struct QuickControls: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.controlState?.canAutofocus == true {
                Button("Focus", systemImage: "viewfinder") { model.autofocus() }
                    .labelStyle(.iconOnly)
                    .help("Autofocus. Click the preview to focus on a spot.")
            }
            if let brightness = model.controlState?.adjustable(.exposureCompensation) {
                BrightnessSlider(model: model, options: brightness.options, current: brightness.current)
            } else {
                Spacer()
            }
            BatteryBadge(level: model.controlState?.battery, isLow: model.controlState?.batteryIsLow == true,
                         shotsRemaining: model.controlState?.shotsRemaining)
            if model.controlState?.canCapturePhoto == true {
                Button("Take Photo", systemImage: "camera.circle") { model.capturePhoto() }
                    .labelStyle(.iconOnly)
                    .help("Take a full-resolution photo and save it to Pictures › Mirrorup")
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}

/// Discrete exposure-compensation steps; applied when the user lets go, not on every step.
private struct BrightnessSlider: View {
    let model: AppModel
    let options: [CameraSettingOption]
    let current: CameraSettingOption?
    @State private var index = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $index, in: 0...Double(max(options.count - 1, 1)), step: 1) { editing in
                guard !editing, options.indices.contains(Int(index)) else { return }
                model.set(.exposureCompensation, to: options[Int(index)])
            }
            .accessibilityLabel("Brightness")
            .accessibilityValue(options.indices.contains(Int(index)) ? options[Int(index)].title : "")
            Text(options.indices.contains(Int(index)) ? options[Int(index)].title : "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .onChange(of: current?.value, initial: true) { _, value in
            index = Double(options.firstIndex { $0.value == value } ?? options.count / 2)
        }
    }
}

private struct BatteryBadge: View {
    let level: String?
    let isLow: Bool
    let shotsRemaining: Int?

    var body: some View {
        if let level {
            Label {
                Text(level)
            } icon: {
                Image(systemName: isLow ? "battery.25percent" : "battery.100percent")
                    .foregroundStyle(isLow ? .red : .secondary)
            }
            .font(.caption)
            .foregroundStyle(isLow ? .red : .secondary)
            .labelStyle(.iconOnly)
            .help(shotsRemaining.map { "Battery: \(level) · \($0) shots remaining" } ?? "Battery: \(level)")
        }
    }
}

// MARK: - Picture disclosure

private struct PictureControls: View {
    @Bindable var model: AppModel
    @State private var isExpanded = false

    private static let settings: [CameraSetting] = [
        .aperture, .shutterSpeed, .iso, .whiteBalance, .colorTemperature, .pictureStyle, .autofocusMethod,
    ]

    var body: some View {
        DisclosureGroup("Picture", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.settings, id: \.self) { setting in
                    if let state = model.controlState?.adjustable(setting) {
                        SettingPicker(model: model, setting: setting, options: state.options)
                    }
                }
                if model.controlState?.zoom != nil {
                    Picker("Zoom", selection: $model.zoomSelection) {
                        ForEach(CameraZoom.allCases, id: \.self) { zoom in
                            Text(zoom.title).tag(zoom)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Magnify the camera image. While zoomed, click the preview to move the zoomed area.")
                }
                if model.controlState?.adjustable(.autofocusMethod) != nil, model.controlState?.canFocusAtPoint == false {
                    Text("Choose 1-point AF in Focus Mode to focus by clicking the preview, and to zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Mirror", isOn: $model.mirrored)
                Toggle("Upside Down", isOn: $model.upsideDown)
                    .help("For a camera mounted upside down")
                if model.controlState?.settings.values.contains(where: \.isAdjustable) == false {
                    Text("Set the camera's mode dial to P, Av, Tv or M for exposure and color controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }
}

private struct SettingPicker: View {
    @Bindable var model: AppModel
    let setting: CameraSetting
    let options: [CameraSettingOption]

    var body: some View {
        Picker(setting.title, selection: $model[setting: setting]) {
            ForEach(options) { option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.menu)
    }
}

// MARK: - Outcome

private struct ControlMessageView: View {
    let message: AppModel.ControlMessage

    var body: some View {
        HStack {
            Label(message.text, systemImage: message.kind == .success ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(message.kind == .success ? Color.secondary : Color.red)
                .lineLimit(2)
            if let url = message.fileURL {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .font(.caption)
                    .buttonStyle(.link)
            }
        }
    }
}
