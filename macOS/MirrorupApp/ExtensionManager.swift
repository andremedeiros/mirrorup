import AppKit
import Foundation
import Observation
import MirrorupDiagnostics
import os
import SystemExtensions

/// Installs, removes and reports the state of the embedded Mirrorup Camera system extension.
@MainActor
@Observable
final class ExtensionManager: NSObject {
    enum State: Equatable {
        case checking
        case notInstalled
        case activating
        /// macOS is waiting for the user to allow the extension in System Settings.
        case awaitingApproval
        case active
        case deactivating
        case rebootRequired
        /// A configuration profile (MDM) forbids this system extension; only an administrator can fix it.
        case blockedByPolicy
        case failed(message: String, detail: String)

        var summary: String {
            switch self {
            case .checking: "Checking…"
            case .notInstalled: "Not installed"
            case .activating: "Installing…"
            case .awaitingApproval: "Waiting for your approval"
            case .active: "Active"
            case .deactivating: "Uninstalling…"
            case .rebootRequired: "Restart your Mac to finish"
            case .blockedByPolicy: "Blocked by your organization's device management"
            case let .failed(message, _): message
            }
        }
    }

    static let approvalInstructions =
        "Open System Settings › General › Login Items & Extensions, click the info button next to Camera Extensions, and turn on Mirrorup Camera."

    private enum RequestKind { case properties, activation, deactivation }

    private(set) var state: State = .checking

    /// A request is in flight; management buttons are disabled meanwhile.
    var isBusy: Bool {
        switch state {
        case .checking, .activating, .deactivating: true
        default: false
        }
    }
    @ObservationIgnored private var pending: [ObjectIdentifier: RequestKind] = [:]
    /// True while a launch-time check may turn into an activation request.
    @ObservationIgnored private var activateAfterCheck = false
    /// User-initiated activations always replace; automatic ones never disturb a running extension.
    @ObservationIgnored private var forceReplace = false
    @ObservationIgnored private let log = Diagnostics.app
    /// Defined once in project.yml (`EXTENSION_BUNDLE_ID`) and injected into the app's Info.plist.
    private let identifier = ExtensionManager.extensionBundleIdentifier

    static let extensionBundleIdentifier: String = {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "MirrorupCameraExtensionBundleIdentifier") as? String, !id.isEmpty else {
            preconditionFailure("MirrorupCameraExtensionBundleIdentifier missing from Info.plist; regenerate the project with `make project`")
        }
        return id
    }()

    func refresh() {
        submit(.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .properties)
    }

    /// Launch-time path: installs the extension if it is missing or the embedded build is a different
    /// version, without restarting an up-to-date extension that clients may be streaming from.
    func activateIfNeeded() {
        activateAfterCheck = true
        refresh()
    }

    /// User-initiated install/reinstall; replaces whatever is installed.
    func activate() {
        forceReplace = true
        submitActivation()
    }

    private func submitActivation() {
        state = .activating
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .activation)
    }

    func deactivate() {
        state = .deactivating
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .deactivation)
    }

    func openApprovalSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: RequestKind) {
        pending[ObjectIdentifier(request)] = kind
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finished(_ id: ObjectIdentifier, result: OSSystemExtensionRequest.Result) {
        let kind = pending.removeValue(forKey: id)
        switch result {
        case .completed:
            state = kind == .deactivation ? .notInstalled : .active
            log.info("System extension request completed (\(String(describing: kind), privacy: .public))")
        case .willCompleteAfterReboot:
            state = .rebootRequired
        @unknown default:
            refresh()
        }
    }

    private func failed(_ id: ObjectIdentifier, error: NSError) {
        let kind = pending.removeValue(forKey: id)
        let detail = "\(error.domain) \(error.code): \(error.localizedDescription)"
        log.error("System extension request failed (\(String(describing: kind), privacy: .public)): \(detail, privacy: .public)")
        let code = error.domain == OSSystemExtensionErrorDomain ? OSSystemExtensionError.Code(rawValue: error.code) : nil
        if kind == .deactivation, code == .extensionNotFound {
            state = .notInstalled
            return
        }
        if code == .requestSuperseded { return }
        if code == .forbiddenBySystemPolicy {
            state = .blockedByPolicy
            return
        }
        // We cancel replacement of an identical, already-installed version; that's success.
        if kind == .activation, code == .requestCanceled {
            refresh()
            return
        }
        state = .failed(message: Self.message(for: code), detail: detail)
    }

    private func found(_ id: ObjectIdentifier, properties: [OSSystemExtensionProperties]) {
        pending.removeValue(forKey: id)
        let ours = properties.filter { $0.bundleIdentifier == identifier && !$0.isUninstalling }
        let embedded = Self.embeddedExtensionVersion
        if activateAfterCheck {
            activateAfterCheck = false
            let current = ours.contains { $0.isEnabled && $0.bundleVersion == embedded }
            if !current && !ours.contains(where: \.isAwaitingUserApproval) {
                log.info("Camera extension missing or outdated (embedded \(embedded ?? "?", privacy: .public)); activating")
                submitActivation()
                return
            }
        }
        if ours.contains(where: \.isEnabled) {
            state = .active
        } else if ours.contains(where: \.isAwaitingUserApproval) {
            state = .awaitingApproval
        } else {
            state = .notInstalled
        }
    }

    private static var embeddedExtensionVersion: String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(extensionBundleIdentifier).systemextension")
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private static func message(for code: OSSystemExtensionError.Code?) -> String {
        switch code {
        case .unsupportedParentBundleLocation:
            "Move Mirrorup to the Applications folder, then install the camera extension again."
        case .missingEntitlement, .codeSignatureInvalid, .validationFailed, .extensionMissingIdentifier:
            "This copy of Mirrorup isn't signed correctly to install its camera extension. Reinstall Mirrorup."
        case .extensionNotFound:
            "The camera extension is missing from the Mirrorup app. Reinstall Mirrorup."
        case .forbiddenBySystemPolicy:
            "Your Mac's security policy doesn't allow the Mirrorup camera extension."
        case .authorizationRequired:
            "macOS needs your approval to install the camera extension. \(approvalInstructions)"
        default:
            "The Mirrorup camera extension couldn't be installed."
        }
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    // All requests are created with `queue: .main`, so every callback arrives on the main thread.

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let force = MainActor.assumeIsolated { () -> Bool in
            defer { forceReplace = false }
            return forceReplace
        }
        if !force && existing.bundleVersion == ext.bundleVersion && existing.bundleShortVersion == ext.bundleShortVersion {
            Diagnostics.app.info("Camera extension \(existing.bundleVersion, privacy: .public) already installed; keeping it")
            return .cancel
        }
        Diagnostics.app.info(
            "Replacing camera extension \(existing.bundleShortVersion, privacy: .public) (\(existing.bundleVersion, privacy: .public)) with \(ext.bundleShortVersion, privacy: .public) (\(ext.bundleVersion, privacy: .public))"
        )
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { state = .awaitingApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated { finished(id, result: result) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let id = ObjectIdentifier(request)
        let nsError = error as NSError
        MainActor.assumeIsolated { failed(id, error: nsError) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let id = ObjectIdentifier(request)
        nonisolated(unsafe) let properties = properties
        MainActor.assumeIsolated { found(id, properties: properties) }
    }
}
