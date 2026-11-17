import CoreMediaIO
import Foundation
import MirrorupDiagnostics
import os

let fallback: FallbackFrame?
do {
    fallback = try FallbackFrame.render()
} catch {
    // Without the fallback the source stream simply sends nothing until the app feeds the sink.
    Diagnostics.virtualCamera.fault("Fallback frame render failed: \(error.description, privacy: .public)")
    fallback = nil
}

let providerSource = ProviderSource(relay: FrameRelay(fallback: fallback))
CMIOExtensionProvider.startService(provider: providerSource.provider)
Diagnostics.virtualCamera.info("Mirrorup Camera Extension started")

CFRunLoopRun()
