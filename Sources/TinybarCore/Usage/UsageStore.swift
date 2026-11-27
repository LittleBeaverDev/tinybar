import Foundation

/// A row of the daily aggregate (SPEC §9).
public struct DailyUsage: Sendable, Hashable {
    public var day: String  // yyyy-MM-dd, local calendar day
    public var provider: ProviderID
    public var model: String
    public var project: String
    public var tokens: TokenCounts
    /// The part of `tokens` from long requests, by Context Band, for Long-context Prices.
    public var long: [Int64: TokenCounts] = [:]
}

/// Requests are filed by how far their context goes past these sizes, so Long-context Prices can
/// be applied at display time whatever tiers models.dev lists then (SPEC §10). Each request is
/// in one band: the largest size its context exceeds. A tier at a size between two bands is
/// applied from the next band up.
public enum ContextBand {
    public static let sizes: [Int64] = [100_000, 200_000, 272_000, 400_000, 1_000_000]

    public static func of(_ tokens: TokenCounts) -> Int64? {
        sizes.last { tokens.context > $0 }
    }
}

/// A row of the activity counters (SPEC §9).
public struct DailyStat: Sendable, Hashable {
    public var day: String
    public var provider: ProviderID
    public var model: String
    public var key: String
    public var value: Int64
}

/// Persistent store of daily token totals plus per-file read cursors, so history survives CLIs
/// deleting their logs and each ingest only reads appended bytes.
public actor UsageStore {
    private let db: SQLiteDB
    private let projects = ProjectResolver()
    private static let schemaVersion: Int64 = 11

    public init(path: URL = Paths.appSupport.appendingPathComponent("usage.sqlite")) throws {
        let db = try SQLiteDB(path: path.path)
        try db.transaction {
            try Self.migrate(db)
            try Self.armBackfill(db, key: "stats_backfill")
            try Self.armBackfill(db, key: "long_context_backfill", codexOnly: true)
        }
        self.db = db
    }

    private static func migrate(_ db: SQLiteDB) throws {
        let version = try db.run("PRAGMA user_version").first?.first?.int ?? 0
        guard version < schemaVersion else { return }
        try db.exec("CREATE TABLE IF NOT EXISTS cursor_usage_event (id TEXT PRIMARY KEY, timestamp_ms INTEGER NOT NULL) WITHOUT ROWID;")
        if version == 10 {
            try db.exec("PRAGMA user_version = 11;")
            return
        }
        try db.exec("CREATE TABLE IF NOT EXISTS pi_message (id TEXT PRIMARY KEY, day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, context INTEGER NOT NULL) WITHOUT ROWID;")
        if version == 9 {
            try db.exec("PRAGMA user_version = 11;")
            return
        }
        if version == 7 || version == 8 {
            // 0.9.0 keeps readings per Account. The ones so far can mix Accounts, so they stay
            // unclaimed (SPEC §14).
            try db.exec("""
            ALTER TABLE limit_reading RENAME TO limit_reading_old;
            \(limitReadingSchema)
            \(openCodeMessageSchema)
            INSERT INTO limit_reading (provider, account, window, resets_at, duration, plan, used_bp, read_at, plan_changed)
            SELECT provider, '', window, resets_at, duration, plan, used_bp, read_at, plan_changed FROM limit_reading_old;
            DROP TABLE limit_reading_old;
            PRAGMA user_version = \(schemaVersion);
            """)
            return
        }
        try db.exec(limitReadingSchema + openCodeMessageSchema)
        if version == 6 {
            try db.exec("PRAGMA user_version = \(schemaVersion);")
            return
        }
        if version >= 2 {
            // 0.5.0 files long requests by Context Band. Claude's come from the messages kept for
            // de-duplication; Codex logs are read again by `backfillLongContext`.
            try db.exec(longContextSchema)
            try db.exec("""
            INSERT OR REPLACE INTO daily_long_context
                (day, provider, model, project, band, input, output, cache_write, cache_read)
            SELECT day, provider, model, project, \(bandSQL("input + cache_write + cache_read")),
                   sum(input), sum(output), sum(cache_write), sum(cache_read)
            FROM claude_message WHERE input + cache_write + cache_read > \(ContextBand.sizes[0])
            GROUP BY 1, 2, 3, 4, 5;
            """)
        }
        if version == 5 {
            try db.exec("PRAGMA user_version = \(schemaVersion);")
            return
        }
        if version == 3 || version == 4 {
            // 0.2.0 kept prompts, tool calls, lines and Agent Time without their model; 0.3.0 had
            // no shell commands, file kinds or parallel tool calls. Count all activity again from
            // the logs still on disk (the backfill runs next).
            try db.exec("""
            DELETE FROM daily_stat;
            DELETE FROM claude_event;
            UPDATE claude_message SET stats = NULL;
            DELETE FROM meta WHERE key = 'stats_backfill';
            PRAGMA user_version = \(schemaVersion);
            """)
            return
        }
        if version == 2 {
            try db.exec("ALTER TABLE claude_message ADD COLUMN stats TEXT;" + statSchema + "PRAGMA user_version = \(schemaVersion);")
            return
        }
        if version == 1 {
            try db.exec(claudeMessageSchema + statSchema + longContextSchema + "PRAGMA user_version = \(schemaVersion);")
            return
        }
        try db.exec(claudeMessageSchema + statSchema + longContextSchema)
        try db.exec("""
        INSERT OR REPLACE INTO meta (key, value) VALUES ('long_context_backfill', 'done'), ('opencode_import', 'done');
        CREATE TABLE IF NOT EXISTS daily_usage (
            day TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, provider, model, project)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS file_cursor (
            path TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            state BLOB
        ) WITHOUT ROWID;
        PRAGMA user_version = \(schemaVersion);
        """)
    }

    /// The tokens of long requests (SPEC §10), a subset of `daily_usage` by Context Band.
    private static let longContextSchema = """
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS daily_long_context (
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        project TEXT NOT NULL,
        band INTEGER NOT NULL,
        input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, provider, model, project, band)
    ) WITHOUT ROWID;
    """

    /// `ContextBand.of` in SQL, for a context expression.
    private static func bandSQL(_ context: String) -> String {
        "CASE " + ContextBand.sizes.reversed().map { "WHEN \(context) > \($0) THEN \($0)" }.joined(separator: " ") + " END"
    }

    /// One row per Claude message id: the usage we have counted for it, so a later, more
    /// complete copy of the same message replaces its contribution instead of adding to it.
    private static let claudeMessageSchema = """
    CREATE TABLE IF NOT EXISTS claude_message (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        project TEXT NOT NULL,
        input INTEGER NOT NULL,
        output INTEGER NOT NULL,
        cache_write INTEGER NOT NULL,
        cache_read INTEGER NOT NULL,
        stats TEXT
    ) WITHOUT ROWID;
    """

    /// The latest reading of each Account's weekly Limit Window (SPEC §14). `used_bp` is hundredths
    /// of a percent, `plan_changed` a plan change during the window. `account` is empty until one
    /// claims the reading.
    private static let limitReadingSchema = """
    CREATE TABLE IF NOT EXISTS limit_reading (
        provider TEXT NOT NULL,
        account TEXT NOT NULL DEFAULT '',
        window TEXT NOT NULL,
        resets_at INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        plan TEXT,
        used_bp INTEGER NOT NULL,
        read_at INTEGER NOT NULL,
        plan_changed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (provider, account, window, resets_at)
    ) WITHOUT ROWID;
    """

    /// The OpenCode responses already counted (`OpenCodeHistory.Row.key`). Kept for good, as a fork
    /// can copy a message of any age.
    private static let openCodeMessageSchema = """
    CREATE TABLE IF NOT EXISTS opencode_message (key TEXT PRIMARY KEY) WITHOUT ROWID;
    """

    /// Activity counters (SPEC §9), and the ids of one-off Claude events (prompts, edits,
    /// compactions) already counted, since resumed sessions copy them into new transcripts.
    private static let statSchema = """
    CREATE TABLE IF NOT EXISTS daily_stat (
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        key TEXT NOT NULL,
        value INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, provider, model, key)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS claude_event (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL
    ) WITHOUT ROWID;
    """

    // MARK: Ingestion

    public struct IngestProgress: Sendable {
        public var filesDone: Int
        public var filesTotal: Int
    }

    public struct IngestResult: Sendable {
        public var filesScanned: Int
        public var bytesRead: Int64
        public var recordsAdded: Int
    }

    /// Looked for each time, since a login folder or `cswap run` profile can appear at any point.
    public static var codexRoots: [URL] { Paths.codexLogRoots() }

    public static var claudeRoots: [URL] { Paths.claudeLogRoots() }
    public static var piRoots: [URL] { Paths.piLogRoots() }
    public static var geminiRoots: [URL] { [Paths.agyBrain()] }
    public static var logRoots: [URL] { codexRoots + claudeRoots + piRoots + geminiRoots }

    public enum LogSource: String, Sendable, CaseIterable {
        case codex, claude, pi, gemini

        public var roots: [URL] {
            switch self {
            case .codex: UsageStore.codexRoots
            case .claude: UsageStore.claudeRoots
            case .pi: UsageStore.piRoots
            case .gemini: UsageStore.geminiRoots
            }
        }
    }

    /// Ingests every source. With `only`, just those log paths are checked (from `LogWatcher`)
    /// instead of walking every root.
    @discardableResult
    public func ingestAll(
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        var total = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        for source in LogSource.allCases {
            let r = try ingest(source, roots: source.roots, only: only, progress: progress)
            total.filesScanned += r.filesScanned
            total.bytesRead += r.bytesRead
            total.recordsAdded += r.recordsAdded
        }
        // A store from before OpenCode reads its history once in the child process first.
        if try hasCompletedOpenCodeImport() { total.recordsAdded += try ingestOpenCode() }
        try pruneClaudeMessagesDaily()
        return total
    }

    @discardableResult
    public func ingestCodex(
        roots: [URL] = UsageStore.codexRoots,
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        try ingest(.codex, roots: roots, only: only, progress: progress)
    }

    @discardableResult
    public func ingestClaude(
        roots: [URL] = UsageStore.claudeRoots,
        only: Set<String>? = nil,
        progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult
    {
        try ingest(.claude, roots: roots, only: only, progress: progress)
    }

    @discardableResult
    public func ingestPi(roots: [URL] = UsageStore.piRoots, only: Set<String>? = nil,
                         progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        try ingest(.pi, roots: roots, only: only, progress: progress)
    }

    @discardableResult
    public func ingestGemini(roots: [URL] = UsageStore.geminiRoots, only: Set<String>? = nil,
                             progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        try ingest(.gemini, roots: roots, only: only, progress: progress)
    }

    /// OpenCode's database and WAL at the last good read, to skip reading them unchanged.
    private var openCodeStamps: [FileStamp?] = []

    /// OpenCode keeps a database, not logs, so it is checked on every ingest. One that can't be read
    /// or has changed shape adds nothing and doesn't stop the other sources. Returns the responses added.
    @discardableResult
    func ingestOpenCode(
        database: URL? = OpenCodeData().database,
        read: @Sendable (URL, Int64) -> OpenCodeHistory.Reading? = OpenCodeHistory.read(database:after:)) throws -> Int
    {
        guard let database else { return 0 }
        func stamps() -> [FileStamp?] { [database.path, database.path + "-wal"].map(Self.stamp) }
        let before = stamps()
        guard before != openCodeStamps else { return 0 }
        // Never past now: one row dated in the future, by a wrong clock or corruption, would
        // otherwise hide every later row for good.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Another file (a restored backup, a new `OPENCODE_DB`) starts over; responses count once anyway.
        let source = "\(database.path)#\(before[0]?.inode ?? 0)"
        let sameSource = try db.run("SELECT value FROM meta WHERE key = 'opencode_source'").first?.first?.text == source
        let cursor = sameSource ? try db.run("SELECT value FROM meta WHERE key = 'opencode_cursor'").first?.first?.text.flatMap { Int64($0) } : nil
        var seen = min(cursor ?? 0, now)
        guard var reading = read(database, seen) else { return 0 }
        if reading.newest < seen {
            // The database went back, as when a backup is restored over the same file.
            seen = 0
            guard let whole = read(database, seen) else { return 0 }
            reading = whole
        }
        // A checkpoint between copying the database and its WAL can leave out an older row while
        // keeping a newer one. What was read still counts, but only a settled read moves on from it.
        let settled = stamps() == before
        let newest = settled ? min(max(seen, reading.newest), now) : seen
        var added = 0
        if !reading.rows.isEmpty || newest > seen {
            try db.transaction {
                for row in reading.rows {
                    try db.run("INSERT OR IGNORE INTO opencode_message (key) VALUES (?)", [.text(row.key)])
                    guard db.changes > 0 else { continue }
                    try addTokens(
                        day: DayKey.string(for: row.record.timestamp), provider: .opencode,
                        model: ModelName.normalize(row.record.model), project: projects.project(for: row.record.cwd),
                        row.record.tokens)
                    added += 1
                }
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('opencode_cursor', ?), ('opencode_source', ?)", [.text(String(newest)), .text(source)])
            }
        }
        if settled { openCodeStamps = before }
        return added
    }

    /// The first read of OpenCode's history for a store that predates it, in the child process.
    public func importOpenCode() throws {
        try importOpenCode(database: OpenCodeData().database)
    }

    /// Done only once it has read the database whole, or there is none. Until then normal ingestion
    /// stays away, and the next launch tries again. A busy database gets a few tries.
    func importOpenCode(database: URL?) throws {
        openCodeStamps = []
        for _ in 0..<3 where openCodeStamps.isEmpty { try ingestOpenCode(database: database) }
        if let database, FileManager.default.fileExists(atPath: database.path), openCodeStamps.isEmpty {
            throw ProviderError.unexpected("Couldn't read OpenCode's database")
        }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('opencode_import', 'done')")
    }

    public func hasCompletedOpenCodeImport() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'opencode_import'").first?.first?.text == "done"
    }

    /// Reads only bytes appended since the last run of each changed file.
    private func ingest(
        _ source: LogSource, roots: [URL], only: Set<String>?,
        progress: (@Sendable (IngestProgress) -> Void)?) throws -> IngestResult
    {
        var changed: [(String, FileStamp)] = []
        if let only {
            let rootPaths = roots.map { $0.path + "/" }
            for path in only where Self.acceptsLog(path, source: source) && rootPaths.contains(where: { prefix in
                path.hasPrefix(prefix) && (source != .gemini || path.dropFirst(prefix.count).split(separator: "/").count == 4)
            }) {
                if let stamp = Self.stamp(path), try isChanged(path, stamp) { changed.append((path, stamp)) }
            }
        } else {
            for root in roots {
                try Self.walkJSONL(root.path, source: source) { path, stamp in
                    if source == .gemini && path.dropFirst(root.path.count + 1).split(separator: "/").count != 4 { return }
                    if try isChanged(path, stamp) { changed.append((path, stamp)) }
                }
            }
        }
        if source == .codex {
            changed.removeAll { path, _ in
                path.hasSuffix(".jsonl.zst") && Self.stamp(String(path.dropLast(4))) != nil
            }
        }
        // Oldest first, so a fork's parent is ingested before the fork when both are new.
        changed.sort { $0.1.mtime < $1.1.mtime }

        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var index = 0
        while index < changed.count {
            let batch = changed[index..<min(index + batchSize, changed.count)]
            var maps: [String: AgyProjectMap] = [:]
            if source == .gemini {
                for root in roots {
                    maps[root.path] = AgyProjectMap(database: root.deletingLastPathComponent().appendingPathComponent("conversation_summaries.db"), resolver: projects)
                }
            }
            try db.transaction {
                for (path, stamp) in batch {
                    try db.exec("SAVEPOINT ingest_file")
                    let read: Int64
                    let added: Int
                    do {
                        (read, added) = try autoreleasepool {
                            let cursor = try source == .codex ? codexCursor(path: path, stamp: stamp) : loadCursor(path: path)
                            switch source {
                            case .codex: return try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .incremental)
                            case .claude: return try ingestClaudeFile(path: path, stamp: stamp, cursor: cursor, mode: .incremental)
                            case .pi: return try ingestPiFile(path: path, stamp: stamp, cursor: cursor)
                            case .gemini:
                                let root = roots.first { path.hasPrefix($0.path + "/") }
                                let id = root.map { String(path.dropFirst($0.path.count + 1)).components(separatedBy: "/").first ?? "" } ?? ""
                                return try ingestGeminiFile(path: path, stamp: stamp, cursor: cursor, project: root.flatMap { maps[$0.path]?.projects[id] } ?? ProjectResolver.noProject)
                            }
                        }
                        try db.exec("RELEASE ingest_file")
                    } catch let error as ZstdReader.Failure {
                        try db.exec("ROLLBACK TO ingest_file; RELEASE ingest_file")
                        NSLog("Tinybar: could not decode %@: %@", path, String(describing: error))
                        continue
                    }
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
            }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: changed.count))
        }
        if result.filesScanned > batchSize {
            // A large import leaves the malloc heap full of freed pages; hand them back to the OS
            // so the idle footprint stays small.
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    private func isChanged(_ path: String, _ stamp: FileStamp) throws -> Bool {
        guard let known = try db.run(
            "SELECT inode, size, mtime FROM file_cursor WHERE path = ?", [.text(path)]).first
        else { return true }
        return FileStamp(inode: known[0].int, size: known[1].int, mtime: known[2].int) != stamp
    }

    /// How a file is read. `backfill` re-reads what an earlier version already counted, up to the
    /// saved offset, for activity stats only: token totals and offsets stay as they are.
    /// `longContext` is the same for the tokens of long requests (Codex only; schema 6).
    enum ReadMode {
        case incremental
        case backfill
        case longContext
    }

    private func ingestCodexFile(path: String, stamp: FileStamp, cursor: Cursor?, mode: ReadMode, limit: Int64? = nil) throws -> (Int64, Int) {
        let url = URL(fileURLWithPath: path)
        // Resume only if it's the same file and it only grew; otherwise start over.
        var parser = CodexLogParser()
        var offset: Int64 = 0
        var until: Int64?
        if mode != .incremental {
            guard let cursor else { return (0, 0) }
            until = limit ?? cursor.offset
        } else if !path.hasSuffix(".zst"), let cursor, cursor.stamp.inode == stamp.inode, stamp.size > cursor.stamp.size || stamp == cursor.stamp,
           let state = cursor.state, let decoded = try? JSONDecoder().decode(CodexLogParser.self, from: state)
        {
            parser = decoded
            offset = cursor.offset
        } else if let state = cursor?.state, let decoded = try? JSONDecoder().decode(CodexLogParser.self, from: state) {
            parser = CodexLogParser(replaying: decoded)
        }

        var agg: [AggKey: TokenCounts] = [:]
        var long: [AggKey: TokenCounts] = [:]
        var stats = StatBatch()
        var added = 0
        func consume(_ line: UnsafeRawBufferPointer) {
            let current = ModelName.normalize(parser.model ?? "unknown")
            let record = parser.consume(line: line) { if mode != .longContext { stats.add($0, provider: .codex, model: current) } }
            guard let record else { return }
            let day = DayKey.string(for: record.timestamp)
            let model = ModelName.normalize(record.model)
            if mode != .longContext {
                stats.addResponse(day: day, provider: .codex, model: model, at: record.timestamp, tokens: record.tokens)
            }
            if mode != .backfill {
                let key = AggKey(day: day, model: model, project: self.projects.project(for: record.cwd))
                if mode == .incremental { agg[key, default: TokenCounts()] += record.tokens }
                if let band = ContextBand.of(record.tokens) { long[key.band(band), default: TokenCounts()] += record.tokens }
            }
            added += 1
        }

        let endOffset: Int64
        if path.hasSuffix(".jsonl.zst") {
            endOffset = try ZstdReader.forEachLine(url: url, until: until, consume)
        } else {
            endOffset = try JSONLReader.forEachLine(url: url, from: offset, until: until, consume)
        }

        for (key, t) in agg {
            try addDaily(day: key.day, provider: .codex, model: key.model, project: key.project, t)
        }
        for (key, tokens) in long {
            let t = mode == .longContext ? try boundedBackfill(tokens, key: key) : tokens
            if !t.isZero { try addLong(day: key.day, provider: .codex, model: key.model, project: key.project, band: key.band, t) }
        }
        try write(stats)
        let state = (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) }
        if mode != .incremental, let cursor {
            if until == cursor.offset { try saveCursor(path: path, source: .codex, stamp: cursor.stamp, offset: cursor.offset, state: state) }
        } else {
            try saveCursor(path: path, source: .codex, stamp: stamp, offset: endOffset, state: state)
        }
        return (endOffset - offset, added)
    }

    private func ingestGeminiFile(path: String, stamp: FileStamp, cursor: Cursor?, project: String) throws -> (Int64, Int) {
        var offset: Int64 = 0
        if let cursor, cursor.stamp.inode == stamp.inode, stamp.size >= cursor.stamp.size {
            offset = cursor.offset
        }
        let parser = AgyLogParser()
        var entries: [AgyLogParser.Entry] = []
        let end = try JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: offset) { line in
            if let entry = parser.consume(line: line) { entries.append(entry) }
        }
        var stats = StatBatch()
        for entry in entries {
            let r = entry.record, day = DayKey.string(for: r.timestamp)
            try addTokens(day: day, provider: .gemini, model: r.model, project: project, r.tokens)
            stats.addResponse(day: day, provider: .gemini, model: r.model, at: r.timestamp, tokens: r.tokens)
            for tool in entry.tools {
                var values = tool.commandStats
                values[StatKey.tool(tool.name), default: 0] += 1
                stats.add(StatEvent(timestamp: r.timestamp, values: values), provider: .gemini, model: r.model)
            }
        }
        try write(stats)
        try saveCursor(path: path, source: .gemini, stamp: stamp, offset: end, state: nil)
        return (end - offset, entries.count)
    }

    private func ingestPiFile(path: String, stamp: FileStamp, cursor: Cursor?) throws -> (Int64, Int) {
        var parser = PiLogParser()
        var offset: Int64 = 0
        if let cursor, cursor.stamp.inode == stamp.inode, stamp.size > cursor.stamp.size || stamp == cursor.stamp,
           let state = cursor.state, let decoded = try? JSONDecoder().decode(PiLogParser.self, from: state) {
            parser = decoded
            offset = cursor.offset
        }
        var entries: [PiLogParser.Entry] = []
        let end = try JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: offset) { line in
            if let entry = parser.consume(line: line) { entries.append(entry) }
        }
        var added = 0
        var stats = StatBatch()
        for entry in entries {
            guard let provider = ProviderID(rawValue: entry.provider) else { continue }
            let record = entry.record
            let day = DayKey.string(for: record.timestamp)
            let model = record.model
            try db.run("INSERT OR IGNORE INTO pi_message (id, day, provider, model, context) VALUES (?, ?, ?, ?, ?)",
                       [.text(entry.id), .text(day), .text(provider.rawValue), .text(model), .int(record.tokens.context)])
            guard db.changes > 0 else { continue }
            try addTokens(day: day, provider: provider, model: model, project: projects.project(for: record.cwd), record.tokens)
            stats.addResponse(day: day, provider: provider, model: model, at: record.timestamp, tokens: record.tokens)
            for tool in entry.tools {
                var values = tool.commandStats
                values[StatKey.tool(tool.name), default: 0] += 1
                stats.add(StatEvent(timestamp: record.timestamp, values: values), provider: provider, model: model)
            }
            added += 1
        }
        try write(stats)
        let state = (try? JSONEncoder().encode(parser)).map { String(decoding: $0, as: UTF8.self) }
        try saveCursor(path: path, source: .pi, stamp: stamp, offset: end, state: state)
        return (end - offset, added)
    }

    private func ingestClaudeFile(path: String, stamp: FileStamp, cursor: Cursor?, mode: ReadMode, limit: Int64? = nil) throws -> (Int64, Int) {
        // Counting is per message id and idempotent, so a replaced or truncated file can simply
        // be re-read from the start.
        var offset: Int64 = 0
        var until: Int64?
        var session = ClaudeLogParser.Session(subagentFile: path.contains("/subagents/"))
        if mode == .backfill {
            guard let cursor else { return (0, 0) }
            until = limit ?? cursor.offset
        } else if let cursor, cursor.stamp.inode == stamp.inode, stamp.size > cursor.stamp.size || stamp == cursor.stamp {
            offset = cursor.offset
            if let state = cursor.state, let decoded = try? JSONDecoder().decode(ClaudeLogParser.Session.self, from: state) {
                session = decoded
            }
        }

        // Merge within the file first: streaming writes several lines per message.
        var latest: [String: ClaudeMessage] = [:]
        var order: [String] = []
        var events: [(id: String, at: Date, model: String, values: [String: Int64])] = []
        let endOffset = try JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: offset, until: until) { line in
            for event in session.consume(line: line) {
                switch event {
                case let .message(m):
                    if latest[m.entry.messageID] != nil {
                        latest[m.entry.messageID]!.merge(m)
                    } else {
                        latest[m.entry.messageID] = ClaudeMessage(m)
                        order.append(m.entry.messageID)
                    }
                case let .prompt(id, at, model):
                    events.append(("p:" + id, at, model, [StatKey.prompts: 1]))
                case let .edit(id, at, model, ext, added, removed):
                    events.append(("e:" + id, at, model, StatKey.edit(ext: ext, added: added, removed: removed)
                        .merging([StatKey.linesAdded: added, StatKey.linesRemoved: removed]) { a, _ in a }))
                case let .command(id, at, model, values):
                    events.append(("b:" + id, at, model, values))
                case let .commandResult(id, at, model, failed):
                    events.append(("x:" + id, at, model, [StatKey.commandsFinished: 1, StatKey.commandsFailed: failed ? 1 : 0]))
                case let .compaction(id, at, model, dropped):
                    events.append(("c:" + id, at, model, [StatKey.compactions: 1, StatKey.compactedTokens: dropped]))
                }
            }
        }

        var added = 0
        for id in order {
            guard let message = latest[id] else { continue }
            if try upsertClaudeMessage(id: id, message, countTokens: mode == .incremental) { added += 1 }
        }
        var stats = StatBatch()
        for event in events {
            let day = DayKey.string(for: event.at)
            try db.run("INSERT OR IGNORE INTO claude_event (id, day) VALUES (?, ?)", [.text(event.id), .text(day)])
            if db.changes > 0 {
                stats.add(StatEvent(timestamp: event.at, values: event.values),
                          provider: ClaudeLogParser.provider(forModel: event.model), model: event.model)
            }
        }
        try write(stats)
        let state = (try? JSONEncoder().encode(session)).map { String(decoding: $0, as: UTF8.self) }
        if mode == .backfill, let cursor {
            if until == cursor.offset { try saveCursor(path: path, source: .claude, stamp: cursor.stamp, offset: cursor.offset, state: state) }
        } else {
            try saveCursor(path: path, source: .claude, stamp: stamp, offset: endOffset, state: state)
        }
        return (endOffset - offset, added)
    }

    /// Records a message's usage and activity, replacing any earlier count for the same id.
    /// With `countTokens` false (backfill) the daily token totals are left alone.
    /// Returns true for a message seen for the first time.
    private func upsertClaudeMessage(id: String, _ message: ClaudeMessage, countTokens: Bool = true) throws -> Bool {
        let record = message.record
        let existing = try db.run(
            "SELECT day, provider, model, project, input, output, cache_write, cache_read, stats FROM claude_message WHERE id = ?",
            [.text(id)]).first

        if let e = existing {
            let old = TokenCounts(input: e[4].int, output: e[5].int, cacheWrite: e[6].int, cacheRead: e[7].int)
            // Activity-only replay must not change the snapshot paired with daily totals.
            let final = countTokens ? old.mergingCopy(record.tokens) : old
            let oldStats = e[8].text.flatMap { try? JSONDecoder().decode(MessageStats.self, from: Data($0.utf8)) }
            let newStats = MessageStats(message).merged(with: oldStats)
            let tokensChanged = final != old
            guard tokensChanged || newStats != oldStats else { return false }

            let day = e[0].text ?? ""
            let provider = e[1].text.flatMap(ProviderID.init(rawValue:)) ?? .claude
            let model = e[2].text ?? ""
            if tokensChanged && countTokens {
                // Undo the old contribution, keeping its original day/model/project.
                let project = e[3].text ?? ""
                try addDaily(day: day, provider: provider, model: model, project: project, -old)
                try addDaily(day: day, provider: provider, model: model, project: project, final)
                if let band = ContextBand.of(old) {
                    try addLong(day: day, provider: provider, model: model, project: project, band: band, -old)
                }
                if let band = ContextBand.of(final) {
                    try addLong(day: day, provider: provider, model: model, project: project, band: band, final)
                }
            }
            var stats = StatBatch()
            stats.replace(
                day: day, provider: provider, model: model,
                old: oldStats?.contributions(tokens: old) ?? [:], new: newStats.contributions(tokens: final))
            if final.context < old.context {
                // A complete copy can carry less context than its preliminary line: drop the peak
                // that line set to the largest of the day's other messages.
                let others = try db.run("""
                SELECT max(context) FROM (
                    SELECT input + cache_write + cache_read AS context FROM claude_message
                    WHERE day = ? AND provider = ? AND model = ? AND id != ?
                    UNION ALL SELECT context FROM pi_message WHERE day = ? AND provider = ? AND model = ?
                )
                """, [.text(day), .text(provider.rawValue), .text(model), .text(id), .text(day), .text(provider.rawValue), .text(model)]).first?.first?.int ?? 0
                try db.run("""
                UPDATE daily_stat SET value = ? WHERE day = ? AND provider = ? AND model = ? AND key = ? AND value = ?
                """, [.int(others), .text(day), .text(provider.rawValue), .text(model), .text(StatKey.contextMax), .int(old.context)])
            }
            stats.addMaximum(day: day, provider: provider, model: model, StatKey.contextMax, final.context)
            try write(stats)
            try db.run("""
            UPDATE claude_message SET input = ?, output = ?, cache_write = ?, cache_read = ?, stats = ? WHERE id = ?
            """, [.int(final.input), .int(final.output), .int(final.cacheWrite),
                  .int(final.cacheRead), .text(newStats.encoded), .text(id)])
            return false
        }

        let day = DayKey.string(for: record.timestamp)
        let model = ModelName.normalize(record.model)
        let provider = ClaudeLogParser.provider(forModel: model)
        let project = projects.project(for: record.cwd)
        if countTokens {
            try addTokens(day: day, provider: provider, model: model, project: project, record.tokens)
        }
        let newStats = MessageStats(message)
        var stats = StatBatch()
        stats.replace(day: day, provider: provider, model: model, old: [:], new: newStats.contributions(tokens: record.tokens))
        stats.addMaximum(day: day, provider: provider, model: model, StatKey.contextMax, record.tokens.context)
        try write(stats)
        try db.run("""
        INSERT INTO claude_message (id, day, provider, model, project, input, output, cache_write, cache_read, stats)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [.text(id), .text(day), .text(provider.rawValue), .text(model), .text(project),
              .int(record.tokens.input), .int(record.tokens.output), .int(record.tokens.cacheWrite), .int(record.tokens.cacheRead),
              .text(newStats.encoded)])
        return true
    }

    /// Imports remote Cursor activity. The watermark is committed only after every page succeeds.
    public func syncCursorUsage(accessToken: String, now: Date = Date(),
        fetch: @Sendable (Int64, Int64, Int) async throws -> CursorUsageEventsAPI.Response) async throws {
        guard let sub = CursorAppAuth.jwtPayload(accessToken)?["sub"] as? String, !sub.isEmpty else {
            throw ProviderError.notConfigured
        }
        let key = "cursor_usage_watermark:" + sub
        let end = now.millis
        let saved = try db.run("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.first?.text.flatMap(Int64.init)
        let start = min(end, saved.map { $0 - 86_400_000 } ?? (end - 30 * 86_400_000))
        var page = 1
        var count = 0
        while true {
            let response = try await fetch(start, end, page)
            let events = response.usageEventsDisplay ?? []
            try db.transaction {
                var stats = StatBatch()
                for event in events {
                    guard let id = event.usageEventId, !id.isEmpty, let timestamp = event.timestamp,
                          timestamp.count == 13, let ms = Int64(timestamp) else { continue }
                    try db.run("INSERT OR IGNORE INTO cursor_usage_event (id, timestamp_ms) VALUES (?, ?)", [.text(id), .int(ms)])
                    guard db.changes > 0, let usage = event.tokenUsage else { continue }
                    let tokens = TokenCounts(input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0,
                                             cacheWrite: usage.cacheWriteTokens ?? 0, cacheRead: usage.cacheReadTokens ?? 0)
                    guard tokens.total > 0 else { continue }
                    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
                    let day = DayKey.string(for: date)
                    let model = ModelName.normalize(event.model ?? "unknown")
                    try addTokens(day: day, provider: .cursor, model: model, project: ProjectResolver.noProject, tokens)
                    stats.addResponse(day: day, provider: .cursor, model: model, at: date, tokens: tokens)
                }
                try write(stats)
            }
            count += events.count
            if events.isEmpty || (response.totalUsageEventsCount.map { count >= $0 } ?? (events.count < 200)) { break }
            page += 1
        }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(String(end))])
    }

    public func syncCursorUsage(accessToken: String, now: Date = Date()) async throws {
        try await syncCursorUsage(accessToken: accessToken, now: now) { start, end, page in
            try await CursorUsageEventsAPI.fetch(accessToken: accessToken, startDate: start, endDate: end, page: page)
        }
    }

    // MARK: Activity stats

    private func write(_ batch: StatBatch) throws {
        for (slot, value) in batch.sums where value != 0 {
            try db.run("""
            INSERT INTO daily_stat (day, provider, model, key, value) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day, provider, model, key) DO UPDATE SET value = value + excluded.value
            """, [.text(slot.day), .text(slot.provider.rawValue), .text(slot.model), .text(slot.key), .int(value)])
        }
        for (slot, value) in batch.maxima where value > 0 {
            try db.run("""
            INSERT INTO daily_stat (day, provider, model, key, value) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(day, provider, model, key) DO UPDATE SET value = max(value, excluded.value)
            """, [.text(slot.day), .text(slot.provider.rawValue), .text(slot.model), .text(slot.key), .int(value)])
        }
    }

    /// Re-reads every log already ingested by a version without activity stats, up to its saved
    /// offset, counting activity only. Runs once, in the history import's child process.
    @discardableResult
    public func backfillStats(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        guard try !hasCompletedStatsBackfill() else { return IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0) }
        try db.transaction {
            try Self.armBackfill(db, key: "stats_backfill")
            try relocateArchivedCursors()
        }
        let cursors = try db.run("""
        SELECT path, provider, CAST(meta.value AS INTEGER) FROM file_cursor
        JOIN meta ON meta.key = 'stats_backfill_limit:' || path ORDER BY path
        """).compactMap { r -> (String, LogSource, Int64)? in
            guard let path = r[0].text, let source = r[1].text.flatMap(LogSource.init(rawValue:)), (source == .codex || source == .claude) else { return nil }
            return (path, source, r[2].int)
        }
        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var failed = false
        var index = 0
        while index < cursors.count {
            let batch = cursors[index..<min(index + batchSize, cursors.count)]
            let finished = try db.transaction {
                // Another run (the CLI, a second app) may have finished and dropped the checkpoints.
                if try hasCompletedStatsBackfill() { return true }
                for (path, source, limit) in batch {
                    let checkpoint = "stats_backfill_file:" + path
                    guard try db.run("SELECT 1 FROM meta WHERE key = ?", [.text(checkpoint)]).isEmpty else { continue }
                    guard let cursor = try loadCursor(path: path), let stamp = Self.stamp(path),
                          Self.canBackfill(path: path, stamp: stamp, cursor: cursor, limit: limit)
                    else { continue }  // gone or replaced: the next ingest reads it from the start
                    let read: Int64
                    let added: Int
                    do {
                        (read, added) = try autoreleasepool {
                            switch source {
                            case .codex: try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .backfill, limit: limit)
                            case .claude: try ingestClaudeFile(path: path, stamp: stamp, cursor: cursor, mode: .backfill, limit: limit)
                            case .pi, .gemini: (0, 0) // never part of a legacy backfill
                            }
                        }
                    } catch let error as ZstdReader.Failure {
                        NSLog("Tinybar: could not decode %@: %@", path, String(describing: error))
                        failed = true
                        continue
                    }
                    // Commit the checkpoint with its counters, so a restarted backfill cannot add them twice.
                    try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(checkpoint)])
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
                return false
            }
            if finished { break }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: cursors.count))
        }
        if !failed { try markStatsBackfillDone() }
        if result.filesScanned > batchSize {
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    /// Re-reads Codex logs up to their saved offsets, filing long requests by Context Band.
    /// Runs once after upgrading to schema 6, in the history import's child process.
    @discardableResult
    public func backfillLongContext(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws -> IngestResult {
        guard try !hasCompletedLongContextBackfill() else { return IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0) }
        try db.transaction {
            try Self.armBackfill(db, key: "long_context_backfill", codexOnly: true)
            try relocateArchivedCursors()
        }
        let paths = try db.run("""
        SELECT path, CAST(meta.value AS INTEGER) FROM file_cursor
        JOIN meta ON meta.key = 'long_context_backfill_limit:' || path ORDER BY path
        """).compactMap { r -> (String, Int64)? in r[0].text.map { ($0, r[1].int) } }
        var result = IngestResult(filesScanned: 0, bytesRead: 0, recordsAdded: 0)
        let batchSize = 200
        var failed = false
        var index = 0
        while index < paths.count {
            let batch = paths[index..<min(index + batchSize, paths.count)]
            let finished = try db.transaction {
                // Another run (the CLI, a second app) may have finished and dropped the checkpoints.
                if try hasCompletedLongContextBackfill() { return true }
                for (path, limit) in batch {
                    let checkpoint = "long_context_backfill_file:" + path
                    guard try db.run("SELECT 1 FROM meta WHERE key = ?", [.text(checkpoint)]).isEmpty else { continue }
                    guard let cursor = try loadCursor(path: path), let stamp = Self.stamp(path),
                          Self.canBackfill(path: path, stamp: stamp, cursor: cursor, limit: limit)
                    else { continue }
                    let read: Int64
                    let added: Int
                    do {
                        (read, added) = try autoreleasepool {
                            try ingestCodexFile(path: path, stamp: stamp, cursor: cursor, mode: .longContext, limit: limit)
                        }
                    } catch let error as ZstdReader.Failure {
                        NSLog("Tinybar: could not decode %@: %@", path, String(describing: error))
                        failed = true
                        continue
                    }
                    try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(checkpoint)])
                    result.filesScanned += 1
                    result.bytesRead += read
                    result.recordsAdded += added
                }
                return false
            }
            if finished { break }
            index += batch.count
            progress?(IngestProgress(filesDone: index, filesTotal: paths.count))
        }
        if !failed { try markLongContextBackfillDone() }
        if result.filesScanned > batchSize {
            try? db.exec("PRAGMA shrink_memory")
            malloc_zone_pressure_relief(nil, 0)
        }
        return result
    }

    /// Freeze the pre-upgrade prefix before normal ingestion can advance any cursor.
    private static func armBackfill(_ db: SQLiteDB, key: String, codexOnly: Bool = false) throws {
        guard try db.run("SELECT 1 FROM meta WHERE key IN (?, ?) AND value = 'done'",
                         [.text(key), .text(key + "_bounds")]).isEmpty else { return }
        try db.run("""
        INSERT OR IGNORE INTO meta (key, value)
        SELECT ? || path, CAST(offset AS TEXT) FROM file_cursor
        """ + (codexOnly ? " WHERE provider = 'codex'" : " WHERE provider IN ('codex', 'claude')"), [.text(key + "_limit:")])
        try db.run("INSERT INTO meta (key, value) VALUES (?, 'done')", [.text(key + "_bounds")])
    }

    public func hasCompletedLongContextBackfill() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'long_context_backfill'").first?.first?.text == "done"
    }

    public func markLongContextBackfillDone() throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('long_context_backfill', 'done')")
            try db.exec("DELETE FROM meta WHERE key GLOB 'long_context_backfill_*'")
        }
    }

    public func hasCompletedStatsBackfill() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'stats_backfill'").first?.first?.text == "done"
    }

    public func markStatsBackfillDone() throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('stats_backfill', 'done')")
            try db.exec("DELETE FROM meta WHERE key GLOB 'stats_backfill_*'")
        }
    }

    /// How long a Claude message id is kept for de-duplication. Copies of a message in later
    /// transcripts (resumed sessions) were seen up to 29 days after it, and Claude Code deletes
    /// transcripts after 30 days by default, so 90 days leaves a wide margin. A copy older than
    /// that would be counted twice; daily totals are never touched by pruning (ADR 0003).
    public static let claudeMessageRetentionDays = 90

    /// Drops Claude message ids older than the retention window. Returns the number removed.
    @discardableResult
    public func pruneClaudeMessages(now: Date = Date()) throws -> Int {
        let cutoff = DayKey.daysAgo(Self.claudeMessageRetentionDays, from: now)
        try db.run("DELETE FROM claude_message WHERE day < ?", [.text(cutoff)])
        let removed = db.changes
        try db.run("DELETE FROM claude_event WHERE day < ?", [.text(cutoff)])
        return removed
    }

    /// Prunes at most once per day, so the 5-minute poll doesn't scan the table each time.
    private func pruneClaudeMessagesDaily(now: Date = Date()) throws {
        let today = DayKey.string(for: now)
        guard try db.run("SELECT value FROM meta WHERE key = 'claude_message_pruned'").first?.first?.text != today
        else { return }
        try pruneClaudeMessages(now: now)
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('claude_message_pruned', ?)", [.text(today)])
    }

    /// A new response's tokens, in the daily totals and, if it was long, its Context Band.
    private func addTokens(day: String, provider: ProviderID, model: String, project: String, _ t: TokenCounts) throws {
        try addDaily(day: day, provider: provider, model: model, project: project, t)
        if let band = ContextBand.of(t) {
            try addLong(day: day, provider: provider, model: model, project: project, band: band, t)
        }
    }

    private func addDaily(day: String, provider: ProviderID, model: String, project: String, _ t: TokenCounts) throws {
        try db.run("""
        INSERT INTO daily_usage (day, provider, model, project, input, output, cache_write, cache_read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day, provider, model, project) DO UPDATE SET
            input = input + excluded.input,
            output = output + excluded.output,
            cache_write = cache_write + excluded.cache_write,
            cache_read = cache_read + excluded.cache_read
        """, [.text(day), .text(provider.rawValue), .text(model), .text(project),
              .int(t.input), .int(t.output), .int(t.cacheWrite), .int(t.cacheRead)])
    }

    /// Old cursors didn't keep their timezone or resolved Project. Don't create orphan bands
    /// when replay attribution changed, or let a backfill exceed the totals actually on file.
    private func boundedBackfill(_ t: TokenCounts, key: AggKey) throws -> TokenCounts {
        let params: [SQLiteDB.Value] = [.text(key.day), .text(key.model), .text(key.project)]
        let filter = " WHERE day = ? AND provider = 'codex' AND model = ? AND project = ?"
        guard let total = try db.run("SELECT input, output, cache_write, cache_read FROM daily_usage" + filter, params).first
        else { return TokenCounts() }
        let used = try db.run("SELECT sum(input), sum(output), sum(cache_write), sum(cache_read) FROM daily_long_context" + filter, params).first!
        let values = zip([t.input, t.output, t.cacheWrite, t.cacheRead], 0..<4).map { value, i in
            min(max(0, value), max(0, total[i].int - used[i].int))
        }
        return TokenCounts(input: values[0], output: values[1], cacheWrite: values[2], cacheRead: values[3])
    }

    private func addLong(day: String, provider: ProviderID, model: String, project: String, band: Int64, _ t: TokenCounts) throws {
        try db.run("""
        INSERT INTO daily_long_context (day, provider, model, project, band, input, output, cache_write, cache_read)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(day, provider, model, project, band) DO UPDATE SET
            input = input + excluded.input,
            output = output + excluded.output,
            cache_write = cache_write + excluded.cache_write,
            cache_read = cache_read + excluded.cache_read
        """, [.text(day), .text(provider.rawValue), .text(model), .text(project), .int(band),
              .int(t.input), .int(t.output), .int(t.cacheWrite), .int(t.cacheRead)])
    }

    private func saveCursor(path: String, source: LogSource, stamp: FileStamp, offset: Int64, state: String?) throws {
        try db.run("""
        INSERT OR REPLACE INTO file_cursor (path, provider, inode, size, mtime, offset, state)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [.text(path), .text(source.rawValue), .int(stamp.inode), .int(stamp.size),
              .int(stamp.mtime), .int(offset), state.map { .text($0) } ?? .null])
    }

    // MARK: Queries

    /// Daily rows with `day >= since` (inclusive), optionally for one provider.
    public func daily(since: String, provider: ProviderID? = nil) throws -> [DailyUsage] {
        var sql = "SELECT day, provider, model, project, input, output, cache_write, cache_read FROM daily_usage WHERE day >= ?"
        var params: [SQLiteDB.Value] = [.text(since)]
        if let provider {
            sql += " AND provider = ?"
            params.append(.text(provider.rawValue))
        }
        struct Key: Hashable { var day, provider, model, project: String }
        var long: [Key: [Int64: TokenCounts]] = [:]
        for r in try db.run(sql.replacingOccurrences(of: "project, input", with: "project, band, input")
            .replacingOccurrences(of: "daily_usage", with: "daily_long_context"), params)
        {
            let key = Key(day: r[0].text ?? "", provider: r[1].text ?? "", model: r[2].text ?? "", project: r[3].text ?? "")
            long[key, default: [:]][r[4].int] = TokenCounts(input: r[5].int, output: r[6].int, cacheWrite: r[7].int, cacheRead: r[8].int)
        }
        return try db.run(sql, params).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            let key = Key(day: r[0].text ?? "", provider: r[1].text ?? "", model: r[2].text ?? "", project: r[3].text ?? "")
            return DailyUsage(
                day: key.day,
                provider: provider,
                model: key.model,
                project: key.project,
                tokens: TokenCounts(input: r[4].int, output: r[5].int, cacheWrite: r[6].int, cacheRead: r[7].int),
                long: long[key] ?? [:])
        }
    }

    /// Activity counters with `day >= since`.
    public func stats(since: String) throws -> [DailyStat] {
        try db.run("SELECT day, provider, model, key, value FROM daily_stat WHERE day >= ?", [.text(since)]).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            return DailyStat(day: r[0].text ?? "", provider: provider, model: r[2].text ?? "", key: r[3].text ?? "", value: r[4].int)
        }
    }

    /// Tokens by hour for days with `day >= since`, to split a day at a window's start.
    public func hourlyTokens(since: String) throws -> [DailyStat] {
        try db.run("""
        SELECT day, provider, model, key, value FROM daily_stat WHERE day >= ? AND key GLOB 'tokens.hour.*'
        """, [.text(since)]).compactMap { r in
            guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { return nil }
            return DailyStat(day: r[0].text ?? "", provider: provider, model: r[2].text ?? "", key: r[3].text ?? "", value: r[4].int)
        }
    }

    // MARK: Limit readings

    /// How many past windows are kept per Account and Limit Window.
    static let keptReadings = 8

    /// Keeps the highest share each weekly account-wide Limit Window of an Account reached, and when
    /// (SPEC §14). With `claiming`, a reading from before Accounts with the same Reset becomes this
    /// Account's. Those can mix Accounts, so only a Provider's only Account should claim them.
    public func recordLimitReadings(_ snapshot: ProviderSnapshot, account: String = "", claiming: Bool = true) throws {
        try db.transaction {
            for w in snapshot.windows where w.kind == .weekly && !w.isModelSpecific {
                guard let resetsAt = w.resetsAt, let duration = w.durationSeconds else { continue }
                let provider = snapshot.provider.rawValue
                let reset = Int64(resetsAt.timeIntervalSince1970)
                let used = Int64((w.usedPercent * 100).rounded())
                let read = Int64(snapshot.fetchedAt.timeIntervalSince1970)
                // A provider can restate a reset by a few seconds; that is still the same window.
                let known = try db.run("""
                SELECT resets_at, plan, used_bp, plan_changed, account FROM limit_reading
                WHERE provider = ? AND (account = ? OR (? AND account = '')) AND window = ? AND abs(resets_at - ?) < 3600
                ORDER BY account DESC, resets_at DESC LIMIT 1
                """, [.text(provider), .text(account), .int(claiming ? 1 : 0), .text(w.id), .int(reset)]).first
                guard let known else {
                    try db.run("""
                    INSERT INTO limit_reading (provider, account, window, resets_at, duration, plan, used_bp, read_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(provider), .text(account), .text(w.id), .int(reset), .int(Int64(duration)),
                          snapshot.plan.map { .text($0) } ?? .null, .int(used), .int(read)])
                    try db.run("""
                    DELETE FROM limit_reading WHERE provider = ? AND account = ? AND window = ? AND resets_at NOT IN (
                        SELECT resets_at FROM limit_reading WHERE provider = ? AND account = ? AND window = ?
                        ORDER BY resets_at DESC LIMIT ?)
                    """, [.text(provider), .text(account), .text(w.id), .text(provider), .text(account), .text(w.id), .int(Int64(Self.keptReadings))])
                    continue
                }
                let plan = snapshot.plan ?? known[1].text
                let changed = known[3].int != 0 || (known[1].text != nil && plan != known[1].text)
                let claim = known[4].text != account
                guard used > known[2].int || plan != known[1].text || changed != (known[3].int != 0) || claim else { continue }
                try db.run("""
                UPDATE OR REPLACE limit_reading SET account = ?, plan = ?, used_bp = max(used_bp, ?), plan_changed = ?,
                    read_at = CASE WHEN ? > used_bp THEN ? ELSE read_at END
                WHERE provider = ? AND account = ? AND window = ? AND resets_at = ?
                """, [.text(account), plan.map { .text($0) } ?? .null, .int(used), .int(changed ? 1 : 0), .int(used), .int(read),
                      .text(provider), .text(known[4].text ?? ""), .text(w.id), .int(known[0].int)])
            }
        }
    }

    /// One Provider's readings, newest first.
    public func limitReadings(provider: ProviderID) throws -> [LimitReading] {
        try db.run("""
        SELECT window, resets_at, duration, plan, used_bp, read_at, plan_changed, account FROM limit_reading
        WHERE provider = ? ORDER BY resets_at DESC
        """, [.text(provider.rawValue)]).map { r in
            LimitReading(
                windowID: r[0].text ?? "",
                resetsAt: Date(timeIntervalSince1970: Double(r[1].int)),
                duration: TimeInterval(r[2].int),
                plan: r[3].text,
                usedPercent: Double(r[4].int) / 100,
                readAt: Date(timeIntervalSince1970: Double(r[5].int)),
                planChanged: r[6].int != 0,
                account: r[7].text ?? "")
        }
    }

    /// Every day with any tokens, oldest first: streaks span the whole history.
    /// Days with any usage, or with usage of one model, of the Providers Stats covers.
    public func activeDays(model: String? = nil, provider: ProviderID? = nil) throws -> [String] {
        let covered = "provider IN (" + ProviderID.allCases.filter(\.hasActivity).map { "'\($0.rawValue)'" }.joined(separator: ", ") + ")"
        if let model {
            if let provider {
                return try db.run("SELECT DISTINCT day FROM daily_usage WHERE \(covered) AND model = ? AND provider = ? ORDER BY day", [.text(model), .text(provider.rawValue)])
                    .compactMap { $0.first?.text }
            }
            return try db.run("SELECT DISTINCT day FROM daily_usage WHERE \(covered) AND model = ? ORDER BY day", [.text(model)])
                .compactMap { $0.first?.text }
        }
        return try db.run("SELECT DISTINCT day FROM daily_usage WHERE \(covered) ORDER BY day").compactMap { $0.first?.text }
    }

    /// Log folders no import has read yet. A login folder or `cswap run` profile that appears can hold
    /// a whole history, so the app reads those in a child process, not during a normal ingest.
    public func unreadLogRoots(_ roots: [URL] = UsageStore.codexRoots + UsageStore.claudeRoots + UsageStore.geminiRoots.filter { FileManager.default.fileExists(atPath: $0.path) }) throws -> [URL] {
        let read = try readLogRoots()
        return roots.filter { !read.contains($0.path) }
    }

    /// `roots` are those listed before reading, so one that appears meanwhile is still imported later.
    public func markLogRootsRead(_ roots: [URL]) throws {
        let all = try readLogRoots().union(roots.map(\.path)).sorted()
        let json = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('read_log_roots', ?)", [.text(json)])
    }

    private func readLogRoots() throws -> Set<String> {
        guard let stored = try db.run("SELECT value FROM meta WHERE key = 'read_log_roots'").first?.first?.text else {
            return Set(Paths.defaultLogRoots().map(\.path))
        }
        return Set((try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? [])
    }

    public func hasCompletedInitialImport() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'initial_import'").first?.first?.text == "done"
    }

    public func markInitialImportDone() throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('initial_import', 'done')")
    }

    // MARK: Internals

    struct FileStamp: Equatable {
        var inode: Int64
        var size: Int64
        var mtime: Int64

        init(inode: Int64, size: Int64, mtime: Int64) {
            self.inode = inode
            self.size = size
            self.mtime = mtime
        }

        init(_ st: stat) {
            inode = Int64(bitPattern: UInt64(st.st_ino))
            size = Int64(st.st_size)
            mtime = Int64(st.st_mtimespec.tv_sec) * 1000 + Int64(st.st_mtimespec.tv_nsec / 1_000_000)
        }
    }

    struct Cursor {
        var stamp: FileStamp
        var offset: Int64
        var state: Data?
    }

    /// Compressed stamps measure encoded bytes, while backfill limits are decoded offsets.
    private static func canBackfill(path: String, stamp: FileStamp, cursor: Cursor, limit: Int64) -> Bool {
        guard stamp.inode == cursor.stamp.inode else { return false }
        return path.hasSuffix(".jsonl.zst") ? stamp == cursor.stamp : stamp.size >= limit
    }

    private struct AggKey: Hashable {
        var day: String
        var model: String
        var project: String
        var band: Int64 = 0

        func band(_ b: Int64) -> AggKey { AggKey(day: day, model: model, project: project, band: b) }
    }

    /// Backfill runs before normal ingestion, so find rollouts archived since the last poll.
    private func relocateArchivedCursors() throws {
        let paths = try db.run("SELECT path FROM file_cursor WHERE provider = 'codex'").compactMap { $0[0].text }
        for path in paths where Self.stamp(path) == nil {
            var root = URL(fileURLWithPath: path).deletingLastPathComponent()
            while root.path != "/", root.lastPathComponent != "sessions" { root.deleteLastPathComponent() }
            guard root.lastPathComponent == "sessions" else { continue }
            let archive = root.deletingLastPathComponent().appendingPathComponent("archived_sessions")
            let file = archive.appendingPathComponent((path as NSString).lastPathComponent).path
            for candidate in [path + ".zst", file, file + ".zst"] {
                if let stamp = Self.stamp(candidate) { _ = try codexCursor(path: candidate, stamp: stamp); break }
            }
        }
    }

    /// Archiving renames a rollout without changing its inode. Move its cursor and any frozen
    /// backfill bounds with it instead of importing the same session under a second path.
    private func codexCursor(path: String, stamp: FileStamp) throws -> Cursor? {
        if let cursor = try loadCursor(path: path) { return cursor }
        let name = (path as NSString).lastPathComponent
        let canonical = name.hasSuffix(".zst") ? String(name.dropLast(4)) : name
        func home(_ path: String) -> String? {
            let parts = path.split(separator: "/")
            guard let i = parts.lastIndex(where: { $0 == "sessions" || $0 == "archived_sessions" }) else { return nil }
            return "/" + parts[..<i].joined(separator: "/")
        }
        guard let oldPath = try db.run("SELECT path FROM file_cursor WHERE provider = 'codex'").compactMap({ $0[0].text }).first(where: {
            let oldName = ($0 as NSString).lastPathComponent
            let oldCanonical = oldName.hasSuffix(".zst") ? String(oldName.dropLast(4)) : oldName
            return oldCanonical == canonical && home($0) != nil && home($0) == home(path)
                && (Self.stamp($0) == nil || (path.hasSuffix(".zst") && !oldName.hasSuffix(".zst")))
        }), let cursor = try loadCursor(path: oldPath) else { return nil }
        try db.run("UPDATE file_cursor SET path = ? WHERE path = ?", [.text(path), .text(oldPath)])
        for prefix in ["stats_backfill_limit:", "stats_backfill_file:", "long_context_backfill_limit:", "long_context_backfill_file:"] {
            try db.run("UPDATE meta SET key = ? WHERE key = ?", [.text(prefix + path), .text(prefix + oldPath)])
        }
        return cursor
    }

    private func loadCursor(path: String) throws -> Cursor? {
        guard let r = try db.run(
            "SELECT inode, size, mtime, offset, state FROM file_cursor WHERE path = ?", [.text(path)]).first
        else { return nil }
        return Cursor(
            stamp: FileStamp(inode: r[0].int, size: r[1].int, mtime: r[2].int),
            offset: r[3].int,
            state: r[4].text.map { Data($0.utf8) })
    }

    /// Recursively visits `*.jsonl` files with one stat each, via fts(3): no Foundation
    /// objects per file, which matters with ~100k session files.
    static func walkJSONL(_ root: String, source: LogSource = .claude, _ visit: (String, FileStamp) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: root) else { return }
        let rootC = strdup(root)
        defer { free(rootC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_D, entry.pointee.fts_level > 0, String(cString: entry.pointee.fts_accpath).split(separator: "/").last?.hasPrefix(".") == true,
               !(source == .gemini && String(cString: entry.pointee.fts_accpath).split(separator: "/").last == ".system_generated") {  // skip hidden dirs
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard info == FTS_F, let st = entry.pointee.fts_statp?.pointee else { continue }
            let path = String(cString: entry.pointee.fts_path)
            guard acceptsLog(path, source: source) else { continue }
            try visit(path, FileStamp(st))
        }
    }

    static func acceptsLog(_ path: String, source: LogSource) -> Bool {
        if source == .gemini {
            let parts = path.split(separator: "/")
            return parts.count >= 5 && parts.suffix(3).elementsEqual([".system_generated", "logs", "transcript.jsonl"])
                && !parts[parts.count - 4].hasPrefix(".")
        }
        if path.split(separator: "/").contains(".system_generated") { return false }
        return path.hasSuffix(".jsonl") || (source == .codex && (path as NSString).lastPathComponent.hasPrefix("rollout-") && path.hasSuffix(".jsonl.zst"))
    }

    static func stamp(_ path: String) -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(st)
    }
}

/// Local calendar day keys (SPEC §9: day boundary).
public enum DayKey {
    public static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func daysAgo(_ n: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
        string(for: calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: now))!, calendar: calendar)
    }

    /// Today is provisional; yesterday is too until 01:00 (logs are written late).
    public static func isProvisional(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if day >= string(for: now, calendar: calendar) { return true }
        return day == daysAgo(1, from: now, calendar: calendar) && calendar.component(.hour, from: now) < 1
    }
}

public enum ModelName {
    /// Strips vendor prefixes so log names match pricing keys (e.g. "openai/gpt-6-sol" → "gpt-6-sol").
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        return s.isEmpty ? "unknown" : s
    }
}

/// Streams lines of a file from a byte offset in 256 KB chunks. Returns the offset just past the
/// last complete line, so a half-written trailing line is re-read on the next ingest.
enum JSONLReader {
    static let chunkSize = 1024 * 1024
    /// Lines longer than this are skipped (Codex embeds multi-MB tool outputs; we never need them).
    static let maxLineBytes = 1024 * 1024

    /// Calls `body` with each complete line (no newline) as a raw buffer valid only for the call.
    /// With `until`, stops at the first line that ends past that offset.
    static func forEachLine(
        url: URL, from start: Int64, until: Int64? = nil, _ body: (UnsafeRawBufferPointer) -> Void) throws -> Int64
    {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        // An offset inside a line only occurs while skipping an oversized line. Recover that
        // state from the preceding byte, without rereading its already discarded prefix.
        var skipping = false
        if start > 0 {
            guard lseek(fd, off_t(start - 1), SEEK_SET) == off_t(start - 1) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var previous: UInt8 = 0
            let n = read(fd, &previous, 1)
            guard n >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if n == 1 { skipping = previous != 0x0A }
        }
        guard lseek(fd, off_t(start), SEEK_SET) == off_t(start) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        return try readLines(fd: fd, from: start, until: until, skipping: skipping, body)
    }

    static func readLines(fd: Int32, from start: Int64, until: Int64? = nil, skipping initialSkipping: Bool = false,
                          drain: Bool = false, _ body: (UnsafeRawBufferPointer) -> Void) throws -> Int64 {
        var skipping = initialSkipping
        let capacity = chunkSize + maxLineBytes
        let buf = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { buf.deallocate() }
        var filled = 0            // valid bytes in buf
        var consumedOffset = start // file offset just past the last complete line

        var reachedLimit = false
        while !reachedLimit {
            let n = read(fd, buf + filled, capacity - filled)
            if n < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if n == 0 { break }
            filled += n
            var lineStart = 0
            while lineStart < filled,
                  let nl = memchr(buf + lineStart, 0x0A, filled - lineStart)
            {
                let end = buf.distance(to: nl)
                if let until, consumedOffset + Int64(end + 1) > until {
                    reachedLimit = true
                    break
                }
                if skipping {
                    skipping = false
                } else if end - lineStart > maxLineBytes {
                    // Skipped whether or not it happens to fit in the buffer, so a full read and an
                    // incremental one see the same lines.
                } else if end > lineStart {
                    // Parsers build Foundation objects per line; release them per line, not per file.
                    autoreleasepool { body(UnsafeRawBufferPointer(start: buf + lineStart, count: end - lineStart)) }
                }
                lineStart = end + 1
            }
            consumedOffset += Int64(lineStart)
            let rest = filled - lineStart
            if rest > maxLineBytes {
                consumedOffset += Int64(rest)
                filled = 0
                skipping = true
            } else {
                if rest > 0, lineStart > 0 { memmove(buf, buf + lineStart, rest) }
                filled = rest
            }
        }
        if drain && reachedLimit {
            while true {
                let n = read(fd, buf, capacity)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if n == 0 { break }
            }
        }
        return consumedOffset
    }
}
