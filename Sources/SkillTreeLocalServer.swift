import Foundation
import Darwin

// HTTP server cục bộ (Swift, không dependency) thay thế server.py của repo skilltree:
// - Phục vụ index.html từ bundle app.
// - API JSON giống hệt server.py: /api/data, /api/up, /api/down, ... (POST cần header X-Panel-Client: 1).
// - Dữ liệu lưu SQLite tại Library/Application Support/skilltree.db.
//
// server.py dùng Python stdlib; ở đây tái hiện đúng schema + luật (điểm, mở khóa cha-con,
// hoàn điểm khi xóa node...) để UI index.html chạy không cần sửa.
final class SkillTreeLocalServer {
    private var listener: POSIXHTTPListener?
    private(set) var rootURL = URL(string: "http://127.0.0.1:0")!

    func start() throws {
        guard listener == nil else { return }
        let listener = try POSIXHTTPListener(port: 0) // port ngẫu nhiên còn trống
        self.listener = listener
        rootURL = URL(string: "http://127.0.0.1:\(listener.port)")!
        let html = try SkillTreeLocalServer.loadHTML()
        // Thread giữ listener bằng strong capture; mỗi connection xử lý trên queue riêng
        let thread = Thread {
            while listener.acceptAndDispatch(handlerMaker: { SkillTreeRequestHandler(db: SkillTreeDatabase(), html: html) }) { }
        }
        thread.name = "SkillTreeLocalServer"
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop() {
        listener?.closeListener()
        listener = nil
    }

    private static func loadHTML() throws -> Data {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Thiếu index.html trong bundle"])
        }
        return try Data(contentsOf: url)
    }
}

// MARK: - SQLite database (giống schema + seed của server.py)

import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SkillTreeDatabase {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "skilltree.db")

    static let defaultCats: [(String, String)] = [
        ("Business", "#3ddc84"), ("Finance", "#3b82ff"), ("Travel", "#ff8a3c"),
        ("Design", "#a63cff"), ("Startup", "#27d3ff"),
    ]
    static let defaultNodes: [(String, String, String, Double, Double, String, Int, String, String)] = [
        ("a", "Nền tảng", "◈", 380, 60, "Startup", 3, "", "Kỹ năng gốc, mở khóa mọi nhánh."),
        ("b", "Lãnh đạo", "♛", 130, 250, "Business", 5, "a", "Điều phối đội nhóm và ra quyết định."),
        ("c", "Chiến lược", "◉", 380, 250, "Business", 5, "a", "Lập kế hoạch dài hạn và đặt mục tiêu."),
        ("d", "Phân nhánh", "⑂", 520, 150, "Design", 3, "c", "Tách quy trình thành các hướng song song."),
        ("e", "Thiết kế", "✎", 660, 150, "Design", 5, "d", "Tạo giao diện và trải nghiệm người dùng."),
        ("f", "Phân tích", "◎", 520, 250, "Finance", 5, "c", "Đọc dữ liệu và rút ra nhận định."),
        ("g", "Đầu tư", "★", 690, 250, "Finance", 5, "f", "Quản lý vốn và tối ưu lợi nhuận."),
        ("h", "Tăng trưởng", "↗", 450, 400, "Startup", 4, "c", "Mở rộng quy mô sản phẩm và thị trường."),
        ("k", "Giá trị", "◇", 610, 400, "Travel", 3, "f", "Xây dựng đề xuất giá trị khác biệt."),
        ("m", "Mạng lưới", "⊸", 380, 530, "Travel", 3, "h", "Kết nối đối tác và cộng đồng."),
    ]
    static let basePoints = 12

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let path = support.appendingPathComponent("skilltree.db").path
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        bootstrapIfNeeded()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func bootstrapIfNeeded() {
        queue.sync {
            exec("""
            CREATE TABLE IF NOT EXISTS cats(name TEXT PRIMARY KEY, color TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS nodes(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT NOT NULL DEFAULT '◆',
              x REAL NOT NULL DEFAULT 380, y REAL NOT NULL DEFAULT 300,
              cat TEXT NOT NULL DEFAULT '', max_lv INTEGER NOT NULL DEFAULT 3,
              parent TEXT NOT NULL DEFAULT '', desc TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS state(node_id TEXT PRIMARY KEY, lv INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            // Đọc meta trực tiếp trong block (meta() có queue.sync riêng → gọi tại đây sẽ deadlock)
            let seeded = query("SELECT value FROM meta WHERE key='seeded'").first?["value"] as? String
            guard seeded != "1" else { return }
            for (name, color) in Self.defaultCats {
                exec("INSERT OR IGNORE INTO cats(name,color) VALUES(?,?)", [name, color])
            }
            for (id, name, icon, x, y, cat, maxLv, parent, desc) in Self.defaultNodes {
                exec("INSERT OR IGNORE INTO nodes(id,name,icon,x,y,cat,max_lv,parent,desc) VALUES(?,?,?,?,?,?,?,?,?)",
                     [id, name, icon, x, y, cat, maxLv, parent, desc])
            }
            exec("INSERT OR REPLACE INTO state(node_id,lv) VALUES('a',1)")
            exec("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["pts", String(Self.basePoints)])
            exec("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["base_points", String(Self.basePoints)])
            exec("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", ["seeded", "1"])
        }
    }

    // MARK: primitives

    private func exec(_ sql: String, _ params: [Any] = []) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(params, to: stmt)
        _ = sqlite3_step(stmt)
    }

    private func query(_ sql: String, _ params: [Any] = []) -> [[String: Any]] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bind(params, to: stmt)
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row[name] = Double(sqlite3_column_double(stmt, i))
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func bind(_ params: [Any], to stmt: OpaquePointer?) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let s as String:
                sqlite3_bind_text(stmt, idx, s, -1, sqliteTransient)
            case let n as Int:
                sqlite3_bind_int64(stmt, idx, sqlite3_int64(n))
            case let d as Double:
                sqlite3_bind_double(stmt, idx, d)
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            case let f as Float:
                sqlite3_bind_double(stmt, idx, Double(f))
            case let b as Bool:
                sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            default:
                sqlite3_bind_text(stmt, idx, "\(p)", -1, sqliteTransient)
            }
        }
    }

    // MARK: domain helpers (bản dịch từ server.py)

    private func meta(_ k: String) -> String? {
        queue.sync {
            query("SELECT value FROM meta WHERE key=?", [k]).first?["value"] as? String
        }
    }

    private func setMeta(_ k: String, _ v: Any) {
        exec("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", [k, "\(v)"])
    }

    private func points() -> Int {
        Int(meta("pts") ?? "0") ?? 0
    }

    private func level(_ nid: String) -> Int {
        query("SELECT lv FROM state WHERE node_id=?", [nid]).first?["lv"] as? Int ?? 0
    }

    private func setLevel(_ nid: String, _ lv: Int) {
        exec("INSERT INTO state(node_id,lv) VALUES(?,?) ON CONFLICT(node_id) DO UPDATE SET lv=excluded.lv", [nid, lv])
    }

    private func node(_ nid: String) -> [String: Any]? {
        queue.sync { query("SELECT * FROM nodes WHERE id=?", [nid]).first }
    }

    private func allNodes() -> [[String: Any]] {
        queue.sync { query("SELECT * FROM nodes ORDER BY id") }
    }

    private func descendants(root: String) -> Set<String> {
        var out = Set<String>()
        var frontier = [root]
        let nodes = allNodes()
        while let cur = frontier.popLast() {
            for n in nodes {
                let nid = n["id"] as? String ?? ""
                if (n["parent"] as? String) == cur && !out.contains(nid) {
                    out.insert(nid)
                    frontier.append(nid)
                }
            }
        }
        return out
    }

    func dump() -> [String: Any] {
        queue.sync {
            var cats: [String: String] = [:]
            for r in query("SELECT * FROM cats ORDER BY name") {
                cats[r["name"] as? String ?? ""] = r["color"] as? String ?? "#3b82ff"
            }
            let nodes = query("SELECT * FROM nodes ORDER BY id").map { r -> [String: Any] in
                [
                    "id": r["id"] ?? "", "name": r["name"] ?? "", "icon": r["icon"] ?? "◆",
                    "x": r["x"] ?? 380.0, "y": r["y"] ?? 300.0, "cat": r["cat"] ?? "",
                    "max_lv": r["max_lv"] ?? 3, "parent": r["parent"] ?? "", "desc": r["desc"] ?? "",
                ]
            }
            var state: [String: Int] = [:]
            for r in query("SELECT * FROM state") {
                state[r["node_id"] as? String ?? ""] = r["lv"] as? Int ?? 0
            }
            return [
                "cats": cats, "nodes": nodes, "state": state,
                "pts": points(),
                "base_points": Int(meta("base_points") ?? "\(Self.basePoints)") ?? Self.basePoints,
            ]
        }
    }

    // MARK: API (trả [String: Any] hoặc throw ApiError như server.py)

    struct ApiError: Error {
        let code: Int
        let message: String

        init(_ code: Int, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    func apiUp(_ b: [String: Any]) throws -> [String: Any] {
        let nid = b["id"] as? String ?? ""
        guard let n = node(nid) else { throw ApiError(404, "Không có node này") }
        let lv = level(nid), pts = points()
        guard pts > 0 else { throw ApiError(400, "Hết điểm khả dụng") }
        let parent = n["parent"] as? String ?? ""
        if !parent.isEmpty {
            guard level(parent) > 0 else { throw ApiError(400, "Node cha chưa mở khóa") }
        }
        guard lv < (n["max_lv"] as? Int ?? 3) else { throw ApiError(400, "Node đã đạt cấp tối đa") }
        setLevel(nid, lv + 1)
        setMeta("pts", pts - 1)
        return dump()
    }

    func apiDown(_ b: [String: Any]) throws -> [String: Any] {
        let nid = b["id"] as? String ?? ""
        guard let n = node(nid) else { throw ApiError(404, "Không có node này") }
        let lv = level(nid)
        guard lv > 0 else { throw ApiError(400, "Node chưa mở khóa") }
        if lv == 1 {
            guard !(n["parent"] as? String ?? "").isEmpty else {
                throw ApiError(400, "Node gốc luôn giữ mức 1")
            }
            let hasOpenKid = !queue.sync {
                query("""
                SELECT 1 FROM state s JOIN nodes n ON n.id=s.node_id
                WHERE n.parent=? AND s.lv>0 LIMIT 1
                """, [nid])
            }.isEmpty
            guard !hasOpenKid else { throw ApiError(400, "Đang có node con mở — hoàn node con trước") }
        }
        if lv == 1 {
            exec("DELETE FROM state WHERE node_id=?", [nid])  // không để row lv=0 (giống server.py)
        } else {
            setLevel(nid, lv - 1)
        }
        setMeta("pts", points() + 1)
        return dump()
    }

    func apiReset() -> [String: Any] {
        exec("DELETE FROM state")
        let roots = queue.sync { query("SELECT id FROM nodes WHERE parent=''").compactMap { $0["id"] as? String } }
        for nid in roots {
            setLevel(nid, 1)
        }
        setMeta("pts", meta("base_points") ?? String(Self.basePoints))
        return dump()
    }

    func apiPoints(_ b: [String: Any]) throws -> [String: Any] {
        let delta = try clampInt(b["delta"] ?? 5, -1000, 1000, "Số không hợp lệ")
        setMeta("pts", max(0, min(99999, points() + delta)))
        return dump()
    }

    func apiNodeAdd(_ b: [String: Any]) throws -> [String: Any] {
        let cats = Set(queue.sync { query("SELECT name FROM cats").compactMap { $0["name"] as? String } })
        var byid: [String: [String: Any]] = [:]
        for n in allNodes() { byid[n["id"] as? String ?? ""] = n }
        let parent = b["parent"] as? String ?? ""
        if !parent.isEmpty {
            guard byid[parent] != nil else { throw ApiError(400, "Node cha không tồn tại") }
        }
        let f = try cleanNode(b, cats: cats, byid: byid, selfId: nil)
        var nid = (b["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if nid.isEmpty || nid.count > 16 {
            nid = "n" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 16)
        }
        while node(nid) != nil {
            nid = "n" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 16)
        }
        exec("INSERT INTO nodes(id,name,icon,x,y,cat,max_lv,parent,desc) VALUES(?,?,?,?,?,?,?,?,?)",
             [nid, f["name"] ?? "", f["icon"] ?? "◆", f["x"] ?? 380.0, f["y"] ?? 300.0,
              f["cat"] ?? "", f["max_lv"] ?? 3, f["parent"] ?? "", f["desc"] ?? ""])
        var out = dump()
        out["new_id"] = nid
        return out
    }

    func apiNodeUpdate(_ b: [String: Any]) throws -> [String: Any] {
        let nid = b["id"] as? String ?? ""
        guard node(nid) != nil else { throw ApiError(404, "Không có node này") }
        let cats = Set(queue.sync { query("SELECT name FROM cats").compactMap { $0["name"] as? String } })
        var byid: [String: [String: Any]] = [:]
        for n in allNodes() { byid[n["id"] as? String ?? ""] = n }
        let f = try cleanNode(b, cats: cats, byid: byid, selfId: nid)
        exec("UPDATE nodes SET name=?,icon=?,x=?,y=?,cat=?,max_lv=?,parent=?,desc=? WHERE id=?",
             [f["name"] ?? "", f["icon"] ?? "◆", f["x"] ?? 380.0, f["y"] ?? 300.0,
              f["cat"] ?? "", f["max_lv"] ?? 3, f["parent"] ?? "", f["desc"] ?? "", nid])
        return dump()
    }

    func apiNodeDelete(_ b: [String: Any]) throws -> [String: Any] {
        let nid = b["id"] as? String ?? ""
        guard node(nid) != nil else { throw ApiError(404, "Không có node này") }
        guard queue.sync { query("SELECT 1 FROM nodes WHERE parent=? LIMIT 1", [nid]) }.isEmpty else {
            throw ApiError(400, "Còn node con — xóa node con trước")
        }
        let lv = level(nid)
        if lv > 0 { setMeta("pts", points() + lv) }
        exec("DELETE FROM state WHERE node_id=?", [nid])
        exec("DELETE FROM nodes WHERE id=?", [nid])
        return dump()
    }

    func apiMove(_ b: [String: Any]) throws -> [String: Any] {
        let nid = b["id"] as? String ?? ""
        guard node(nid) != nil else { throw ApiError(404, "Không có node này") }
        let x = try clampDouble(b["x"], 40, 720, "Số không hợp lệ")
        let y = try clampDouble(b["y"], 40, 550, "Số không hợp lệ")
        exec("UPDATE nodes SET x=?,y=? WHERE id=?", [x, y, nid])
        return dump()
    }

    func apiCatAdd(_ b: [String: Any]) throws -> [String: Any] {
        let name = (b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard name.count <= 24, !name.isEmpty else { throw ApiError(400, "Thiếu tên danh mục") }
        guard queue.sync { query("SELECT 1 FROM cats WHERE name=?", [name]) }.isEmpty else {
            throw ApiError(400, "Danh mục đã tồn tại")
        }
        var color = b["color"] as? String ?? "#3b82ff"
        if Self.colorRE.firstMatch(in: color, range: NSRange(color.startIndex..., in: color)) == nil {
            color = "#3b82ff"
        }
        exec("INSERT INTO cats(name,color) VALUES(?,?)", [name, color])
        return dump()
    }

    func apiCatUpdate(_ b: [String: Any]) throws -> [String: Any] {
        let name = b["name"] as? String ?? ""
        guard queue.sync { query("SELECT 1 FROM cats WHERE name=?", [name]) }.first != nil else {
            throw ApiError(404, "Không có danh mục này")
        }
        let color = b["color"] as? String ?? ""
        guard Self.colorRE.firstMatch(in: color, range: NSRange(color.startIndex..., in: color)) != nil else {
            throw ApiError(400, "Màu phải dạng #rrggbb")
        }
        exec("UPDATE cats SET color=? WHERE name=?", [color, name])
        return dump()
    }

    func apiCatDelete(_ b: [String: Any]) throws -> [String: Any] {
        let name = b["name"] as? String ?? ""
        guard queue.sync { query("SELECT 1 FROM cats WHERE name=?", [name]) }.first != nil else {
            throw ApiError(404, "Không có danh mục này")
        }
        let nCats = Int(queue.sync { query("SELECT COUNT(*) c FROM cats").first?["c"] as? Int ?? 0 })
        guard nCats > 1 else { throw ApiError(400, "Phải còn ít nhất một danh mục") }
        guard queue.sync { query("SELECT 1 FROM nodes WHERE cat=? LIMIT 1", [name]) }.isEmpty else {
            throw ApiError(400, "Danh mục đang có node — dời node sang danh mục khác trước")
        }
        exec("DELETE FROM cats WHERE name=?", [name])
        return dump()
    }

    func apiImport(_ b: [String: Any]) throws -> [String: Any] {
        var catsIn: [(String, String)] = []
        if let dict = b["cats"] as? [String: Any] {
            catsIn = dict.map { ($0.key, "\($0.value)") }
        } else if let arr = b["cats"] as? [[Any]] {
            for it in arr {
                guard it.count >= 2 else { throw ApiError(400, "Danh mục sai định dạng") }
                catsIn.append(("\((it[0] as? String ?? "").description)", "\((it[1] as? String ?? "#3b82ff"))"))
            }
        }
        guard !catsIn.isEmpty else { throw ApiError(400, "Thiếu danh mục (cats)") }
        var cats: [String: String] = [:]
        for (name0, color0) in catsIn {
            let name = String(name0.trimmingCharacters(in: .whitespaces).prefix(24))
            guard !name.isEmpty else { throw ApiError(400, "Tên danh mục rỗng") }
            cats[name] = Self.colorRE.firstMatch(in: color0, range: NSRange(color0.startIndex..., in: color0)) != nil
                ? color0 : "#3b82ff"
        }
        guard let nodesIn = b["nodes"] as? [[String: Any]] else { throw ApiError(400, "Thiếu nodes") }
        let ids = Set(nodesIn.compactMap { ($0["id"] as? String)?.trimmingCharacters(in: .whitespaces) })
        guard ids.count == nodesIn.count else { throw ApiError(400, "Trùng node id") }
        var nodes: [[String: Any]] = []
        var byid: [String: [String: Any]] = [:]
        for n in nodesIn {
            var f = try cleanNode(n, cats: Set(cats.keys), byid: byid, selfId: nil)
            f["id"] = (n["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            f["parent"] = n["parent"] as? String ?? ""
            if let p = f["parent"] as? String, !p.isEmpty, !ids.contains(p) { f["parent"] = "" }
            nodes.append(f)
            byid[f["id"] as? String ?? ""] = f
        }
        for f in nodes {
            var cur = f, steps = 0
            while let p = cur["parent"] as? String, !p.isEmpty {
                guard let next = byid[p] else { break }
                cur = next
                steps += 1
                guard steps <= nodes.count else {
                    throw ApiError(400, "Cây bị vòng lặp parent (node \(f["id"] as? String ?? ""))")
                }
            }
        }
        var state: [String: Int] = [:]
        if let stateIn = b["state"] as? [String: Any] {
            for (nid, lvAny) in stateIn {
                guard byid[nid] != nil else { continue }
                let maxLv = byid[nid]?["max_lv"] as? Int ?? 3
                let lv: Int
                if let i = lvAny as? Int {
                    lv = i
                } else if let s = lvAny as? String, let i = Int(s) {
                    lv = i
                } else if let d = lvAny as? Double {
                    lv = Int(d)
                } else {
                    continue
                }
                if lv >= 0 { state[nid] = min(maxLv, lv) }
            }
        }
        let pts = try clampInt(b["pts"] ?? 0, 0, 99999, "Số không hợp lệ")
        let base = try clampInt(b["base_points"] ?? Self.basePoints, 0, 99999, "Số không hợp lệ")
        exec("DELETE FROM state")
        exec("DELETE FROM nodes")
        exec("DELETE FROM cats")
        for (name, color) in cats {
            exec("INSERT INTO cats(name,color) VALUES(?,?)", [name, color])
        }
        for f in nodes {
            exec("INSERT INTO nodes(id,name,icon,x,y,cat,max_lv,parent,desc) VALUES(?,?,?,?,?,?,?,?,?)",
                 [f["id"] ?? "", f["name"] ?? "", f["icon"] ?? "◆", f["x"] ?? 380.0, f["y"] ?? 300.0,
                  f["cat"] ?? "", f["max_lv"] ?? 3, f["parent"] ?? "", f["desc"] ?? ""])
        }
        for (nid, lv) in state {
            exec("INSERT OR REPLACE INTO state(node_id,lv) VALUES(?,?)", [nid, lv])
        }
        setMeta("pts", pts)
        setMeta("base_points", base)
        return dump()
    }

    // MARK: validation helpers (tương ứng clean_node của server.py)

    private static let colorRE = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")

    private func clampInt(_ v: Any?, _ lo: Int, _ hi: Int, _ msg: String) throws -> Int {
        if let i = v as? Int { return max(lo, min(hi, i)) }
        if let d = v as? Double { return max(lo, min(hi, Int(d))) }
        if let s = v as? String, let i = Int(s) { return max(lo, min(hi, i)) }
        throw ApiError(400, msg)
    }

    private func clampDouble(_ v: Any?, _ lo: Double, _ hi: Double, _ msg: String) throws -> Double {
        if let d = v as? Double { return max(lo, min(hi, d)) }
        if let i = v as? Int { return max(lo, min(hi, Double(i))) }
        if let s = v as? String, let d = Double(s) { return max(lo, min(hi, d)) }
        throw ApiError(400, msg)
    }

    private func cleanNode(
        _ d: [String: Any], cats: Set<String>, byid: [String: [String: Any]], selfId: String?
    ) throws -> [String: Any] {
        let name0 = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let name = name0.isEmpty ? "Node mới" : String(name0.prefix(60))
        let icon0 = (d["icon"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let icon = icon0.isEmpty ? "◆" : String(icon0.prefix(4))
        let desc0 = (d["desc"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let desc = String(desc0.prefix(300))
        let cat = d["cat"] as? String ?? ""
        guard cats.contains(cat) else { throw ApiError(400, "Danh mục không tồn tại: \(cat)") }
        let maxLv = try clampInt(d["max_lv"] ?? 3, 1, 10, "Số không hợp lệ")
        let x = try clampDouble(d["x"] ?? 380, 40, 720, "Số không hợp lệ")
        let y = try clampDouble(d["y"] ?? 300, 40, 550, "Số không hợp lệ")
        let parent = d["parent"] as? String ?? ""
        if !parent.isEmpty {
            guard byid[parent] != nil else { throw ApiError(400, "Node cha không tồn tại") }
            if let selfId {
                guard parent != selfId else { throw ApiError(400, "Node không thể là cha của chính nó") }
                guard !descendants(root: selfId).contains(parent) else {
                    throw ApiError(400, "Node cha không được là node con của nó")
                }
            }
        }
        return ["name": name, "icon": icon, "desc": desc, "cat": cat,
                "max_lv": maxLv, "x": x, "y": y, "parent": parent]
    }
}

// MARK: - POSIX HTTP listener (stdlib-only: socket + accept, mỗi connection chạy tuần tự trên worker)

final class POSIXHTTPListener {
    private var serverFD: Int32 = -1
    private(set) var port: Int

    init(port: Int) throws {
        self.port = port
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian) // chỉ lắng nghe localhost

        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        serverFD = fd
        if port == 0 {
            var boundAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &boundAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = getsockname(fd, sa, &len)
                }
            }
            self.port = Int(UInt16(bigEndian: boundAddr.sin_port))
        }
    }

    func closeListener() {
        if serverFD >= 0 {
            // shutdown trước để accept() đang block thoát ngay
            shutdown(serverFD, Int32(SHUT_RDWR))
            close(serverFD)
            serverFD = -1
        }
    }

    /// Blocking accept — gọi trong thread riêng. Trả false khi listener đóng.
    func acceptAndDispatch(handlerMaker: @escaping () -> SkillTreeRequestHandler) -> Bool {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(serverFD, sa, &len)
            }
        }
        guard clientFD >= 0 else { return false }
        let handler = handlerMaker()
        let queue = DispatchQueue(label: "skilltree.conn")
        queue.async {
            handler.handle(fd: clientFD)
            close(clientFD)
        }
        return true
    }
}

// MARK: - HTTP request handler (giống Handler của server.py)

final class SkillTreeRequestHandler {
    private let db: SkillTreeDatabase
    private let html: Data

    init(db: SkillTreeDatabase, html: Data) {
        self.db = db
        self.html = html
    }

    func handle(fd: Int32) {
        guard let request = readRequest(fd: fd) else { return }
        let response: Data
        switch request.method {
        case "GET":
            response = handleGet(request)
        case "POST":
            response = handlePost(request)
        default:
            response = jsonResponse(404, ["error": "Không tìm thấy"])
        }
        fd.writeAll(response)
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func readRequest(fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { chunk.deallocate() }
        // Đọc đến khi hết header (\r\n\r\n)
        let headerDelimiter = Data("\r\n\r\n".utf8)
        while buffer.range(of: headerDelimiter) == nil && buffer.count < 1 << 20 {
            let n = read(fd, chunk, 65536)
            guard n > 0 else { break }
            buffer.append(chunk, count: n)
        }
        guard let headerEnd = buffer.range(of: headerDelimiter) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= 2 * 1024 * 1024 else { return nil }
        let bodyStart = headerEnd.upperBound
        var body = buffer.count > bodyStart ? buffer.subdata(in: bodyStart..<buffer.endIndex) : Data()
        while body.count < contentLength {
            let n = read(fd, chunk, 65536)
            guard n > 0 else { break }
            body.append(chunk, count: n)
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }
        return HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: body
        )
    }

    private func handleGet(_ req: HTTPRequest) -> Data {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        if path == "/" || path == "/index.html" {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nCache-Control: no-store\r\n\r\n"
            return Data(head.utf8) + html
        } else if path == "/api/data" {
            return jsonResponse(200, db.dump())
        } else if path == "/favicon.ico" {
            return Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
        }
        return jsonResponse(404, ["error": "Không tìm thấy"])
    }

    private func handlePost(_ req: HTTPRequest) -> Data {
        guard req.headers["x-panel-client"] == "1" else {
            return jsonResponse(403, ["error": "Thiếu header X-Panel-Client"])
        }
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        var body: [String: Any] = [:]
        if !req.body.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: req.body),
                  let dict = parsed as? [String: Any] else {
                return jsonResponse(400, ["error": "JSON sai định dạng"])
            }
            body = dict
        }
        do {
            let result: [String: Any]
            switch path {
            case "/api/up": result = try db.apiUp(body)
            case "/api/down": result = try db.apiDown(body)
            case "/api/reset": result = db.apiReset()
            case "/api/points": result = try db.apiPoints(body)
            case "/api/node/add": result = try db.apiNodeAdd(body)
            case "/api/node/update": result = try db.apiNodeUpdate(body)
            case "/api/node/delete": result = try db.apiNodeDelete(body)
            case "/api/move": result = try db.apiMove(body)
            case "/api/cat/add": result = try db.apiCatAdd(body)
            case "/api/cat/update": result = try db.apiCatUpdate(body)
            case "/api/cat/delete": result = try db.apiCatDelete(body)
            case "/api/import": result = try db.apiImport(body)
            default:
                return jsonResponse(404, ["error": "Không tìm thấy API"])
            }
            return jsonResponse(200, result)
        } catch let e as SkillTreeDatabase.ApiError {
            return jsonResponse(e.code, ["error": e.message])
        } catch {
            return jsonResponse(500, ["error": "Lỗi máy chủ: \(error)"])
        }
    }

    private func jsonResponse(_ code: Int, _ obj: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(code) \(reasonPhrase(code))\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + data
    }

    private func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return ""
        }
    }
}

extension Int32 {
    func writeAll(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = data.count
            while remaining > 0 {
                let n = Darwin.write(self, pointer, remaining)
                guard n > 0 else { break }
                pointer += n
                remaining -= n
            }
        }
    }
}
