import Foundation

public enum CursorUsageEventsAPI {
    public struct TokenUsage: Codable, Sendable {
        public var inputTokens: Int64?
        public var outputTokens: Int64?
        public var cacheReadTokens: Int64?
        public var cacheWriteTokens: Int64?
    }
    public struct Event: Codable, Sendable {
        public var usageEventId: String?
        public var timestamp: String?
        public var model: String?
        public var tokenUsage: TokenUsage?
    }
    public struct Response: Codable, Sendable {
        public var totalUsageEventsCount: Int?
        public var usageEventsDisplay: [Event]?
    }
    private struct Request: Encodable {
        var startDate: Int64
        var endDate: Int64
        var page: Int
        var pageSize: Int = 200
    }
    public static func fetch(accessToken: String, startDate: Int64, endDate: Int64, page: Int, session: URLSession = .tinybar) async throws -> Response {
        guard HTTP.isHeaderSafe(accessToken) else { throw ProviderError.notConfigured }
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Request(startDate: startDate, endDate: endDate, page: page))
        return try JSONDecoder().decode(Response.self, from: await HTTP.send(request, session: session, providerName: "Cursor"))
    }
}
