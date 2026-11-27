import Foundation

/// A snapshot of conversation workspaces, read once for an ingest batch.
struct AgyProjectMap {
    let projects: [String: String]

    init(database: URL, resolver: ProjectResolver) {
        projects = CredentialDatabase.read(database, cloneFirst: true) { handle in
            guard let rows = SQLiteDB.rows(handle, "SELECT conversation_id, workspace_uris FROM conversation_summaries")
                ?? SQLiteDB.rows(handle, "SELECT id, workspace_uris FROM conversation_summaries") else { return [:] }
            var result: [String: String] = [:]
            for row in rows {
                guard let id = row[0].text, let json = row[1].text,
                      let uris = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { continue }
                for uri in uris {
                    guard let url = URL(string: uri), url.isFileURL,
                          url.host == nil || url.host == "" || url.host == "localhost",
                          url.path.hasPrefix("/") else { continue }
                    result[id] = resolver.project(for: url.path)
                    break
                }
            }
            return result
        } ?? [:]
    }
}
