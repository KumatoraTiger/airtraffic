import Foundation

// MARK: - Provider registry

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemini
    case openai
    case anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: "Google (Gemini)"
        case .openai: "OpenAI (GPT)"
        case .anthropic: "Anthropic (Claude)"
        }
    }

    /// Editable in settings; these are only initial values.
    public var defaultModel: String {
        switch self {
        case .gemini: "gemini-2.5-flash"
        case .openai: "gpt-5-mini"
        case .anthropic: "claude-opus-5"
        }
    }

    /// Environment variable consulted when no key is stored in the Keychain.
    public var apiKeyEnvName: String {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        }
    }
}

// MARK: - Request / response

public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct LLMRequest: Sendable {
    public var system: String?
    public var messages: [ChatMessage]
    /// Hint that the response should be a single JSON value. Providers that
    /// support a JSON mode use it; others rely on the prompt.
    public var jsonMode: Bool
    public var maxTokens: Int

    public init(
        system: String? = nil, messages: [ChatMessage],
        jsonMode: Bool = false, maxTokens: Int = 4096
    ) {
        self.system = system
        self.messages = messages
        self.jsonMode = jsonMode
        self.maxTokens = maxTokens
    }
}

public enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey(ProviderKind)
    case httpError(status: Int, body: String)
    case emptyResponse
    case refusal

    public var description: String {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider.displayName) の API キーが設定されていません"
        case .httpError(let status, let body):
            "API エラー (HTTP \(status)): \(body.prefix(300))"
        case .emptyResponse:
            "モデルから空の応答が返されました"
        case .refusal:
            "モデルが応答を拒否しました"
        }
    }
}

/// Provider-agnostic chat completion interface.
public protocol LLMClient: Sendable {
    var kind: ProviderKind { get }
    func complete(_ request: LLMRequest) async throws -> String
}

public enum LLMClientFactory {
    public static func make(kind: ProviderKind, apiKey: String, model: String) -> any LLMClient {
        switch kind {
        case .gemini: GeminiClient(apiKey: apiKey, model: model)
        case .openai: OpenAIClient(apiKey: apiKey, model: model)
        case .anthropic: AnthropicClient(apiKey: apiKey, model: model)
        }
    }
}

// MARK: - JSON helpers

public enum LLMJSON {
    /// Extracts the first JSON object or array from model output, tolerating
    /// markdown fences and surrounding prose.
    public static func extractJSON(from text: String) -> Data? {
        let trimmed =
            text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return data
        }
        // Fall back to the outermost {...} or [...] span.
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = trimmed.range(of: open)?.lowerBound,
                let end = trimmed.range(of: close, options: .backwards)?.upperBound,
                start < end
            {
                let candidate = String(trimmed[start..<end])
                if let data = candidate.data(using: .utf8),
                    (try? JSONSerialization.jsonObject(with: data)) != nil
                {
                    return data
                }
            }
        }
        return nil
    }
}
