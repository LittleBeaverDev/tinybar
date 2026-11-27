import Foundation
import CoreFoundation

/// A single model response; raw tool arguments are never retained.
struct AgyLogParser {
    struct Entry {
        let record: UsageRecord
        let tools: [PiLogParser.Tool]
    }

    func consume(line: UnsafeRawBufferPointer) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "PLANNER_RESPONSE", obj["source"] as? String == "MODEL",
              let date = (obj["created_at"] as? String).flatMap(parseISODate),
              let model = obj["model"] as? String, !model.isEmpty else { return nil }
        let usage = obj["tokens"] as? [String: Any] ?? obj
        func count(_ key: String) -> Int64? {
            guard let n = usage[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue < Double(Int64.max), n.doubleValue.rounded(.down) == n.doubleValue else { return nil }
            return n.int64Value
        }
        guard let input = count("input_tokens"), let read = count("cache_read_tokens"), let output = count("output_tokens"),
              input <= Int64.max - read, input + read <= Int64.max - output else { return nil }
        let tokens = TokenCounts(input: input, output: output, cacheWrite: 0, cacheRead: read)
        guard tokens.total > 0 else { return nil }
        let tools = (obj["tool_calls"] as? [[String: Any]] ?? []).compactMap { tool -> PiLogParser.Tool? in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            let command = (tool["args"] as? [String: Any])?["CommandLine"] as? String
            return PiLogParser.Tool(name: name, commandStats: name == "run_command" ? command.map(ShellCommand.stats) ?? [:] : [:])
        }
        return Entry(record: UsageRecord(timestamp: date, model: ModelName.normalize(model), cwd: nil, tokens: tokens), tools: tools)
    }
}
