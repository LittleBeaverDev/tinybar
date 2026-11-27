import Foundation
import Testing
@testable import TinybarCore

@Test func agySnapshotDiscoveryAndIncrementalIngest() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let brain = dir.appendingPathComponent("brain")
    let logs = brain.appendingPathComponent("conversation/.system_generated/logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("transcript.jsonl")
    let dbURL = dir.appendingPathComponent("conversation_summaries.db")
    let source = try SQLiteDB(path: dbURL.path)
    try source.exec("CREATE TABLE conversation_summaries (conversation_id TEXT, workspace_uris TEXT);")
    try source.run("INSERT INTO conversation_summaries VALUES (?, ?)", [.text("conversation"), .text("[\"https://example.com\",\"file:///tmp/agy%20missing%20project\"]")])
    let wal = URL(fileURLWithPath: dbURL.path + "-wal")
    let beforeDB = try Data(contentsOf: dbURL), beforeWAL = try Data(contentsOf: wal)
    let mapping = AgyProjectMap(database: dbURL, resolver: ProjectResolver())
    #expect(mapping.projects["conversation"] == "agy missing project")
    #expect(try Data(contentsOf: dbURL) == beforeDB)
    #expect(try Data(contentsOf: wal) == beforeWAL)
    #expect(UsageStore.acceptsLog(file.path, source: .gemini))
    #expect(!UsageStore.acceptsLog(file.path, source: .codex))
    #expect(!UsageStore.acceptsLog(logs.appendingPathComponent("other.jsonl").path, source: .gemini))
    let row = "{\"type\":\"PLANNER_RESPONSE\",\"source\":\"MODEL\",\"created_at\":\"2025-01-02T12:00:00.123Z\",\"model\":\"google/gemini-test\",\"input_tokens\":10,\"cache_read_tokens\":4,\"output_tokens\":2,\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git status\"}}]}\n"
    let split = row.index(row.startIndex, offsetBy: row.count / 2)
    try (row + row[..<split]).write(to: file, atomically: true, encoding: .utf8)
    let storeURL = dir.appendingPathComponent("usage.sqlite")
    let store = try UsageStore(path: storeURL)
    #expect(try await store.ingestGemini(roots: [brain]).recordsAdded == 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data(row[split...].utf8)); try handle.close()
    #expect(try await store.ingestGemini(roots: [brain]).recordsAdded == 1)
    let restarted = try UsageStore(path: storeURL)
    #expect(try await restarted.ingestGemini(roots: [brain]).recordsAdded == 0)
    let rows = try await restarted.daily(since: "0000", provider: .gemini)
    #expect(rows.count == 1)
    #expect(rows.first?.project == "agy missing project")
    #expect(rows.first?.tokens.input == 20)
    #expect(rows.first?.tokens.cacheRead == 8)
    #expect(rows.first?.tokens.output == 4)
    let stats = try await restarted.stats(since: "0000")
    #expect(stats.contains { $0.key == StatKey.tool("run_command") && $0.value == 2 })
}
