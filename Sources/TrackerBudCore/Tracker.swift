import Foundation

public protocol Tracker: AnyObject, Sendable {
    static var id: String { get }
    var isRunning: Bool { get }
    func start() throws
    func stop()
    func currentPermissionStatus() -> PermissionStatus
}
