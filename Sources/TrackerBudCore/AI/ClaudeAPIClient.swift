import Foundation
import OSLog

public struct ClaudeMessage: Sendable, Codable {
    public let role: String     // "user" | "assistant"
    public let content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ClaudeResponse: Sendable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let model: String
}

public enum ClaudeAPIError: Error, CustomStringConvertible {
    case noKey
    case http(Int, String)
    case decoding(String)
    case budgetExceeded(reason: String)
    case networking(String)

    public var description: String {
        switch self {
        case .noKey: return "No API key set. Paste your Claude API key in Settings."
        case .http(let code, let body): return "Claude API error \(code): \(body)"
        case .decoding(let m): return "Decoding error: \(m)"
        case .budgetExceeded(let r): return "Budget exceeded: \(r)"
        case .networking(let m): return "Network error: \(m)"
        }
    }
}

/// Plain URLSession-based client. No SDK dependency.
/// Tracks tokens + cost into EventStore.api_calls.
public final class ClaudeAPIClient: @unchecked Sendable {
    public static let shared = ClaudeAPIClient()

    public static let defaultModel = "claude-haiku-4-5"
    public static let defaultDailyInputBudget = 100_000
    public static let defaultDailyOutputBudget = 25_000

    // Pricing (per 1M tokens, USD). Source: docs.anthropic.com — keep up to date.
    private struct Pricing {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }
    private static let priceTable: [String: Pricing] = [
        "claude-haiku-4-5":   Pricing(input: 1.00,  output: 5.00,  cacheRead: 0.10, cacheWrite: 1.25),
        "claude-sonnet-4-6":  Pricing(input: 3.00,  output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-opus-4-7":    Pricing(input: 5.00,  output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
    ]

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "ClaudeAPI")
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    public func ping() async throws -> Bool {
        let r = try await send(
            system: "Reply with exactly the word OK.",
            messages: [ClaudeMessage(role: "user", content: "ping")],
            model: Self.defaultModel,
            maxTokens: 16,
            purpose: "test",
            checkBudget: false
        )
        return r.text.uppercased().contains("OK")
    }

    /// Send a request. Throws if budget exceeded BEFORE the network call.
    public func send(
        system: String,
        messages: [ClaudeMessage],
        model: String = ClaudeAPIClient.defaultModel,
        maxTokens: Int = 1024,
        purpose: String = "query",
        checkBudget: Bool = true
    ) async throws -> ClaudeResponse {
        guard let key = APIKeyVault.shared.get(), !key.isEmpty else {
            throw ClaudeAPIError.noKey
        }

        if checkBudget {
            if let spend = try? EventStore.shared.todayAPISpend() {
                if spend.inputTokens > Self.defaultDailyInputBudget {
                    throw ClaudeAPIError.budgetExceeded(
                        reason: "Daily input token budget (\(Self.defaultDailyInputBudget)) exceeded."
                    )
                }
                if spend.outputTokens > Self.defaultDailyOutputBudget {
                    throw ClaudeAPIError.budgetExceeded(
                        reason: "Daily output token budget (\(Self.defaultDailyOutputBudget)) exceeded."
                    )
                }
            }
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")

        let body = buildRequestBody(
            system: system,
            messages: messages,
            model: model,
            maxTokens: maxTokens
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeAPIError.networking("no HTTP response")
            }
            if http.statusCode >= 400 {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw ClaudeAPIError.http(http.statusCode, body)
            }
            return try decodeResponse(data: data, model: model, purpose: purpose)
        } catch let e as ClaudeAPIError {
            throw e
        } catch {
            throw ClaudeAPIError.networking(error.localizedDescription)
        }
    }

    private func buildRequestBody(
        system: String, messages: [ClaudeMessage], model: String, maxTokens: Int
    ) -> [String: Any] {
        // Wrap the system prompt with ephemeral cache_control so repeated
        // requests within ~5 min reuse the cached prefix and cost ~10× less.
        let systemBlocks: [[String: Any]] = [
            [
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"]
            ]
        ]
        let messagePayload: [[String: Any]] = messages.map { m in
            ["role": m.role, "content": m.content]
        }
        return [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemBlocks,
            "messages": messagePayload
        ]
    }

    private func decodeResponse(data: Data, model: String, purpose: String) throws -> ClaudeResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeAPIError.decoding("not an object")
        }
        guard let contentArray = obj["content"] as? [[String: Any]] else {
            throw ClaudeAPIError.decoding("missing content[]")
        }
        let text = contentArray.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()

        let usage = (obj["usage"] as? [String: Any]) ?? [:]
        let inT = (usage["input_tokens"] as? Int) ?? 0
        let outT = (usage["output_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0

        let pricing = Self.priceTable[model] ?? Self.priceTable["claude-haiku-4-5"]!
        let cost = Double(inT) * pricing.input / 1_000_000
            + Double(outT) * pricing.output / 1_000_000
            + Double(cacheRead) * pricing.cacheRead / 1_000_000
            + Double(cacheCreate) * pricing.cacheWrite / 1_000_000

        try? EventStore.shared.recordAPICall(
            model: model,
            inputTokens: inT,
            outputTokens: outT,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            costUSD: cost,
            purpose: purpose
        )

        return ClaudeResponse(
            text: text,
            inputTokens: inT,
            outputTokens: outT,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            model: model
        )
    }
}
