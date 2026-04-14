import Foundation

@MainActor
enum MCPDetector {
    private static var cache: [String: (mtime: Date, json: [String: Any])] = [:]

    static func detect(cwd: String) -> [String] {
        var names = Set<String>()
        names.formUnion(userConfigServers(cwd: cwd))
        names.formUnion(projectFileServers(cwd: cwd))
        return names.sorted()
    }

    private static func userConfigServers(cwd: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude/settings.json"),
        ]
        var result: [String] = []
        for url in candidates {
            guard let json = loadJSON(at: url) else { continue }
            if let servers = json["mcpServers"] as? [String: Any] {
                result.append(contentsOf: servers.keys)
            }
            if let projects = json["projects"] as? [String: Any],
               let project = projects[cwd] as? [String: Any],
               let servers = project["mcpServers"] as? [String: Any] {
                result.append(contentsOf: servers.keys)
            }
        }
        return result
    }

    private static func projectFileServers(cwd: String) -> [String] {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(".mcp.json")
        guard let json = loadJSON(at: url),
              let servers = json["mcpServers"] as? [String: Any] else { return [] }
        return Array(servers.keys)
    }

    private static func loadJSON(at url: URL) -> [String: Any]? {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            cache.removeValue(forKey: path)
            return nil
        }
        if let cached = cache[path], cached.mtime == mtime {
            return cached.json
        }
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        cache[path] = (mtime, parsed)
        return parsed
    }
}
