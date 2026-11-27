import Foundation
@testable import TinybarCore
import Testing

// MARK: Gemini (agy /usage report)

private let agyReport = #"""
{"conversation_id":"","status":"SUCCESS","response":"…","command":{"name":"usage","data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.8,"reset_time":"2026-10-07T11:50:26Z"},
  {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.25,"reset_time":"2026-09-30T16:50:26Z"}]},
 {"name":"Claude and GPT models","buckets":[
  {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-07T11:50:26Z"},
  {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.5}]}]}}}
"""#

@Test func mapsAntigravityUsageReport() throws {
    let s = try AntigravityCLI.snapshot(fromUsageReport: Data(agyReport.utf8))
    #expect(s.provider == .gemini)
    #expect(s.source == .cliProcess)
    #expect(s.windows.map(\.id) == ["session", "weekly", "third-party-session", "third-party-weekly"])
    #expect(s.windows[0].kind == .session && !s.windows[0].isModelSpecific)
    #expect(s.windows[0].remainingPercent == 25)
    #expect(s.windows[1].remainingPercent == 80)
    #expect(s.windows[2].title == "Claude & GPT 5-hour" && s.windows[2].isModelSpecific)
    #expect(s.windows[2].resetsAt == nil)
    #expect(s.windows[1].resetsAt == parseISODate("2026-10-07T11:50:26Z"))
}

@Test func antigravityFailureIsNotASnapshot() {
    let signedOut = #"{"status":"ERROR","response":"Please sign in to continue"}"#
    #expect(throws: ProviderError.loginExpired) { try AntigravityCLI.snapshot(fromUsageReport: Data(signedOut.utf8)) }
    #expect(throws: ProviderError.self) { try AntigravityCLI.snapshot(fromUsageReport: Data("not json".utf8)) }
}

// MARK: Cursor (usage-summary)

private func cursorSummary(_ json: String) throws -> ProviderSnapshot {
    CursorUsageAPI.snapshot(from: try JSONDecoder().decode(CursorUsageAPI.Summary.self, from: Data(json.utf8)))
}

@Test func mapsCursorPlanUsage() throws {
    let s = try cursorSummary(#"""
    {"membershipType":"pro","billingCycleStart":"2026-09-23T10:27:04.000Z","billingCycleEnd":"2026-10-23T10:27:04.000Z",
     "individualUsage":{"plan":{"enabled":true,"used":388,"limit":2000,"totalPercentUsed":19.4,"autoPercentUsed":2.5,"apiPercentUsed":36.3},
                        "onDemand":{"enabled":true,"used":450,"limit":1000}}}
    """#)
    #expect(s.plan == "Pro")
    #expect(s.windows.map(\.id) == ["monthly", "monthly-auto", "monthly-api"])
    #expect(abs(s.windows[0].remainingPercent - 80.6) < 0.001)
    #expect(s.windows[0].resetsAt == parseISODate("2026-10-23T10:27:04.000Z"))
    #expect(s.windows[0].durationSeconds == 30 * 86400)
    #expect(s.windows[0].kind == .other)
    #expect(s.windows[1].isModelSpecific && s.windows[2].isModelSpecific)
    #expect(s.extraUsage == ExtraUsageSpend(used: 4.5, limit: 10, currency: "USD"))
}

@Test func cursorFallsBackToCentsAndTeamPool() throws {
    let cents = try cursorSummary(#"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#)
    #expect(cents.windows.map(\.remainingPercent) == [75])
    let pooled = try cursorSummary(#"{"membershipType":"enterprise","teamUsage":{"pooled":{"used":100,"limit":400}}}"#)
    #expect(pooled.windows.map(\.remainingPercent) == [75])
    #expect(pooled.plan == "Enterprise")
    let unlimited = try cursorSummary(#"{"isUnlimited":true,"individualUsage":{"plan":{"totalPercentUsed":10}}}"#)
    #expect(unlimited.windows.isEmpty)
}

@Test func cursorFallsBackToTeamOnDemandSpend() throws {
    let team = try cursorSummary(#"{"teamUsage":{"onDemand":{"enabled":true,"used":450,"limit":1000}}}"#)
    #expect(team.extraUsage == ExtraUsageSpend(used: 4.5, limit: 10, currency: "USD"))
    let individual = try cursorSummary(#"{"individualUsage":{"onDemand":{"enabled":true,"used":100}},"teamUsage":{"onDemand":{"enabled":true,"used":450}}}"#)
    #expect(individual.extraUsage?.used == 1)
    let disabled = try cursorSummary(#"{"teamUsage":{"onDemand":{"enabled":false,"used":0}}}"#)
    #expect(disabled.extraUsage == nil)
    let priorSpend = try cursorSummary(#"{"teamUsage":{"onDemand":{"enabled":false,"used":450}}}"#)
    #expect(priorSpend.extraUsage?.used == 4.5)
}

@Test func cursorAppTokenBecomesSessionCookie() {
    func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    let token = "h.\(b64(#"{"sub":"auth0|user_ABC123","exp":4102444800}"#)).sig"
    #expect(CursorAppAuth.cookieHeader(accessToken: token) == "WorkosCursorSessionToken=user_ABC123%3A%3A\(token)")
    let bad = "h.\(b64(#"{"sub":"auth0|x;y"}"#)).sig"
    #expect(CursorAppAuth.cookieHeader(accessToken: bad) == nil)
    #expect(CursorAppAuth.decode(Data("\"tok\"".utf8)) == "tok")
    #expect(CursorAppAuth.decode("tok".data(using: .utf16LittleEndian)!) == "tok")
}


@Test func cursorSafeStorageEnvelopes() throws {
    let token = "h.eyJzdWIiOiJhdXRoMHx1c2VyIiwiZXhwIjo0MTAyNDQ0ODAwfQ.sig"
    let encrypted = "cursor-safe-storage:v1:djEwrS58+0ZzxnKlwnrprtUXHpTQg7M/BMxB0PGqdkBF4VxrxljpHxIVU0M9Wk9kxdyVnRakuWpA+JMjsGqGvN2dvg=="
    var calls = 0
    let cache = SafeStorage.Cache()
    let reader: (String, String) -> Data? = { service, account in
        calls += 1
        #expect(service == "Cursor Safe Storage" && account == "Cursor Key")
        return Data("password".utf8)
    }
    #expect(try CursorAppAuth.resolve(token, readPassword: reader, cache: cache) == token)
    #expect(calls == 0)
    let decrypted = try CursorAppAuth.resolve(encrypted, readPassword: reader, cache: cache)
    #expect(decrypted == token)
    #expect(CursorAppAuth.cookieHeader(accessToken: decrypted) == "WorkosCursorSessionToken=user%3A%3A\(token)")
    #expect(calls == 1)
    for invalid in ["cursor-safe-storage:v1:%%%", "cursor-safe-storage:v2:AAAA",
                    "cursor-safe-storage:v1:YWJj", "cursor-safe-storage:v1:djEw", "cursor-safe-storage:v1:djEwAA=="] {
        #expect(throws: ProviderError.self) { try CursorAppAuth.resolve(invalid, readPassword: reader, cache: cache) }
    }
    #expect(calls == 1)
    for invalid in ["djEwQTP6Oq2miYFdXOYlihqY6w==", "djEwhvJpaPiJc4MkqR82oy2zJQ=="] {
        #expect(throws: ProviderError.self) { try CursorAppAuth.resolve("cursor-safe-storage:v1:" + invalid, readPassword: reader, cache: cache) }
    }
    #expect(throws: ProviderError.self) { try CursorAppAuth.resolve(encrypted, readPassword: { _, _ in Data("wrong".utf8) }, cache: SafeStorage.Cache()) }
    #expect(throws: ProviderError.loginExpired) {
        try CursorAppAuth.resolve(token, now: Date(timeIntervalSince1970: 4102444750))
    }
}

@Test func cursorDeniedKeyIsCached() async {
    let cache = SafeStorage.Cache()
    let calls = CursorPasswordCalls()
    let stored = "cursor-safe-storage:v1:djEwQTP6Oq2miYFdXOYlihqY6w=="
    let provider = CursorProvider(storedToken: { stored }, browserCookie: { _ in nil },
                                  password: { _, _ in calls.increment(); return nil }, cache: cache)
    for _ in 0..<2 {
        do { _ = try await provider.fetch(); Issue.record("Expected Keychain error") }
        catch let error as ProviderError {
            if case .unexpected = error {} else { Issue.record("Expected unexpected error") }
        } catch { Issue.record("Unexpected error") }
    }
    #expect(calls.count == 1)
}

private final class CursorPasswordCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}


private final class CursorSummaryFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let isSand = request.url?.path == "/aiserver.v1.DashboardService/GetSandUsageStatus"
        let mode = request.value(forHTTPHeaderField: "X-Fixture-Mode")
        var status = 200
        let body: String
        if isSand {
            #expect(mode != "browser")
            #expect(request.url?.host == "api2.cursor.sh")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer h.eyJzdWIiOiJhdXRoMHx1c2VyIiwiZXhwIjo0MTAyNDQ0ODAwfQ.sig")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                bodyData = data
            }
            #expect(bodyData == Data("{}".utf8))
            if mode == "error" { status = 500; body = "error" }
            else if mode == "malformed" { body = "not json" }
            else { body = #"{"currentPeriodStart":"2026-09-30T11:50:26Z","nextResetTimestampUtc":"2026-10-07T11:50:26Z","usagePercent":25,"hasNonZeroIncludedLimit":true}"# }
        } else {
            #expect(request.url?.path == "/api/usage-summary")
            body = #"{"membershipType":"pro","individualUsage":{"plan":{"used":10,"limit":100}}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test func cursorFetchesAppAndFallsBackAfterDenial() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CursorSummaryFixture.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let token = "h.eyJzdWIiOiJhdXRoMHx1c2VyIiwiZXhwIjo0MTAyNDQ0ODAwfQ.sig"
    let app = CursorProvider(session: session, storedToken: { token }, browserCookie: { _ in nil })
    let snapshot = try await app.fetch()
    #expect(snapshot.plan == "Pro" && snapshot.source == .cli)
    #expect(snapshot.windows.map(\.id) == ["monthly", "grok-bot"])
    let grok = try #require(snapshot.windows.last)
    #expect(grok.title == "Grok Bot" && grok.isModelSpecific && grok.kind == .weekly)
    #expect(grok.remainingPercent == 75 && grok.durationSeconds == 7 * 86400)
    #expect(grok.resetsAt == parseISODate("2026-10-07T11:50:26Z"))
    let browserConfig = URLSessionConfiguration.ephemeral
    browserConfig.protocolClasses = [CursorSummaryFixture.self]
    browserConfig.httpAdditionalHeaders = ["X-Fixture-Mode": "browser"]
    let browserSession = URLSession(configuration: browserConfig)
    defer { browserSession.invalidateAndCancel() }
    let encrypted = "cursor-safe-storage:v1:djEwQTP6Oq2miYFdXOYlihqY6w=="
    let fallback = CursorProvider(session: browserSession, storedToken: { encrypted }, browserCookie: { _ in "fixture" },
                                  password: { _, _ in nil }, cache: SafeStorage.Cache())
    let browser = try await fallback.fetch()
    #expect(browser.plan == "Pro" && browser.source == .browser)
    #expect(browser.windows.map(\.id) == ["monthly"])
}

@Test func cursorGrokMappingEdgeCases() throws {
    func window(_ json: String) throws -> LimitWindow? {
        CursorUsageAPI.grokBotWindow(from: try JSONDecoder().decode(CursorUsageAPI.SandUsageStatus.self, from: Data(json.utf8)))
    }
    #expect(try window(#"{"usagePercent":150}"#)?.remainingPercent == 0)
    for json in [#"{"usagePercent":0}"#, #"{"usagePercent":-1}"#, #"{}"#,
                 #"{"usagePercent":10,"hasNonZeroIncludedLimit":false}"#] {
        #expect(try window(json) == nil)
    }
    let invalidDates = try #require(try window(#"{"usagePercent":10,"currentPeriodStart":"bad","nextResetTimestampUtc":"2026-10-07T11:50:26Z"}"#))
    #expect(invalidDates.durationSeconds == nil && invalidDates.resetsAt != nil)
    let reversed = try #require(try window(#"{"usagePercent":10,"currentPeriodStart":"2026-10-08T11:50:26Z","nextResetTimestampUtc":"2026-10-07T11:50:26Z"}"#))
    #expect(reversed.durationSeconds == nil)
}

@Test func cursorGrokFailuresPreserveSnapshot() async throws {
    let token = "h.eyJzdWIiOiJhdXRoMHx1c2VyIiwiZXhwIjo0MTAyNDQ0ODAwfQ.sig"
    for mode in ["error", "malformed"] {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CursorSummaryFixture.self]
        config.httpAdditionalHeaders = ["X-Fixture-Mode": mode]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let snapshot = try await CursorProvider(session: session, storedToken: { token }, browserCookie: { _ in nil }).fetch()
        #expect(snapshot.plan == "Pro" && snapshot.source == .cli)
        #expect(snapshot.windows.map(\.id) == ["monthly"] && snapshot.windows[0].remainingPercent == 90)
    }
}
