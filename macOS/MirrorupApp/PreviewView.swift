import AppKit
import AVFoundation
import CoreMedia
import MirrorupDiagnostics
import os
import SwiftUI

/// Shows the frames being published, newest only. Frames are submitted from the forwarding task;
/// at most one main-queue hop is outstanding and it always renders the newest pending frame, so a
/// busy main thread drops preview frames instead of building a backlog.
@MainActor
final class PreviewRenderer {
    private struct Pending {
        var sampleBuffer: CMSampleBuffer?
        var drainScheduled = false
        var attached = false
    }

    private var renderedSinceAttach = 0

    nonisolated private let pending = OSAllocatedUnfairLock(uncheckedState: Pending())
    private var layer: AVSampleBufferDisplayLayer?

    nonisolated init() {}

    nonisolated func submit(_ sampleBuffer: CMSampleBuffer) {
        let schedule = pending.withLockUnchecked { state -> Bool in
            guard state.attached else { return false }
            state.sampleBuffer = sampleBuffer
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.drain() }
        }
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        renderedSinceAttach = 0
        pending.withLockUnchecked { $0.attached = true }
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        guard self.layer === layer else { return }
        self.layer = nil
        pending.withLockUnchecked { state in
            state.attached = false
            state.sampleBuffer = nil
        }
    }

    private func drain() {
        let sampleBuffer = pending.withLockUnchecked { state -> CMSampleBuffer? in
            state.drainScheduled = false
            defer { state.sampleBuffer = nil }
            return state.sampleBuffer
        }
        guard let sampleBuffer, let layer else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            Diagnostics.app.error("Preview renderer failed: \(renderer.error?.localizedDescription ?? "unknown", privacy: .public); flushing")
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
        renderedSinceAttach += 1
        if renderedSinceAttach == 1 {
            Diagnostics.app.info("Preview rendering (first frame enqueued, layer \(Int(layer.bounds.width))x\(Int(layer.bounds.height)))")
        }
    }
}

/// Live preview layer. It receives frames only while its window is visible on screen, so a closed
/// popover costs nothing.
struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    /// An NSView has no natural size, and the menu-bar popover sizes itself from its content's ideal
    /// size; without this the preview collapses to zero height. Fill the offered width at 16:9.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewNSView, context: Context) -> CGSize? {
        let width = proposal.width ?? Self.idealWidth
        return CGSize(width: width, height: (width * 9 / 16).rounded())
    }

    static let idealWidth: CGFloat = 320

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        nsView.setAttached(false)
    }
}

final class PreviewNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var renderer: PreviewRenderer?
    private var occlusionObserver: (any NSObjectProtocol)?
    private var isAttached = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        // Layer-hosting view: assign the layer before enabling layers, otherwise AppKit treats the
        // view as layer-backed and manages (and may never display) the layer itself.
        layer = displayLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAttachment() }
            }
        }
        updateAttachment()
    }

    private func updateAttachment() {
        setAttached(window?.occlusionState.contains(.visible) == true)
    }

    func setAttached(_ attached: Bool) {
        guard attached != isAttached else { return }
        isAttached = attached
        Diagnostics.app.info("Preview \(attached ? "attached" : "detached", privacy: .public) (window visible: \(self.window?.occlusionState.contains(.visible) == true))")
        if attached {
            renderer?.attach(displayLayer)
        } else {
            renderer?.detach(displayLayer)
            // Don't flash a stale frame next time the popover opens.
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
}
