import Foundation
import Testing
@testable import TinybarCore

private struct PiFixture {
    let dir: URL
    let sessions: URL
    let file: URL
    let database: URL
    let store: UsageStore

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessions = dir.appendingPathComponent("sessions")
        file = sessions.appendingPathComponent("session.jsonl")
        database = dir.appendingPathComponent("usage.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        store = try UsageStore(path: database)
    }
    func remove() { try? FileManager.default.removeItem(at: dir) }
    func write(_ text: String) throws { try text.write(to: file, atomically: true, encoding: .utf8) }
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

private let piSession = "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"cwd\":\"/tmp/project\"}\n"
private func piMessage(_ id: String, _ provider: String, input: Int = 10) -> String {
    "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"2025-01-02T12:00:00Z\",\"message\":{\"role\":\"assistant\",\"provider\":\"\(provider)\",\"model\":\"shared\",\"usage\":{\"input\":\(input),\"output\":2}}}\n"
}

@Test func piMixedProvidersAndSameModelSelection() async throws {
    let f = try PiFixture(); defer { f.remove() }
    try f.write(piSession + piMessage("a", "openai-codex") + piMessage("b", "opencode", input: 20) + piMessage("c", "anthropic") + piMessage("d", "custom"))
    try await f.store.ingestPi(roots: [f.sessions])
    let rows = try await f.store.daily(since: "0000")
    #expect(Set(rows.map(\.provider)) == [.codex, .opencode, .claude, .piOther])
    #expect(rows.first { $0.provider == .codex }?.tokens.input == 10)
    #expect(rows.first { $0.provider == .opencode }?.tokens.input == 20)
    let day = try #require(rows.first?.day)
    let now = ISO8601DateFormatter().date(from: "2025-01-02T18:00:00Z")!
    let summary = StatsSummary.build(usage: rows, stats: try await f.store.stats(since: "0000"), allDays: [day], range: .week, model: "shared", modelProvider: .opencode, prices: .empty, now: now)
    #expect(summary.tokens == 22)
    #expect(summary.tokensByProvider[.codex] == nil)
    #expect(summary.models.filter { $0.name == "shared" }.count == 4)
    #expect(try await f.store.activeDays(model: "shared", provider: .opencode) == [day])
}

@Test func piPartialAppendAndReingest() async throws {
    let f = try PiFixture(); defer { f.remove() }
    let message = piMessage("b", "opencode")
    let split = message.index(message.startIndex, offsetBy: message.count / 2)
    try f.write(piSession + piMessage("a", "openai-codex") + message[..<split])
    try await f.store.ingestPi(roots: [f.sessions])
    #expect(try await f.store.daily(since: "0000").count == 1)
    try f.append(String(message[split...]))
    try await f.store.ingestPi(roots: [f.sessions])
    try await f.store.ingestPi(roots: [f.sessions])
    let rows = try await f.store.daily(since: "0000")
    #expect(rows.count == 2)
    #expect(rows.reduce(0) { $0 + $1.tokens.input } == 20)
}

@Test func piReplacementTruncationAndForkCopies() async throws {
    let f = try PiFixture(); defer { f.remove() }
    let first = piSession + piMessage("a", "openai-codex")
    try f.write(first)
    try await f.store.ingestPi(roots: [f.sessions])
    try (first + piMessage("b", "opencode")).write(to: f.sessions.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8)
    try f.write(piSession + piMessage("c", "anthropic"))
    try await f.store.ingestPi(roots: [f.sessions])
    try f.write(piSession)
    try await f.store.ingestPi(roots: [f.sessions])
    let rows = try await f.store.daily(since: "0000")
    #expect(rows.reduce(0) { $0 + $1.tokens.input } == 30)
    #expect(Set(rows.map(\.provider)) == [.codex, .opencode, .claude])
}

@Test func piSchemaTenMigrationPreservesHistory() async throws {
    let f = try PiFixture(); defer { f.remove() }
    let db = try SQLiteDB(path: f.database.path)
    try db.exec("DROP TABLE pi_message; PRAGMA user_version = 9; INSERT INTO daily_usage VALUES ('2025-01-01', 'codex', 'old', '', 7, 0, 0, 0);")
    let migrated = try UsageStore(path: f.database)
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 11)
    try f.write(piSession + piMessage("a", "opencode"))
    try await migrated.ingestPi(roots: [f.sessions])
    let rows = try await migrated.daily(since: "0000")
    #expect(rows.first { $0.model == "old" }?.tokens.input == 7)
    #expect(rows.first { $0.provider == .opencode }?.tokens.input == 10)
}
