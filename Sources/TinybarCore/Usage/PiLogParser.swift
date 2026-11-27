import Foundation

/// Incrementally reads pi v3 session JSONL. The session state can be saved with a file cursor.
public struct PiLogParser: Sendable, Codable {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?

    public struct Tool: Sendable, Equatable {
        public var name: String
        /// Derived counters only; the command itself is not retained.
        public var commandStats: [String: Int64]
    }

    public struct Entry: Sendable {
        public var id: String
        /// Tinybar provider raw value. Unknown pi providers are attributed to `pi`.
        public var provider: String
        public var record: UsageRecord
        public var tools: [Tool]
    }

    public init() {}

    public mutating func consume(line: UnsafeRawBufferPointer) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        if type == "session" {
            guard (obj["version"] as? NSNumber)?.intValue == 3 else { return nil }
            sessionID = obj["id"] as? String
            cwd = obj["cwd"] as? String
            return nil
        }
        guard type == "message", let id = obj["id"] as? String,
              let message = obj["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let providerName = message["provider"] as? String, !providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let at = (obj["timestamp"] as? String).flatMap(parseISODate)
                ?? (message["timestamp"] as? String).flatMap(parseISODate)
                ?? (message["timestamp"] as? NSNumber).map({ Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        else { return nil }
        let provider: String
        switch providerName {
        case "openai", "openai-codex": provider = "codex"
        case "anthropic": provider = "claude"
        case "opencode": provider = "opencode"
        default: provider = "pi"
        }
        func count(_ key: String) -> Int64 { (usage[key] as? NSNumber)?.int64Value ?? 0 }
        let input = count("input"), output = count("output")
        let read = count("cacheRead"), write = count("cacheWrite"), reasoning = count("reasoning")
        let separateReasoning = reasoning > 0 && count("totalTokens") == input + output + read + write + reasoning
        let tokens = TokenCounts(input: input, output: output + (separateReasoning ? reasoning : 0), cacheWrite: write, cacheRead: read)
        guard tokens.total > 0 else { return nil }
        let tools = (message["content"] as? [[String: Any]] ?? []).compactMap { block -> Tool? in
            guard block["type"] as? String == "toolCall", let name = block["name"] as? String else { return nil }
            let normalized = name == "bash" ? "Bash" : name
            let command = (block["arguments"] as? [String: Any])?["command"] as? String
            return Tool(name: normalized, commandStats: normalized == "Bash" ? command.map(ShellCommand.stats) ?? [:] : [:])
        }
        return Entry(id: id, provider: provider, record: UsageRecord(timestamp: at, model: ModelName.normalize(model), cwd: cwd, tokens: tokens), tools: tools)
    }
}
