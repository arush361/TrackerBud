import Foundation
import AppKit

public struct BrowserURLSnapshot: Sendable {
    public let browser: String       // "safari" | "chrome" | "arc" | ...
    public let url: String
    public let title: String?
}

public protocol BrowserURLProvider: Sendable {
    /// Bundle identifiers this provider handles.
    var bundleIdentifiers: [String] { get }
    /// True if this provider knows how to query the given bundle ID.
    func handles(bundleID: String) -> Bool
    /// Returns the active tab URL/title for the running browser, or nil if
    /// unavailable (browser not running, AX/Apple Events denied, no tab).
    func currentURL() -> BrowserURLSnapshot?
}

public extension BrowserURLProvider {
    func handles(bundleID: String) -> Bool {
        bundleIdentifiers.contains(bundleID)
    }
}

enum AppleScriptRunner {
    static func run(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let descriptor = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor?.stringValue
    }

    static func runTwo(_ source: String) -> (String, String)? {
        // Expects script to return a list of two strings.
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        guard let descriptor = script?.executeAndReturnError(&error), error == nil else {
            return nil
        }
        guard descriptor.numberOfItems >= 2 else { return nil }
        let a = descriptor.atIndex(1)?.stringValue ?? ""
        let b = descriptor.atIndex(2)?.stringValue ?? ""
        return (a, b)
    }
}

public struct SafariURLProvider: BrowserURLProvider {
    public let bundleIdentifiers = ["com.apple.Safari"]
    public init() {}
    public func currentURL() -> BrowserURLSnapshot? {
        let src = """
        try
          tell application "Safari"
            if (count of windows) is 0 then return ""
            set theURL to URL of current tab of front window
            set theTitle to name of current tab of front window
            return {theURL as text, theTitle as text}
          end tell
        on error
          return ""
        end try
        """
        guard let (url, title) = AppleScriptRunner.runTwo(src), !url.isEmpty else { return nil }
        return BrowserURLSnapshot(browser: "safari", url: url, title: title.isEmpty ? nil : title)
    }
}

public struct ChromeURLProvider: BrowserURLProvider {
    public let bundleIdentifiers = ["com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta"]
    public init() {}
    public func currentURL() -> BrowserURLSnapshot? {
        let src = """
        try
          tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return {theURL as text, theTitle as text}
          end tell
        on error
          return ""
        end try
        """
        guard let (url, title) = AppleScriptRunner.runTwo(src), !url.isEmpty else { return nil }
        return BrowserURLSnapshot(browser: "chrome", url: url, title: title.isEmpty ? nil : title)
    }
}

public struct ArcURLProvider: BrowserURLProvider {
    public let bundleIdentifiers = ["company.thebrowser.Browser"]
    public init() {}
    public func currentURL() -> BrowserURLSnapshot? {
        // Arc uses the Chromium-style scripting dictionary.
        let src = """
        try
          tell application "Arc"
            if (count of windows) is 0 then return ""
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return {theURL as text, theTitle as text}
          end tell
        on error
          return ""
        end try
        """
        guard let (url, title) = AppleScriptRunner.runTwo(src), !url.isEmpty else { return nil }
        return BrowserURLSnapshot(browser: "arc", url: url, title: title.isEmpty ? nil : title)
    }
}
