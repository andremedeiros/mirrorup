import AppKit
import AVFoundation
import CoreMedia
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
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
    }
}

struct PreviewView: NSViewRepresentable {
    let renderer: PreviewRenderer

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.renderer = renderer
        renderer.attach(view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        // Detach by layer identity so a newer preview window is unaffected.
        nsView.renderer?.detach(nsView.displayLayer)
    }
}

final class PreviewNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var renderer: PreviewRenderer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer = displayLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
