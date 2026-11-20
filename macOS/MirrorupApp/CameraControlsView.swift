import AppKit
import MirrorupCapture
import SwiftUI

/// Camera controls in the popover, as one two-column grid (trailing labels, equal-width controls)
/// followed by the Focus / Take Photo buttons. Only what the camera offers in its current mode is
/// shown. Values are read when the popover opens and after each change; nothing is polled.
struct CameraControlsView: View {
    @Bindable var model: AppModel

    private static let pickers: [CameraSetting] = [
        .whiteBalance, .colorTemperature, .imageStyle, .aperture, .shutterSpeed, .iso, .autofocusMethod,
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
                                RowLabel(state.title)
                                SettingPicker(model: model, state: state)
                                    .disabled(model.isApplyingControl)
                            }
                        }
                    }
                    if let levels = model.controlState?.zoomLevels, levels.count > 1, model.controlState?.zoom != nil {
                        GridRow {
                            RowLabel("Zoom")
                            Picker("Zoom", selection: $model.zoomSelection) {
                                ForEach(levels, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .disabled(model.isApplyingControl)
                            .help("Magnify the camera image. While zoomed, click the preview to move the zoomed area.")
                        }
                    }
                    if model.canShowLiveViewOnCamera {
                        GridRow {
                            RowLabel("Live View")
                            Toggle("Show on Camera Screen", isOn: $model.showsLiveViewOnCamera)
                                .help("Keep the picture on the camera's screen while streaming. Uses more battery.")
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
                if model.isEnhanceSupported {
                    GridRow {
                        RowLabel("Detail")
                        Toggle("Enhance", isOn: $model.enhance)
                            .help("Sharpen the picture with Apple's machine-learning upscaler. Adds about 12 ms of latency per frame.")
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

    /// One line from the backend on what is locked and how to unlock it; why photos are off first.
    private var hint: String? {
        model.controlState.flatMap { $0.photoUnavailableReason ?? $0.hint }
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

/// Discrete exposure-compensation steps; applied when the user lets go, not on every step. The
/// position follows the camera's value except while dragging, so a refused change snaps back.
private struct BrightnessSlider: View {
    let model: AppModel
    let options: [CameraSettingOption]
    let current: CameraSettingOption?
    @State private var dragIndex: Double?

    private var currentIndex: Double {
        Double(options.firstIndex { $0.value == current?.value } ?? options.count / 2)
    }

    private var index: Double { dragIndex ?? currentIndex }

    private var title: String {
        options.indices.contains(Int(index)) ? options[Int(index)].title : "–"
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { index }, set: { dragIndex = $0 }),
                   in: 0...Double(max(options.count - 1, 1)), step: 1) { editing in
                guard !editing, let dragged = dragIndex else { return }
                dragIndex = nil
                let i = Int(dragged)
                guard options.indices.contains(i), options[i].value != current?.value else { return }
                model.set(.exposureCompensation, to: options[i])
            }
            .labelsHidden()
            .accessibilityLabel("Brightness")
            .accessibilityValue(title)
            Text(title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}

private struct SettingPicker: View {
    @Bindable var model: AppModel
    let state: CameraSettingState

    var body: some View {
        Picker(state.title, selection: $model[setting: state.setting]) {
            // The camera can report a current value outside the list it offers (or none); show it
            // rather than a blank popup.
            if let current = state.current, !state.options.contains(current) {
                Text(current.title).tag(UInt32?.some(current.value))
            } else if state.current == nil {
                Text("—").tag(UInt32?.none)
            }
            ForEach(state.options) { Text($0.title).tag(UInt32?.some($0.value)) }
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
                        .help("Autofocus. Click the preview to focus on a spot, where the camera's focus mode allows it.")
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
                .accessibilityLabel("Battery \(text)\(isLow ? ", low" : "")")
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
