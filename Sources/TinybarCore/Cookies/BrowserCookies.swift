import CommonCrypto
import Foundation
import Darwin
import SQLite3

/// Reads session cookies from local browsers for the opt-in browser fallback (SPEC §4).
///
/// Chromium browsers encrypt cookies with a key kept in the login Keychain ("<Browser> Safe
/// Storage"); reading it shows a one-time macOS prompt, which is why this is opt-in. Firefox
/// stores cookies in plaintext. Safari needs Full Disk Access and is not supported.
public enum BrowserCookies {
    public struct Browser: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Under ~/Library/Application Support.
        var root: String
        var keychainService: String?
        var keychainAccount: String?
        var isFirefox = false
    }

    public static let browsers: [Browser] = [
        Browser(name: "Chrome", root: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        Browser(name: "Arc", root: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        Browser(name: "Dia", root: "Dia/User Data", keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
        Browser(name: "Brave", root: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        Browser(name: "Edge", root: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        Browser(name: "Comet", root: "Comet", keychainService: "Comet Safe Storage", keychainAccount: "Comet"),
        Browser(name: "Firefox", root: "Firefox/Profiles", isFirefox: true),
    ]

    public struct Found: Sendable {
        public var browser: String
        public var cookies: [String: String]
    }

    /// Returns the first browser profile holding all `required` cookie names for `domain`, with
    /// every cookie for that domain. Browsers are tried in order; decryption keys are only
    /// requested for a browser whose database actually contains the required cookie.
    public static func find(domain: String, required: [String]) -> Found? {
        for browser in browsers {
            for db in cookieDatabases(browser) {
                guard let rows = readRows(db: db, domain: domain, firefox: browser.isFirefox),
                      hasAll(required, in: rows.map(\.name))
                else { continue }
                let cookies = browser.isFirefox ? plaintext(rows) : decrypt(rows, browser: browser, db: db)
                if let cookies, hasAll(required, in: Array(cookies.keys)) {
                    return Found(browser: browser.name, cookies: cookies)
                }
            }
        }
        return nil
    }

    /// A required name also matches its chunked form ("name.0", "name.1", …).
    private static func hasAll(_ required: [String], in names: [String]) -> Bool {
        required.allSatisfy { r in names.contains { $0 == r || $0.hasPrefix(r + ".") } }
    }

    /// Value of a cookie that may be split into numbered chunks.
    public static func joined(_ name: String, in cookies: [String: String]) -> String? {
        if let v = cookies[name] { return v }
        var parts: [String] = []
        var i = 0
        while let part = cookies["\(name).\(i)"] { parts.append(part); i += 1 }
        return parts.isEmpty ? nil : parts.joined()
    }

    /// Browsers with a cookie database on this Mac (for the settings screen).
    public static func installed() -> [Browser] {
        browsers.filter { !cookieDatabases($0).isEmpty }
    }

    // MARK: Discovery

    static func cookieDatabases(_ browser: Browser) -> [URL] {
        let fm = FileManager.default
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(browser.root)
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        if browser.isFirefox {
            return entries.sorted().map { root.appendingPathComponent($0).appendingPathComponent("cookies.sqlite") }
                .filter { fm.fileExists(atPath: $0.path) }
        }
        let profiles = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        return profiles.compactMap { profile in
            let dir = root.appendingPathComponent(profile)
            return [dir.appendingPathComponent("Network/Cookies"), dir.appendingPathComponent("Cookies")]
                .first { fm.fileExists(atPath: $0.path) }
        }
    }

    // MARK: SQLite

    struct Row {
        var host: String
        var name: String
        var value: String
        var encrypted: Data
    }

    /// WAL contents are read from a private copy, never by opening the browser's live sidecars.
    static func readRows(db: URL, domain: String, firefox: Bool, now: Date = Date()) -> [Row]? {
        CredentialDatabase.read(db) { handle in
            let sql = firefox
                ? "SELECT host, name, value, NULL FROM moz_cookies WHERE (host = ? OR host = ?) AND expiry > ?"
                : "SELECT host_key, name, value, encrypted_value FROM cookies WHERE (host_key = ? OR host_key = ?) AND (expires_utc = 0 OR expires_utc > ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, domain, -1, transient)
            sqlite3_bind_text(stmt, 2, "." + domain, -1, transient)
            // Firefox uses Unix seconds; Chromium uses microseconds since 1601 (zero is a session cookie).
            let expiry = firefox ? now.timeIntervalSince1970 : (now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
            sqlite3_bind_double(stmt, 3, expiry)

            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text: (Int32) -> String = { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
                var encrypted = Data()
                if let blob = sqlite3_column_blob(stmt, 3) {
                    encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
                }
                rows.append(Row(host: text(0), name: text(1), value: text(2), encrypted: encrypted))
            }
            return rows
        }
    }

    static func metaVersion(db: URL) -> Int {
        CredentialDatabase.read(db) { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let v = sqlite3_column_text(stmt, 0) else { return nil }
            return Int(String(cString: v))
        } ?? 0
    }

    // MARK: Decryption

    static func plaintext(_ rows: [Row]) -> [String: String] {
        Dictionary(rows.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    static func decrypt(_ rows: [Row], browser: Browser, db: URL) -> [String: String]? {
        guard let key = key(for: browser) else { return nil }
        let stripsHostHash = metaVersion(db: db) >= 24
        var out: [String: String] = [:]
        for row in rows {
            if !row.value.isEmpty { out[row.name] = row.value; continue }
            guard var plain = SafeStorage.decrypt(row.encrypted, key: key)
            else { continue }
            // Newer Chromium prefixes the plaintext with SHA256(host_key).
            if stripsHostHash, plain.count >= 32 { plain = plain.dropFirst(32) }
            if let s = String(data: plain, encoding: .utf8) { out[row.name] = s }
        }
        return out
    }

    static func key(for browser: Browser, readPassword: (String, String) -> Data? = SafeStorage.keychainPassword) -> Data? {
        guard let service = browser.keychainService, let account = browser.keychainAccount else { return nil }
        return SafeStorage.key(service: service, account: account, readPassword: readPassword)
    }
}

/// Electron and Chromium Safe Storage share the same macOS key derivation and envelope.
enum SafeStorage {
    final class Cache: @unchecked Sendable {
        fileprivate let lock = NSLock()
        fileprivate var keys: [Identity: Data] = [:] // Empty data represents a denied lookup.
    }
    fileprivate struct Identity: Hashable { let service: String; let account: String }
    private static let shared = Cache()

    static func validEnvelope(_ data: Data) -> Bool {
        data.count > 3 && data.prefix(3) == Data("v10".utf8) && (data.count - 3) % 16 == 0
    }

    static func decrypt(_ data: Data, key: Data) -> Data? {
        guard validEnvelope(data) else { return nil }
        return aes128CBCDecrypt(Data(data.dropFirst(3)), key: key)
    }

    static func key(service: String, account: String, readPassword: (String, String) -> Data? = keychainPassword,
                    cache: Cache = shared) -> Data? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        let identity = Identity(service: service, account: account)
        if let cached = cache.keys[identity] { return cached.isEmpty ? nil : cached }
        cache.keys[identity] = Data()
        guard let password = readPassword(service, account) else { return nil }
        var derived = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                password.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        cache.keys[identity] = derived
        return derived
    }

    static func keychainPassword(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func aes128CBCDecrypt(_ data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress,
                            d.baseAddress, data.count,
                            o.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength
        return out
    }
}

/// Opening a live WAL database even read-only can write its shared-memory sidecar. Read immutable
/// without a WAL; otherwise let SQLite recover a private copy and remove it immediately afterward.
enum CredentialDatabase {
    static func read<T>(_ db: URL, cloneFirst: Bool = false, _ body: (OpaquePointer) -> T?) -> T? {
        let fm = FileManager.default
        var directory: URL?
        defer { if let directory { try? fm.removeItem(at: directory) } }
        var source = db
        let hasWAL = fm.fileExists(atPath: db.path + "-wal")
        if cloneFirst {
            guard let snapshot = snapshot(db) else { return nil }
            directory = snapshot.deletingLastPathComponent()
            source = snapshot
        } else if hasWAL {
            let temp = fm.temporaryDirectory.appendingPathComponent("tinybar-credentials-\(UUID().uuidString)")
            directory = temp
            do {
                try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                source = temp.appendingPathComponent("snapshot.sqlite")
                try fm.copyItem(at: db, to: source)
                try fm.copyItem(at: URL(fileURLWithPath: db.path + "-wal"), to: URL(fileURLWithPath: source.path + "-wal"))
            } catch { return nil }
        }
        let path = source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path
        let snapshotHasWAL = fm.fileExists(atPath: source.path + "-wal")
        let uri = "file:\(path)?" + (snapshotHasWAL ? "mode=ro" : "immutable=1")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 500)
        return body(handle)
    }
    private struct FileState: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private static func state(_ url: URL) -> FileState? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attrs[.systemFileNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileState(inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }

    private static func snapshot(_ db: URL) -> URL? {
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: db.path + "-wal")
        for _ in 0..<2 {
            guard let before = state(db) else { return nil }
            let walBefore = state(wal)
            let dir = fm.temporaryDirectory.appendingPathComponent("tinybar-credentials-\(UUID().uuidString)")
            let target = dir.appendingPathComponent("snapshot.sqlite")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                func clone(_ source: URL, _ dest: URL, size: UInt64) throws {
                    if clonefile(source.path, dest.path, 0) != 0 {
                        guard before.size <= 64 * 1024 * 1024, size <= 64 * 1024 * 1024 else {
                            throw CocoaError(.fileWriteOutOfSpace)
                        }
                        try fm.copyItem(at: source, to: dest)
                    }
                }
                try clone(db, target, size: before.size)
                if let walBefore { try clone(wal, URL(fileURLWithPath: target.path + "-wal"), size: walBefore.size) }
                if state(db) == before && state(wal) == walBefore { return target }
            } catch { /* A concurrent checkpoint may have removed the WAL; retry. */ }
            try? fm.removeItem(at: dir)
        }
        return nil
    }

}

/// Fetches limits using only the browser session (for diagnostics and the settings screen).
public enum BrowserFallback {
    public static func fetch(_ provider: ProviderID, session: URLSession = .tinybar) async throws -> (browser: String, snapshot: ProviderSnapshot) {
        switch provider {
        case .claude:
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw ProviderError.notConfigured }
            return (found.browser, try await ClaudeWebAPI.fetch(sessionKey: key, session: session))
        case .codex:
            guard let found = BrowserCookies.find(domain: "chatgpt.com", required: [ChatGPTWebSession.cookieName])
            else { throw ProviderError.notConfigured }
            let creds = try await ChatGPTWebSession.accessToken(cookies: found.cookies, session: session)
            async let usage = CodexUsageAPI.fetchUsage(creds, session: session)
            async let banked = try? CodexUsageAPI.fetchBankedResets(creds, session: session)
            var snapshot = try await CodexUsageAPI.snapshot(from: usage, bankedResets: banked)
            snapshot.source = .browser
            return (found.browser, snapshot)
        case .cursor:
            let name = CursorUsageAPI.sessionCookie
            guard let found = BrowserCookies.find(domain: "cursor.com", required: [name]), let value = found.cookies[name]
            else { throw ProviderError.notConfigured }
            return (found.browser, try await CursorUsageAPI.fetch(cookieHeader: "\(name)=\(value)", source: .browser, session: session))
        case .gemini, .opencode, .copilot, .grok:
            throw ProviderError.notConfigured
        }
    }
}
