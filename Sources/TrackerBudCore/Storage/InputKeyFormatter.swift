import Foundation
import AppKit

/// Renders a key combo as a human-readable string from raw NSEvent modifiers
/// and key code/char.
public enum InputKeyFormatter {
    public static func format(modifiers: Int64, keyChar: String, keyCode: Int64) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: Int(modifiers)))
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        let keyDisplay: String
        if !keyChar.isEmpty {
            keyDisplay = keyChar.uppercased()
        } else {
            keyDisplay = specialKeyName(forCode: keyCode) ?? "(\(keyCode))"
        }
        parts.append(keyDisplay)
        return parts.joined()
    }

    public static func tokenFor(modifiers: Int64, keyChar: String, keyCode: Int64) -> String {
        // Normalized token used for pattern mining. Stable across cases.
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: Int(modifiers)))
        var bits: [String] = []
        if flags.contains(.command) { bits.append("cmd") }
        if flags.contains(.option) { bits.append("opt") }
        if flags.contains(.shift) { bits.append("shift") }
        if flags.contains(.control) { bits.append("ctrl") }
        let key = keyChar.isEmpty ? "code\(keyCode)" : keyChar.lowercased()
        bits.append(key)
        return "key:" + bits.joined(separator: "+")
    }

    private static func specialKeyName(forCode code: Int64) -> String? {
        switch code {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}
