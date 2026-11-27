import Foundation
@testable import TinybarCore
import Testing

private func compress(_ plain: URL, to compressed: URL, using zstd: URL) throws {
    let process = Process()
    process.executableURL = zstd
    process.arguments = ["-q", "-f", plain.path, "-o", compressed.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private let zstdLog = #"{"timestamp":"2026-09-25T10:00:00Z","type":"turn_context","payload":{"model":"gpt-test"}}"# + "\n" + #"{"timestamp":"2026-09-25T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300000,"output_tokens":10}}}}"# + "\n"

@Test func compressedParityAndBackfills() async throws {
    guard let zstd = ZstdReader.executable() else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let plainDir = dir.appendingPathComponent("plain"), zipDir = dir.appendingPathComponent("zip")
    try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: zipDir, withIntermediateDirectories: true)
    let plain = plainDir.appendingPathComponent("rollout-a.jsonl")
    let zip = zipDir.appendingPathComponent("rollout-a.jsonl.zst")
    try zstdLog.write(to: plain, atomically: true, encoding: .utf8)
    try compress(plain, to: zip, using: zstd)
    let a = try UsageStore(path: dir.appendingPathComponent("a.sqlite"))
    let bURL = dir.appendingPathComponent("b.sqlite")
    let b = try UsageStore(path: bURL)
    // Completed markers must not prevent a full scan when no cursors exist.
    try await b.markInitialImportDone(); try await b.markStatsBackfillDone(); try await b.markLongContextBackfillDone()
    try await a.ingestCodex(roots: [plainDir]); try await b.ingestCodex(roots: [zipDir])
    #expect(try await a.daily(since: "0000") == b.daily(since: "0000"))
    #expect(try await a.stats(since: "0000") == b.stats(since: "0000"))
    #expect(try await a.hourlyTokens(since: "0000") == b.hourlyTokens(since: "0000"))
    let db = try SQLiteDB(path: bURL.path)
    let cursor = try #require(db.run("SELECT size, offset FROM file_cursor").first)
    #expect(cursor[0].int < cursor[1].int)
    try db.exec("DELETE FROM daily_stat; DELETE FROM daily_long_context; DELETE FROM meta WHERE key GLOB '*backfill*'")
    #expect(try await b.backfillStats().filesScanned == 1)
    #expect(try await b.backfillLongContext().filesScanned == 1)
    #expect(try await a.daily(since: "0000") == b.daily(since: "0000"))
    #expect(try await a.stats(since: "0000") == b.stats(since: "0000"))
    #expect(try await a.hourlyTokens(since: "0000") == b.hourlyTokens(since: "0000"))
}

@Test func compressedWatcherFilter() {
    #expect(UsageStore.acceptsLog("/sessions/rollout-a.jsonl.zst", source: .codex))
    #expect(!UsageStore.acceptsLog("/sessions/other.jsonl.zst", source: .codex))
    #expect(!UsageStore.acceptsLog("/sessions/rollout-a.jsonl.zst", source: .claude))
}

@Test func compressedConversionAndRelocation() async throws {
    guard let zstd = ZstdReader.executable() else { return }
    for both in [false, true] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = dir.appendingPathComponent("sessions"), archive = dir.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let plain = sessions.appendingPathComponent("rollout-a.jsonl")
        let zip = archive.appendingPathComponent("rollout-a.jsonl.zst")
        try zstdLog.write(to: plain, atomically: true, encoding: .utf8)
        let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
        try await store.ingestCodex(roots: [sessions])
        try compress(plain, to: zip, using: zstd)
        if !both { try FileManager.default.removeItem(at: plain) }
        try await store.ingestCodex(roots: [sessions, archive])
        if both { try FileManager.default.removeItem(at: plain); try await store.ingestCodex(roots: [sessions, archive]) }
        #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 300010)
        #expect(try await store.stats(since: "0000").first { $0.key == StatKey.responses }?.value == 1)
    }
}

@Test func compressedCodexImportAndFailures() async throws {
    guard let zstd = ZstdReader.executable() else { return }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let plain = sessions.appendingPathComponent("rollout-good.jsonl")
    let compressed = URL(fileURLWithPath: plain.path + ".zst")
    let line = #"{"timestamp":"2026-09-25T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":1}}}}"# + "\n"
    try line.write(to: plain, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = zstd
    process.arguments = ["-q", "-f", plain.path, "-o", compressed.path]
    try process.run(); process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    try FileManager.default.removeItem(at: plain)
    let bad = sessions.appendingPathComponent("rollout-bad.jsonl.zst")
    try Data("not zstd".utf8).write(to: bad)
    let truncated = sessions.appendingPathComponent("rollout-truncated.jsonl.zst")
    let bytes = try Data(contentsOf: compressed)
    try bytes.prefix(bytes.count / 2).write(to: truncated)
    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestCodex(roots: [sessions])
    #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 101)
    try await store.ingestCodex(roots: [sessions])
    #expect(try await store.daily(since: "0000").reduce(0) { $0 + $1.tokens.total } == 101)
    #expect(throws: (any Error).self) {
        try ZstdReader.forEachLine(url: compressed, executable: URL(fileURLWithPath: "/nonexistent/zstd")) { _ in }
    }
}
