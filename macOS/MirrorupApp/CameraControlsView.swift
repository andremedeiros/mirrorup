import AppKit
import MirrorupCapture
import SwiftUI

/// Camera controls in the popover, as one two-column grid (trailing labels, equal-width controls)
/// followed by the Focus / Take Photo buttons. Only what the camera offers in its current mode is
/// shown. Values are read when the popover opens and after each change; nothing is polled.
struct CameraControlsView: View {
    @Bindable var model: AppModel

    private static let pickers: [CameraSetting] = [
        .whiteBalance, .colorTemperature, .pictureStyle, .aperture, .shutterSpeed, .iso, .autofocusMethod,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    if let brightness = model.controlState?.adjustable(.exposureCompensation) {
                        GridRow {
                            RowLabel(CameraSetting.exposureCompensation.title)
                            BrightnessSlider(model: model, options: brightness.options, current: brightness.current)
                                .disabled(model.isApplyingControl)
                        }
                    }
                    ForEach(Self.pickers, id: \.self) { setting in
                        if let state = model.controlState?.adjustable(setting) {
                            GridRow {
                                RowLabel(setting.title)
                                SettingPicker(model: model, setting: setting, options: state.options)
                                    .disabled(model.isApplyingControl)
                            }
                        }
                    }
                    if model.controlState?.zoom != nil {
                        GridRow {
                            RowLabel("Zoom")
                            Picker("Zoom", selection: $model.zoomSelection) {
                                ForEach(CameraZoom.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .disabled(model.isApplyingControl)
                            .help("Magnify the camera image. While zoomed, click the preview to move the zoomed area.")
                        }
                    }
                // App-side, so usable while a camera command runs.
                GridRow {
                    RowLabel("Image")
                    HStack(spacing: 14) {
                        Toggle("Mirror", isOn: $model.mirrored)
                        Toggle("Upside Down", isOn: $model.upsideDown)
                            .help("For a camera mounted upside down")
                    }
                }
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ActionRow(model: model)
        }
        .controlSize(.small)
    }

    /// One line explaining what is missing, most specific first.
    private var hint: String? {
        guard let state = model.controlState else { return nil }
        if let reason = state.photoUnavailableReason { return reason }
        if !state.settings.values.contains(where: \.isAdjustable)
            || state.adjustable(.exposureCompensation) == nil {
            return "Set the camera's mode dial to P, Av, Tv or M for exposure and color controls."
        }
        if state.adjustable(.autofocusMethod) != nil, state.canAutofocus, !state.canFocusAtPoint {
            return "Choose 1-point AF in Focus Mode to focus by clicking the preview, and to zoom."
        }
        return nil
    }
}

private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .lineLimit(1)
    }
}

/// Discrete exposure-compensation steps; applied when the user lets go, not on every step.
private struct BrightnessSlider: View {
    let model: AppModel
    let options: [CameraSettingOption]
    let current: CameraSettingOption?
    @State private var index = 0.0

    private var title: String {
        options.indices.contains(Int(index)) ? options[Int(index)].title : "–"
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $index, in: 0...Double(max(options.count - 1, 1)), step: 1) { editing in
                guard !editing, options.indices.contains(Int(index)) else { return }
                model.set(.exposureCompensation, to: options[Int(index)])
            }
            .labelsHidden()
            .accessibilityLabel("Brightness")
            .accessibilityValue(title)
            Text(title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .onChange(of: current?.value, initial: true) { _, value in
            index = Double(options.firstIndex { $0.value == value } ?? options.count / 2)
        }
    }
}

private struct SettingPicker: View {
    @Bindable var model: AppModel
    let setting: CameraSetting
    let options: [CameraSettingOption]

    var body: some View {
        Picker(setting.title, selection: $model[setting: setting]) {
            ForEach(options) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // Every popup spans the column, so the column reads as one edge, not a ragged stack.
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Actions

/// Focus and Take Photo as two equal buttons across the popover, the last outcome underneath.
private struct ActionRow: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.controlState?.canAutofocus == true {
                    Button("Focus", systemImage: "viewfinder") { model.autofocus() }
                        .help("Autofocus. In 1-point AF, click the preview to focus on a spot.")
                }
                if model.controlState?.canCapturePhoto == true {
                    Button("Take Photo", systemImage: "camera") { model.capturePhoto() }
                        .help("Take a full-resolution photo and save it to Pictures › Mirrorup")
                }
            }
            .buttonSizing(.flexible)
            .disabled(model.isApplyingControl)
            .controlSize(.regular)

            if let message = model.controlMessage {
                ControlMessageView(message: message)
            }
        }
    }
}

/// "100% · 5154 shots", shown on the preview like a camera's own screen.
struct BatteryLabel: View {
    let state: CameraControlState?

    var body: some View {
        if let level = state?.battery {
            let isLow = state?.batteryIsLow == true
            let text = state?.shotsRemaining.map { "\(level) · \($0) shots" } ?? level
            Label(text, systemImage: isLow ? "battery.25percent" : "battery.100percent")
                .monospacedDigit()
                .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .accessibilityLabel("Battery \(text)")
        }
    }
}

private struct ControlMessageView: View {
    let message: AppModel.ControlMessage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(message.kind == .success ? Color.green : Color.orange)
            Text(message.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let url = message.fileURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }
}
