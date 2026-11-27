import Foundation
import Testing
@testable import TinybarCore

@Test func piParserReadsSessionAndAssistantUsage() throws {
    var parser = PiLogParser()
    func consume(_ line: String) -> PiLogParser.Entry? {
        Data(line.utf8).withUnsafeBytes { parser.consume(line: $0) }
    }
    #expect(consume(#"{"type":"session","version":3,"id":"s","cwd":"/tmp/project"}"#) == nil)
    let entry = try #require(consume(#"{"type":"message","id":"m","timestamp":"2025-01-02T12:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"example","usage":{"input":10,"output":3,"reasoning":2,"cacheRead":4,"cacheWrite":5,"totalTokens":24},"content":[{"type":"toolCall","name":"bash","arguments":{"command":"git status"}}]}}"#))
    #expect(entry.provider == "codex")
    #expect(entry.record.cwd == "/tmp/project")
    #expect(entry.record.tokens == TokenCounts(input: 10, output: 5, cacheWrite: 5, cacheRead: 4))
    #expect(entry.tools.first?.name == "Bash")
    #expect(entry.tools.first?.commandStats.isEmpty == false)
    #expect(consume(#"{"type":"message","id":"u","message":{"role":"user"}}"#) == nil)
    #expect(consume("not json") == nil)
}
