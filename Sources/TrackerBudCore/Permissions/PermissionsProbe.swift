import Foundation
import AppKit
import ApplicationServices
import AVFoundation

/// Behavioral TCC probes. We attempt the operation each capability gates and
/// classify the result. This is more reliable than relying on static lookups
/// alone (which can lie when a grant exists but the codesign identity changed).
public enum PermissionsProbe {
    public enum Capability: String, CaseIterable, Identifiable, Sendable {
        case accessibility
        case automation       // Apple Events to other apps
        case inputMonitoring
        case fullDisk         // OR per-folder; we approximate by trying ~/Documents
        case screenRecording
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .accessibility:   return "Accessibility"
            case .automation:      return "Automation (Apple Events)"
            case .inputMonitoring: return "Input Monitoring"
            case .fullDisk:        return "File Access"
            case .screenRecording: return "Screen Recording"
            }
        }

        public var subtitle: String {
            switch self {
            case .accessibility:
                return "Needed to read window titles from the focused app."
            case .automation:
                return "Needed to read the active URL from Safari, Chrome, and Arc."
            case .inputMonitoring:
                return "Needed to track keyboard shortcut usage. Content of keystrokes is never recorded."
            case .fullDisk:
                return "Needed to watch files you open and edit in Documents, Desktop, and Downloads."
            case .screenRecording:
                return "Needed for periodic screenshots and OCR-based search."
            }
        }

        public var systemSettingsURL: URL? {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .automation:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            case .fullDisk:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }

    public static func status(for capability: Capability) -> PermissionStatus {
        switch capability {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .automation:
            // We can only know this by actually trying an Apple Event. We piggy-back
            // on whether Safari/Chrome is running and we got AX. Otherwise: notDetermined.
            return .notDetermined
        case .inputMonitoring:
            // Attempt to install a global monitor and check IOHIDCheckAccess via private API.
            // Public option: try addGlobalMonitorForEvents and infer from delivery.
            // Cheapest reliable check is IOHIDCheckAccess via private symbol; avoid it
            // and return notDetermined so the card prompts the user to verify.
            return .notDetermined
        case .fullDisk:
            // Try to list ~/Documents. If it works, we have access.
            let path = NSHomeDirectory() + "/Documents"
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil {
                return .granted
            }
            return .denied
        case .screenRecording:
            // CGPreflightScreenCaptureAccess is the canonical check.
            if CGPreflightScreenCaptureAccess() { return .granted }
            return .notDetermined
        }
    }

    public static func openSystemSettings(for capability: Capability) {
        guard let url = capability.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    public static func requestScreenRecording() {
        // Prompts if not yet determined. Otherwise no-op.
        _ = CGRequestScreenCaptureAccess()
    }
}
