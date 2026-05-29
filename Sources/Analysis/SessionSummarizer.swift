import Foundation
import TrackerBudCore
import OSLog

/// Builds prompts from event data and asks Claude to summarize or answer
/// natural-language queries. Tokens-only by default; opt-in to send decrypted
/// content (window titles, URLs, file paths, OCR text) per request.
public final class SessionSummarizer: Sendable {
    public static let shared = SessionSummarizer()
    public init() {}

    public enum PrivacyMode: String, Sendable {
        case tokensOnly
        case withContent
    }

    public struct SummaryResult: Sendable {
        public let prose: String
        public let model: String
        public let tokensUsed: Int
        public let costUSD: Double
    }

    private static let baseSystemPrompt = """
    You are a private analyst for someone studying their own work patterns. \
    Be concise, factual, and human. Avoid productivity-coach moralizing. \
    If you make claims about time spent or sequences, derive them only from the \
    activity log provided in the user message. If data is sparse, say so.

    The activity log is a sequence of events with this shape (one per line):
      HH:MM  source:type  token  [optional content]

    Tokens are normalized identifiers like `app:com.apple.mail`, `browser:github.com+/anthropics`, \
    `file:swift@a3f2`, `key:cmd+shift+v`, `clip:text`. Use them to spot repeated sequences. \
    Don't invent activity you can't see in the log.
    """

    /// Summarize an arbitrary date range.
    public func summarize(
        from start: Date,
        to end: Date,
        mode: PrivacyMode = .tokensOnly,
        userInstructions: String = "Summarize what I worked on in 3-6 short paragraphs."
    ) async throws -> SummaryResult {
        let log = try buildEventLog(from: start, to: end, mode: mode)
        let userMessage = """
        Time range: \(formatTimestamp(start)) → \(formatTimestamp(end))
        Events: \(log.eventCount)
        Privacy: \(mode.rawValue)

        \(userInstructions)

        --- activity log ---
        \(log.text)
        --- end log ---
        """

        let resp = try await ClaudeAPIClient.shared.send(
            system: Self.baseSystemPrompt,
            messages: [ClaudeMessage(role: "user", content: userMessage)],
            maxTokens: 1024,
            purpose: "summary"
        )

        // Persist
        _ = try? EventStore.shared.recordSessionSummary(
            rangeStart: start,
            rangeEnd: end,
            privacyMode: mode.rawValue,
            model: resp.model,
            prose: resp.text,
            tokenCount: resp.inputTokens + resp.outputTokens
        )

        return SummaryResult(
            prose: resp.text,
            model: resp.model,
            tokensUsed: resp.inputTokens + resp.outputTokens,
            costUSD: estimateCost(
                model: resp.model,
                inputTokens: resp.inputTokens,
                outputTokens: resp.outputTokens
            )
        )
    }

    /// Answer a natural-language question about a date range.
    public func answer(
        question: String,
        from start: Date,
        to end: Date,
        mode: PrivacyMode = .tokensOnly
    ) async throws -> SummaryResult {
        return try await summarize(
            from: start,
            to: end,
            mode: mode,
            userInstructions: "Question from the user: \(question)\n\nAnswer in 1-4 short paragraphs. Cite specific times or sequences when relevant."
        )
    }

    // MARK: - Private

    private struct EventLog {
        let text: String
        let eventCount: Int
    }

    private func buildEventLog(from start: Date, to end: Date, mode: PrivacyMode) throws -> EventLog {
        let cap = 1500   // hard event cap to keep prompts bounded
        let rows = try EventStore.shared.recentEventRows(limit: 5000)
        // Filter to range and (if tokensOnly) exclude is_private events implicitly through recentEventRows.
        // recentEventRows is sorted DESC by id; reverse to chronological.
        let filtered = rows
            .filter { $0.ts >= start && $0.ts <= end }
            .sorted { $0.ts < $1.ts }
            .prefix(cap)

        let lines: [String] = filtered.map { row in
            let ts = formatHHMM(row.ts)
            switch mode {
            case .tokensOnly:
                return "\(ts)  \(row.source.rawValue):\(row.type)  \(row.token)"
            case .withContent:
                var bits = "\(ts)  \(row.source.rawValue):\(row.type)  \(row.token)"
                if let primary = row.primaryText, !primary.isEmpty {
                    let trimmed = String(primary.prefix(120))
                    bits += "  ◦ \(trimmed)"
                }
                if let secondary = row.secondaryText, !secondary.isEmpty {
                    bits += " [\(secondary)]"
                }
                return bits
            }
        }
        return EventLog(text: lines.joined(separator: "\n"), eventCount: lines.count)
    }

    private func formatTimestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    private func formatHHMM(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func estimateCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        // Mirrors ClaudeAPIClient's price table for haiku-4-5 default
        let inputPrice = 1.00 / 1_000_000.0
        let outputPrice = 5.00 / 1_000_000.0
        return Double(inputTokens) * inputPrice + Double(outputTokens) * outputPrice
    }
}
