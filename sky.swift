// sky.swift — GET /sky: the record read out loud (§2: visualization as record).
// t_c79ef288 (Sky P3): a read-only, derived-facts snapshot for the sky's
// identity + activity adapters. This file supplies FACTS only — who exists
// (roster + palette), what sessions are open (fill, generation), which
// workers are live. All painting/taste decisions live in the engine, not here.
// Sources: ~/.hermes/profiles/<p>/profile.yaml (color), skills/ (facets,
// spike), state.db (sessions, halo=record depth, tempo cadence inputs),
// kanban.db task_runs (worker electrons). Read-only opens; nothing here can
// write to the record.

import Foundation
import SQLite3

// ── tiny read-only SQLite shim ─────────────────────────────────────────────
final class SkyDB {
    private var db: OpaquePointer?
    init?(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // READONLY: the sky observes the record; it never touches it.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let d = db { sqlite3_close_v2(d) }; db = nil; return nil
        }
        sqlite3_busy_timeout(db, 150)
    }
    deinit { if let d = db { sqlite3_close_v2(d) } }
    func scalarInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW { return Int(sqlite3_column_int64(stmt, 0)) }
        return 0
    }
}

// sqlite3_column_text gives NULL for NULL cells — a safe text extractor:
private func skyColText(_ stmt: OpaquePointer?, _ c: Int32) -> String {
    guard let p = sqlite3_column_text(stmt, c) else { return "" }
    return String(cString: p)
}
extension SkyDB {
    // Column-safe variant used everywhere; rows() above kept for shape clarity.
    func q(_ sql: String) -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for c in 0..<sqlite3_column_count(stmt) { row.append(skyColText(stmt, c)) }
            out.append(row)
        }
        return out
    }
}

// ── HSL color from profile.yaml → hex (the engine's hexHue wants #rrggbb) ──
func skyHslToHex(_ h: Double, _ s: Double, _ l: Double) -> String {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch hp {
    case ..<1: (r1, g1, b1) = (c, x, 0)
    case ..<2: (r1, g1, b1) = (x, c, 0)
    case ..<3: (r1, g1, b1) = (0, c, x)
    case ..<4: (r1, g1, b1) = (0, x, c)
    case ..<5: (r1, g1, b1) = (x, 0, c)
    default:   (r1, g1, b1) = (c, 0, x)
    }
    let m = l - c / 2
    let to255 = { (v: Double) in Int(((v + m) * 255).rounded()) }
    return String(format: "#%02x%02x%02x", to255(r1), to255(g1), to255(b1))
}
func skyHashHue(_ s: String) -> Double { // same law as the plugin's hashHue
    var h = 0.0
    for ch in s.unicodeScalars { h = (h * 31 + Double(ch.value)).truncatingRemainder(dividingBy: 360) }
    return h
}
func skyProfileColor(_ yaml: String, name: String) -> String {
    // "color: hsl(254 68% 58%)" (space-separated) or legacy "hsl(254, 68%, 58%)";
    // also accept bare "#rrggbb". No color → the stable hash law (familiarity:
    // the same agent always gets the same color, §3.2).
    if let r = try? NSRegularExpression(pattern: "color:\\s*#[0-9a-fA-F]{6}"),
       let m = r.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)),
       let rr = Range(m.range, in: yaml) {
        return String(yaml[rr]).replacingOccurrences(of: "color:", with: "").trimmingCharacters(in: .whitespaces)
    }
    if let r = try? NSRegularExpression(pattern: "color:\\s*hsl\\(\\s*([0-9.]+)[\\s,]+([0-9.]+)%?[\\s,]+([0-9.]+)%?"),
       let m = r.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)), m.numberOfRanges == 4 {
        func g(_ i: Int) -> Double {
            guard let rr = Range(m.range(at: i), in: yaml) else { return 0 }
            return Double(yaml[rr]) ?? 0
        }
        return skyHslToHex(g(1), g(2) / 100, g(3) / 100)
    }
    return skyHslToHex(skyHashHue(name), 0.62, 0.58)
}

// ── edgey-domain law for spikiness (§4 dial 2) ─────────────────────────────
// Pentest-craft earns edges; a pavilion-builder is nearly a sphere. Derived
// from skill DIRECTORY NAMES only — the record, never an authored tag list.
private let skyEdgeWords = ["pentest", "security", "sherlock", "godmode", "red-team",
                            "surgery", "recon", "debug", "troubleshoot", "audit", "osint"]
private func skySpike(_ names: [String]) -> Double {
    guard !names.isEmpty else { return 0 }
    let edgey = names.filter { n in skyEdgeWords.contains { n.lowercased().contains($0) } }.count
    return round(Double(edgey) / Double(names.count) * 100) / 100
}

// ── the snapshot builder (cached: 2 s floor so N windows cannot stampede) ──
private let skyCacheLock = NSLock()
private var skyCacheAt: TimeInterval = 0
private var skyCacheBody = ""

func skySnapshot() -> String {
    skyCacheLock.lock(); defer { skyCacheLock.unlock() }
    let nowT = Date().timeIntervalSince1970
    if nowT - skyCacheAt < 2.0 && !skyCacheBody.isEmpty { return skyCacheBody }
    let now = Int(nowT)
    let home = NSHomeDirectory() + "/.hermes"
    let fm = FileManager.default
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // ── roster (§3.2 suns + §4 portraits) ──
    var roster: [String] = []
    let profDir = home + "/profiles"
    let profs = (try? fm.contentsOfDirectory(atPath: profDir))?.sorted() ?? []
    for p in profs {
        if p.hasPrefix(".") { continue } // trash dirs (.deleted) are not agents
        let pPath = profDir + "/" + p
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: pPath, isDirectory: &isDir), isDir.boolValue else { continue }
        let yaml = (try? String(contentsOfFile: pPath + "/profile.yaml", encoding: .utf8)) ?? ""
        let color = skyProfileColor(yaml, name: p)

        // facets (§4 dial 1) = skill count — the counter wears geometry.
        // Directory-leaf names, following the family-skills symlink if any.
        var skillNames: [String] = []
        if let en = fm.enumerator(atPath: pPath + "/skills") {
            for case let f as String in en where f.hasSuffix("SKILL.md") {
                skillNames.append((f as NSString).lastPathComponent == "SKILL.md"
                    ? (f as NSString).deletingLastPathComponent : f)
            }
        }
        let facets = skillNames.count
        let spike = skySpike(skillNames)

        let statePath = pPath + "/state.db"
        let sdb = SkyDB(statePath)

        // halo (§4 dial 4) = depth of record — log-scaled message depth.
        let msgs = sdb?.scalarInt("SELECT COUNT(*) FROM messages") ?? 0
        let halo = msgs > 0 ? min(1.0, log10(Double(msgs)) / 5.0) : 0.0
        let haloR = (halo * 100).rounded() / 100

        // tempo (§4 dial 3) arrives from kanban cadence (below) — worker_executions
        // carries no timestamps, so the record's only honest cadence is run starts/h.

        roster.append("{\"profile\":\"\(esc(p))\",\"color\":\"\(color)\",\"facets\":\(facets),\"spike\":\(spike),\"halo\":\(haloR)}")
    }

    // ── kanban tempo + workers (one open of kanban.db) ──
    let kdb = SkyDB(home + "/kanban.db")
    var tempoByProfile: [String: Int] = [:]
    var workers: [String] = []
    if let kdb = kdb {
        // cadence: runs started in the last 6 h (a rate; engine owns tempo taste)
        for r in kdb.q("SELECT COALESCE(profile,''), COUNT(*) FROM task_runs WHERE started_at > \(now - 21600) GROUP BY 1")
            .whereCols { $0.count >= 2 } {
            tempoByProfile[r[0]] = Int(r[1]) ?? 0
        }
        // live electrons: runs whose status is running (worker alive right now)
        for r in kdb.q("SELECT r.id, COALESCE(NULLIF(r.profile,''), t.assignee, ''), COALESCE(t.title,'') " +
                       "FROM task_runs r LEFT JOIN tasks t ON t.id = r.task_id " +
                       "WHERE r.status='running' AND r.profile IS NOT NULL OR r.status='running' AND t.assignee IS NOT NULL") {
            guard r.count >= 2, !r[1].isEmpty else { continue }
            workers.append("{\"id\":\"kbr-\(r[0])\",\"profile\":\"\(esc(r[1]))\",\"kind\":\"kanban\",\"task\":\"\(esc(String(r.count >= 3 ? r[2].prefix(60) : "")))\"}")
        }
    }
    // fold tempo into roster JSON (rebuilt string; roster is small)
    roster = roster.map { obj in
        guard let r = obj.range(of: "\"profile\":\"") else { return obj }
        let rest = obj[r.upperBound...]
        let name = String(rest.prefix { $0 != "\"" })
        let t = tempoByProfile[name] ?? 0
        return obj.dropLast() + ",\"tempo\":\(t)}"
    }

    // ── sessions (§3.3 motes: fill, compaction generation, activity) ──
    var sessions: [String] = []
    for p in profs {
        guard let sdb = SkyDB(profDir + "/" + p + "/state.db") else { continue }
        let cutoff = now - 86_400
        for r in sdb.q("SELECT s.id, COALESCE(s.message_count,0), " +
                       "COALESCE((SELECT MAX(g.generation) FROM conversation_generations g WHERE g.session_key = s.session_key),1), " +
                       "COALESCE(s.last_activity_at, s.started_at) " +
                       "FROM sessions s WHERE s.ended_at IS NULL AND COALESCE(s.last_activity_at, s.started_at) > \(cutoff) " +
                       "ORDER BY 4 DESC LIMIT 12") {
            guard r.count >= 4, !r[0].isEmpty else { continue }
            let mc = Int(r[1]) ?? 0
            let fill = min(1.0, Double(mc) / 200.0)
            let act = (Double(r[3]) ?? 0).rounded()
            let active = (nowT - act) < 120
            // local subagent electrons (delegate_task children etc.)
            sessions.append("{\"id\":\"\(esc(r[0]))\",\"profile\":\"\(esc(p))\",\"fill\":\(String(format: "%.2f", fill)),\"gen\":\(r[2]),\"active\":\(active ? "true" : "false")}")
        }
        for r in sdb.q("SELECT w.execution_id FROM worker_executions w WHERE w.status='running'") {
            workers.append("{\"id\":\"wkx-\(esc(r[0]))\",\"profile\":\"\(esc(p))\",\"kind\":\"worker\"}")
        }
    }

    let body = "{\"t\":\(now),\"build\":\"\(esc(SIDECAR_BUILD))\"," +
        "\"roster\":[" + roster.joined(separator: ",") + "]," +
        "\"sessions\":[" + sessions.joined(separator: ",") + "]," +
        "\"workers\":[" + workers.joined(separator: ",") + "]}"
    skyCacheAt = nowT; skyCacheBody = body
    return body
}

// helper so malformed rows never crash the roster loop
private extension Array where Element == [String] {
    func whereCols(_ pred: ([String]) -> Bool) -> [[String]] { filter(pred) }
}
