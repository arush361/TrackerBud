import Foundation

public enum PermissionStatus: String, Sendable {
    case notRequired
    case granted
    case denied
    case notDetermined

    public var isGranted: Bool {
        switch self {
        case .notRequired, .granted: return true
        case .denied, .notDetermined: return false
        }
    }

    public var label: String {
        switch self {
        case .notRequired: return "Not required"
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not determined"
        }
    }
}
