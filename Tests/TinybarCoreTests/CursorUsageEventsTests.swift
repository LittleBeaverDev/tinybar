import Foundation
import Testing
@testable import TinybarCore

private func cursorJWT(_ sub: String) -> String {
    let payload = Data("{\"sub\":\"\(sub)\"}".utf8).base64EncodedString()
    return "x.\(payload).x"
}
private func cursorResponse(_ json: String) throws -> CursorUsageEventsAPI.Response {
    try JSONDecoder().decode(CursorUsageEventsAPI.Response.self, from: Data(json.utf8))
}
private actor CursorPages {
    var starts: [Int64] = []
    var fail = false
    func setFail(_ value: Bool) { fail = value }
    func fetch(_ start: Int64, _ end: Int64, _ page: Int) throws -> CursorUsageEventsAPI.Response {
        starts.append(start)
        if page == 2 && fail { throw ProviderError.notConfigured }
        if page == 1 { return try cursorResponse("""
        {"totalUsageEventsCount":2,"usageEventsDisplay":[{"usageEventId":"no-tokens","timestamp":"1700000000000"}]}
        """) }
        return try cursorResponse("""
        {"totalUsageEventsCount":2,"usageEventsDisplay":[{"usageEventId":"one","timestamp":"1700000000000","tokenUsage":{"inputTokens":150001}}]}
        """)
    }
}

@Test func cursorPagesRetryDedupeAndAccounts() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try UsageStore(path: dir.appendingPathComponent("usage.sqlite"))
    let pages = CursorPages()
    let now = Date(timeIntervalSince1970: 1_700_100_000)
    await pages.setFail(true)
    do {
        try await store.syncCursorUsage(accessToken: cursorJWT("a"), now: now) { try await pages.fetch($0, $1, $2) }
        Issue.record("expected page failure")
    } catch {}
    await pages.setFail(false)
    try await store.syncCursorUsage(accessToken: cursorJWT("a"), now: now) { try await pages.fetch($0, $1, $2) }
    try await store.syncCursorUsage(accessToken: cursorJWT("a"), now: now.addingTimeInterval(3600)) { try await pages.fetch($0, $1, $2) }
    try await store.syncCursorUsage(accessToken: cursorJWT("b"), now: now.addingTimeInterval(3600)) { try await pages.fetch($0, $1, $2) }
    let starts = await pages.starts
    #expect(starts[0] == starts[2])
    #expect(starts[4] == now.millis - 86_400_000)
    #expect(starts[6] == now.millis + 3_600_000 - 30 * 86_400_000)
    let rows = try await store.daily(since: "0000", provider: .cursor)
    #expect(rows.count == 1)
    #expect(rows.first?.tokens.input == 150001)
    #expect(rows.first?.long[100_000]?.input == 150001)
    #expect(try await store.stats(since: "0000").first { $0.provider == .cursor && $0.key == StatKey.responses }?.value == 1)
}

@Test func cursorEmptySyncAndMigration() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("usage.sqlite")
    _ = try UsageStore(path: path)
    let db = try SQLiteDB(path: path.path)
    try db.exec("DROP TABLE cursor_usage_event; PRAGMA user_version = 10; INSERT INTO daily_usage VALUES ('2025-01-01','codex','old','',7,0,0,0);")
    let store = try UsageStore(path: path)
    #expect(try db.run("PRAGMA user_version").first?.first?.int == 11)
    #expect(try await store.daily(since: "0000").first?.tokens.input == 7)
    try await store.syncCursorUsage(accessToken: cursorJWT("a")) { _, _, _ in try cursorResponse("{}") }
    #expect(try await store.daily(since: "0000", provider: .cursor).isEmpty)
}

private final class CursorEventsProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        let valid = request.url?.host == "api2.cursor.sh" && request.httpMethod == "POST"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer abc"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            && body?["startDate"] == 10 && body?["endDate"] == 20 && body?["page"] == 2 && body?["pageSize"] == 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"usageEventsDisplay\":[{}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func cursorEventsRequest() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CursorEventsProtocol.self]
    let session = URLSession(configuration: config)
    let result = try await CursorUsageEventsAPI.fetch(accessToken: "abc", startDate: 10, endDate: 20, page: 2, session: session)
    #expect(result.usageEventsDisplay?.first?.tokenUsage == nil)
}
