import Foundation
import AppKit
import SQLite3
import os

// MARK: - 库扫描结果

/// 一个工程（.fcpbundle 里 `R1`、`R2` 这种子目录）
struct FCPBundleProject: Identifiable {
    /// 事件目录 + 工程目录，库内唯一
    var id: String { "\(eventRelativePath)/\(relativePath)" }
    let eventRelativePath: String
    let relativePath: String
    var name: String
    var references: FCPProjectReferences
    /// 解析失败、字段缺失时的说明。非空表示这个工程的内容不完整，不能拿它判断「未使用」
    var warning: String?
}

/// 一个事件（库根下的 `01V1`、`02V2` 这种目录）
struct FCPBundleEvent: Identifiable {
    var id: String { relativePath }
    let relativePath: String
    var name: String
    var projects: [FCPBundleProject]
    /// 事件级数据库里的效果引用（旧格式工程会存在这里）
    var references: FCPProjectReferences
    var warning: String?
}

/// 整个 .fcpbundle 的只读扫描结果
struct FCPBundleScanResult {
    let libraryURL: URL
    let libraryName: String
    let libraryVersion: String?
    let isLocked: Bool
    /// 「库正在 FCP 中使用」「.lock 可能是残留」这类提示，不参与能否停用的判断
    var notice: String?
    var events: [FCPBundleEvent]

    /// 勾了「整库」时忽略这个集合
    var wholeLibrary: Bool = true
    /// 未勾「整库」时，用户选中的工程 id
    var selectedProjectIDs: Set<String> = []
    /// Effects.map 里登记的、库级的效果资源（整库统计时并入）
    var libraryExtraReferences = FCPProjectReferences()

    var allProjects: [FCPBundleProject] { events.flatMap(\.projects) }
    var projectCount: Int { allProjects.count }

    /// 当前选择下要保护的效果引用
    func references(wholeLibrary: Bool, selected: Set<String>) -> FCPProjectReferences {
        var refs = FCPProjectReferences()
        if wholeLibrary {
            for event in events {
                refs.formUnion(event.references)
                for project in event.projects {
                    refs.formUnion(project.references)
                }
            }
            refs.formUnion(libraryExtraReferences)
        } else {
            for event in events {
                let chosen = event.projects.filter { selected.contains($0.id) }
                guard !chosen.isEmpty else { continue }
                // 事件级引用属于这个事件里的所有工程，选中任意一个都要保护
                refs.formUnion(event.references)
                for project in chosen {
                    refs.formUnion(project.references)
                }
            }
        }
        return refs
    }

    /// 选中范围里是否有读不完整的工程（或事件级数据读不出来）
    func hasUnreadableSelection(wholeLibrary: Bool, selected: Set<String>) -> Bool {
        let chosenEvents = wholeLibrary
            ? events
            : events.filter { event in event.projects.contains { selected.contains($0.id) } }
        if chosenEvents.contains(where: { $0.warning != nil }) { return true }
        return chosenEvents.flatMap(\.projects).contains { $0.warning != nil }
    }

    var selectionLabel: String {
        if wholeLibrary {
            return T("整库「%@」", libraryName)
        }
        if selectedProjectIDs.count == 1,
           let project = allProjects.first(where: { selectedProjectIDs.contains($0.id) }) {
            return T("工程「%@」", project.name)
        }
        return T("选中的 %@ 个工程", selectedProjectIDs.count)
    }
}

// MARK: - 错误

enum FCPBundleError: LocalizedError {
    /// 不是 FCP 库（没有 CurrentVersion.flexolibrary）
    case notLibrary
    /// 版本读不懂
    case unsupportedVersion(String)
    /// 某个步骤读不出来，detail 里说明卡在哪
    case unreadable(String)
    /// 库结构能打开，但没有任何事件/工程
    case noEvents

    var errorDescription: String? {
        let detail: String
        switch self {
        case .notLibrary:
            detail = T("找不到 CurrentVersion.flexolibrary，这可能不是 Final Cut Pro 资源库")
        case .unsupportedVersion(let value):
            detail = T("资源库版本 %@ 不在支持范围", value)
        case .unreadable(let value):
            detail = value
        case .noEvents:
            detail = T("没有找到任何事件或工程")
        }
        return T("这个库的格式本工具还读不懂（%@）。请在 Final Cut Pro 里打开该库，用「文件 → 导出 XML」导出 .fcpxml，再拖进来扫描。", detail)
    }
}

// MARK: - 只读库读取

/// 直接读 .fcpbundle。
///
/// 安全纪律：
/// 1. 只对原库做「读取目录 / 复制文件」，绝不写入、不加锁、不改时间戳；
/// 2. 先复制到临时目录，再解析副本；
/// 3. 无论成功失败，临时副本都会删除。
enum FCPBundleReader {
    private static let logger = Logger(subsystem: "FCPXPluginManager", category: "bundle")

    private static let skippedDirectoryNames: Set<String> = [
        "render files", "original media", "shared items", "proxy media",
        "transcoded media", "analysis files", "motion templates.localized"
    ]

    static func isLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("CurrentVersion.flexolibrary").path
        )
    }

    static func scan(url: URL) throws -> FCPBundleScanResult {
        guard isLibrary(url) else { throw FCPBundleError.notLibrary }

        let lockState = readLockState(in: url)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FCPPluginManager-Bundle-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
            logger.debug("临时副本已清理：\(temp.path, privacy: .public)")
        }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        logger.debug("开始只读复制：\(url.path, privacy: .public) → \(temp.path, privacy: .public)")

        let copies = try copyParsingFiles(from: url, to: temp)

        let version = readVersion(at: temp)
        if let version,
           let head = version.split(separator: ";").first,
           let number = Int(head.trimmingCharacters(in: .whitespaces)),
           number < 700 {
            throw FCPBundleError.unsupportedVersion(version)
        }
        let copiedLibrary = temp.appendingPathComponent("CurrentVersion.flexolibrary")
        guard FileManager.default.fileExists(atPath: copiedLibrary.path) else {
            throw FCPBundleError.unreadable(T("复制库索引 CurrentVersion.flexolibrary 失败"))
        }

        // 库索引数据库必须能打开，否则整个库都不认识
        let libraryDatabase: SQLiteReadOnly
        do {
            libraryDatabase = try SQLiteReadOnly(url: copiedLibrary)
            guard try libraryDatabase.hasTable("ZCOLLECTION") else {
                throw FCPBundleError.unreadable(T("库索引里没有 ZCOLLECTION 表"))
            }
        } catch let error as FCPBundleError {
            logger.error("库索引读取失败：\(error.localizedDescription, privacy: .public)")
            throw error
        } catch {
            logger.error("库索引数据库打不开：\(error.localizedDescription, privacy: .public)")
            throw FCPBundleError.unreadable(T("库索引数据库打不开：%@", error.localizedDescription))
        }

        var events: [FCPBundleEvent] = []
        for event in copies {
            var eventRecord = FCPBundleEvent(
                relativePath: event.relativePath,
                name: event.relativePath,
                projects: [],
                references: FCPProjectReferences(),
                warning: nil
            )

            // 事件名优先取事件级数据库，读不到就退回目录名（目录名是真实存在的信息，不是猜测）
            if let eventDB = event.databaseURL {
                do {
                    let rows = try readRows(at: eventDB)
                    if let name = displayName(in: rows, preferring: "FFMediaEvent")
                        ?? displayName(in: rows, preferring: "FFMediaEventProject") {
                        eventRecord.name = name
                    }
                    eventRecord.references = references(from: rows)
                } catch {
                    eventRecord.warning = T("事件「%@」的数据库读不出来：%@", event.relativePath, error.localizedDescription)
                    logger.error("事件数据库读取失败 \(eventDB.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            for project in event.projects {
                var projectRecord = FCPBundleProject(
                    eventRelativePath: event.relativePath,
                    relativePath: project.relativePath,
                    name: project.relativePath,
                    references: FCPProjectReferences(),
                    warning: nil
                )
                guard let projectDB = project.databaseURL else {
                    projectRecord.warning = T("工程「%@」没有 CurrentVersion.fcpevent", project.relativePath)
                    eventRecord.projects.append(projectRecord)
                    continue
                }
                do {
                    let rows = try readRows(at: projectDB)
                    if let name = displayName(in: rows, preferring: "FFMediaEventProject") {
                        projectRecord.name = name
                    }
                    if rows.isEmpty {
                        projectRecord.warning = T("工程「%@」的数据库是空的", project.relativePath)
                    }
                    if rows.contains(where: { $0.metadataDecodeFailed }) {
                        projectRecord.warning = T("工程「%@」有内容解析失败", project.relativePath)
                    }
                    projectRecord.references = references(from: rows)
                } catch {
                    projectRecord.warning = T("工程「%@」的数据库读不出来：%@", project.relativePath, error.localizedDescription)
                    logger.error("工程数据库读取失败 \(projectDB.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                eventRecord.projects.append(projectRecord)
            }

            events.append(eventRecord)
        }

        guard !events.isEmpty else {
            throw FCPBundleError.noEvents
        }

        var result = FCPBundleScanResult(
            libraryURL: url,
            libraryName: url.deletingPathExtension().lastPathComponent,
            libraryVersion: version,
            isLocked: lockState.isLocked,
            notice: lockState.notice,
            events: events.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        )
        result.libraryExtraReferences = readEffectsMap(at: temp)
        result.selectedProjectIDs = Set(result.allProjects.map(\.id))

        // 库索引里的记录数只做交叉验证，对不上时留日志，不影响解析
        if let count = try? libraryDatabase.rowCount(in: "ZCOLLECTION", where: "ZTYPE = 'FFEventRecord'"),
           count != events.count {
            logger.notice("库索引记录 \(count) 个事件，磁盘上找到 \(events.count) 个")
        }
        logger.notice("库扫描完成：事件 \(events.count) 个、工程 \(result.projectCount) 个、版本 \(version ?? "未知", privacy: .public)")
        return result
    }

    // MARK: 锁

    private struct LockState {
        var isLocked: Bool
        var notice: String?
    }

    private static func readLockState(in bundle: URL) -> LockState {
        let fm = FileManager.default
        let lock = bundle.appendingPathComponent(".lock")
        guard fm.fileExists(atPath: lock.path) else {
            return LockState(isLocked: false, notice: nil)
        }

        let fcpRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.FinalCut")
            .isEmpty
        if fcpRunning {
            return LockState(
                isLocked: true,
                notice: T("库正在 FCP 中使用，已按只读分析。建议先退出 Final Cut Pro，再执行停用。")
            )
        }

        // 有 .lock 但 FCP 没开：大多是上次没正常退出留下的，仍然只读处理
        let info = bundle.appendingPathComponent(".lock-info")
        var detail = ""
        if let data = try? Data(contentsOf: info),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let host = plist["hostname"] as? String,
           let user = plist["user"] as? String {
            detail = T("（记录来自 %@ / %@）", host, user)
        }
        return LockState(
            isLocked: true,
            notice: T("检测到库里有 .lock 标记%@，可能是上次未正常退出留下的。已按只读分析，不会改动原库。", detail)
        )
    }

    // MARK: 版本

    private static func readVersion(at bareCopy: URL) -> String? {
        let url = bareCopy.appendingPathComponent("CurrentVersion.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["catalogVersion"] as? String
    }

    // MARK: 复制

    private struct CopiedProject {
        let relativePath: String
        let databaseURL: URL?
    }

    private struct CopiedEvent {
        let relativePath: String
        let databaseURL: URL?
        let projects: [CopiedProject]
    }

    /// 只复制解析需要的文件，跳过 Render Files 和媒体。
    private static func copyParsingFiles(from bundle: URL, to temp: URL) throws -> [CopiedEvent] {
        let fm = FileManager.default
        for name in ["CurrentVersion.flexolibrary", "CurrentVersion.plist", "Settings.plist", "Effects.map"] {
            let source = bundle.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try copyFile(source, to: temp.appendingPathComponent(name))
        }

        let children = (try? fm.contentsOfDirectory(
            at: bundle,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var events: [CopiedEvent] = []
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            if skippedDirectoryNames.contains(child.lastPathComponent.lowercased()) { continue }

            let eventDB = child.appendingPathComponent("CurrentVersion.fcpevent")
            guard fm.fileExists(atPath: eventDB.path) else { continue }

            let eventTarget = temp.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            try fm.createDirectory(at: eventTarget, withIntermediateDirectories: true)
            try copyFile(eventDB, to: eventTarget.appendingPathComponent("CurrentVersion.fcpevent"))

            var projects: [CopiedProject] = []
            let subdirectories = (try? fm.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for sub in subdirectories {
                let subIsDirectory = (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard subIsDirectory else { continue }
                let name = sub.lastPathComponent.lowercased()
                if skippedDirectoryNames.contains(name) || name.hasPrefix("__") { continue }

                let projectDB = sub.appendingPathComponent("CurrentVersion.fcpevent")
                guard fm.fileExists(atPath: projectDB.path) else { continue }
                let projectTarget = eventTarget.appendingPathComponent(sub.lastPathComponent, isDirectory: true)
                try fm.createDirectory(at: projectTarget, withIntermediateDirectories: true)
                try copyFile(projectDB, to: projectTarget.appendingPathComponent("CurrentVersion.fcpevent"))
                projects.append(CopiedProject(relativePath: sub.lastPathComponent, databaseURL: projectTarget.appendingPathComponent("CurrentVersion.fcpevent")))
            }

            events.append(CopiedEvent(
                relativePath: child.lastPathComponent,
                databaseURL: eventTarget.appendingPathComponent("CurrentVersion.fcpevent"),
                projects: projects.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            ))
        }
        return events
    }

    /// 优先用 ditto 复制（保留资源分支）；失败时退回 FileManager。
    private static func copyFile(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        } catch {
            logger.debug("ditto 不可用，改用 FileManager：\(error.localizedDescription, privacy: .public)")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: 读集合

    private struct CollectionRow {
        let type: String
        let metadata: [String: BinaryPlistValue]
        let metadataDecodeFailed: Bool
    }

    private static func readRows(at url: URL) throws -> [CollectionRow] {
        let database = try SQLiteReadOnly(url: url)
        guard try database.hasTable("ZCOLLECTION") else {
            throw FCPBundleError.unreadable(T("%@ 里没有 ZCOLLECTION 表", url.lastPathComponent))
        }
        let raw = try database.collectionRows()
        return raw.map { row in
            guard let blob = row.blob else {
                return CollectionRow(type: row.type, metadata: [:], metadataDecodeFailed: false)
            }
            if let metadata = KeyedArchiveDecoder.decodeMetadata(blob) {
                return CollectionRow(type: row.type, metadata: metadata, metadataDecodeFailed: false)
            }
            return CollectionRow(type: row.type, metadata: [:], metadataDecodeFailed: true)
        }
    }

    private static func references(from rows: [CollectionRow]) -> FCPProjectReferences {
        var references = FCPProjectReferences()
        for row in rows {
            guard let effectID = stringValue("effectID", in: row.metadata), !effectID.isEmpty else { continue }
            let normalizedID = effectID.removingPercentEncoding ?? effectID
            guard isPluginReference(normalizedID) else { continue }
            references.uids.insert(normalizedID)
            if let name = stringValue("displayName", in: row.metadata), !name.isEmpty {
                references.names.insert(name)
            }
        }
        return references
    }

    /// FCP 内置效果（如 FFHeColorEffect、HEConform）不是插件，不参与匹配，
    /// 否则会被当成「本机缺失的插件」误报。
    static func isPluginReference(_ effectID: String) -> Bool {
        if effectID.hasPrefix("~/") || effectID.hasPrefix("/") { return true }
        if effectID.contains("/") { return true }
        let lower = effectID.lowercased()
        if [".moti", ".moef", ".motr", ".plugin", ".fxplug", ".component", ".bundle"].contains(where: lower.hasSuffix) {
            return true
        }
        if lower.contains(".") && !lower.hasPrefix("ff") { return true }
        return false
    }

    private static func stringValue(_ key: String, in metadata: [String: BinaryPlistValue]) -> String? {
        guard case .string(let value)? = metadata[key] else { return nil }
        return value
    }

    private static func displayName(in rows: [CollectionRow], preferring type: String) -> String? {
        guard let value = rows.first(where: { $0.type == type })
            .flatMap({ stringValue("displayName", in: $0.metadata) }), !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: Effects.map

    /// 库根 Effects.map 是 UID → 效果资源的归档。这里只取路径字符串，作为整库统计的补充。
    private static func readEffectsMap(at bareCopy: URL) -> FCPProjectReferences {
        let url = bareCopy.appendingPathComponent("Effects.map")
        guard let data = try? Data(contentsOf: url),
              let root = KeyedArchiveDecoder.decode(data) else {
            return FCPProjectReferences()
        }
        var paths = Set<String>()
        collectPathStrings(root, into: &paths)
        var references = FCPProjectReferences()
        for path in paths {
            let decoded = path.removingPercentEncoding ?? path
            guard isPluginReference(decoded) else { continue }
            references.uids.insert(decoded)
        }
        return references
    }

    private static func collectPathStrings(_ value: BinaryPlistValue, into paths: inout Set<String>) {
        switch value {
        case .string(let text):
            guard text.contains("/") else { return }
            let lower = text.lowercased()
            if [".moti", ".moef", ".motr", ".plugin", ".fxplug", ".component", ".bundle"].contains(where: lower.hasSuffix)
                || lower.contains("templates.localized") {
                paths.insert(text)
            }
        case .array(let values):
            for item in values { collectPathStrings(item, into: &paths) }
        case .dictionary(let values):
            for item in values.values { collectPathStrings(item, into: &paths) }
        default:
            break
        }
    }
}

// MARK: - 只读 SQLite

private final class SQLiteReadOnly {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        // immutable=1 让 SQLite 不加任何锁，也不写日志
        let uri = url.absoluteString + "?mode=ro&immutable=1"
        let result = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 错误 \(result)"
            sqlite3_close(database)
            throw FCPBundleError.unreadable(T("以只读方式打开失败：%@", message))
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    func hasTable(_ name: String) throws -> Bool {
        try rowCount(in: "sqlite_master", where: "type = 'table' AND name = '\(name)'") > 0
    }

    func rowCount(in table: String, where condition: String) throws -> Int {
        try query("SELECT COUNT(*) FROM \(table) WHERE \(condition)") { statement in
            Int(sqlite3_column_int(statement, 0))
        }.first ?? 0
    }

    struct RawRow {
        let type: String
        let blob: Data?
    }

    func collectionRows() throws -> [RawRow] {
        try query("""
            SELECT c.ZTYPE, m.ZDICTIONARYDATA
            FROM ZCOLLECTION c
            LEFT JOIN ZCOLLECTIONMD m ON m.ZCOLLECTION = c.Z_PK
            """) { statement in
            let type = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            var blob: Data?
            if let bytes = sqlite3_column_blob(statement, 1) {
                let count = Int(sqlite3_column_bytes(statement, 1))
                if count > 0 {
                    blob = Data(bytes: bytes, count: count)
                }
            }
            return RawRow(type: type, blob: blob)
        }
    }

    private func query<Element>(_ sql: String, row: (OpaquePointer) -> Element) throws -> [Element] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw FCPBundleError.unreadable(T("查询失败：%@", message))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Element] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append(row(statement!))
            } else if step == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errmsg(handle))
                throw FCPBundleError.unreadable(T("读取失败：%@", message))
            }
        }
        return rows
    }
}

// MARK: - NSKeyedArchiver

/// 只解码 .fcpbundle 里的归档对象图。
/// 不依赖 NSKeyedUnarchiver：FCP 的 NSMapTable 归档会让系统解码器报「Missing key」。
enum KeyedArchiveDecoder {
    static func decode(_ data: Data) -> BinaryPlistValue? {
        guard let root = try? BinaryPlist(data: data).parse() else { return nil }
        guard case .dictionary(let top) = root,
              case .array(let objects)? = top["$objects"] else {
            return nil
        }
        let rootIndex: Int
        if case .dictionary(let topDict)? = top["$top"],
           case .uid(let index)? = topDict["root"] {
            rootIndex = index
        } else {
            rootIndex = 1
        }
        return resolve(.uid(rootIndex), objects: objects, depth: 0)
    }

    static func decodeMetadata(_ data: Data) -> [String: BinaryPlistValue]? {
        guard case .dictionary(let value)? = decode(data) else { return nil }
        return value
    }

    private static func resolve(_ value: BinaryPlistValue, objects: [BinaryPlistValue], depth: Int) -> BinaryPlistValue {
        guard depth < 40 else { return .null }
        switch value {
        case .uid(let index):
            guard index > 0, index < objects.count else { return .null }
            return resolve(objects[index], objects: objects, depth: depth + 1)
        case .dictionary(let dictionary):
            if case .array(let keys)? = dictionary["NS.keys"],
               case .array(let values)? = dictionary["NS.objects"] {
                var result: [String: BinaryPlistValue] = [:]
                for (key, value) in zip(keys, values) {
                    guard case .string(let name) = resolve(key, objects: objects, depth: depth + 1) else { continue }
                    result[name] = resolve(value, objects: objects, depth: depth + 1)
                }
                return .dictionary(result)
            }
            var result: [String: BinaryPlistValue] = [:]
            // NSMapTable 的键是 $0…$N 这种编号，不能按「$ 开头就丢」处理
            for (key, value) in dictionary where !["$class", "$classes", "$classname"].contains(key) {
                result[key] = resolve(value, objects: objects, depth: depth + 1)
            }
            return .dictionary(result)
        case .array(let values):
            return .array(values.map { resolve($0, objects: objects, depth: depth + 1) })
        default:
            return value
        }
    }
}

// MARK: - 最小二进制 plist 解析

/// 只实现 FCP 库用得到的部分：标量、数组、字典、UID。
enum BinaryPlistValue {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case uid(Int)
    case array([BinaryPlistValue])
    case dictionary([String: BinaryPlistValue])
}

struct BinaryPlist {
    private let bytes: [UInt8]
    private let offsetIntSize: Int
    private let objectRefSize: Int
    private let objectCount: Int
    private let topObject: Int
    private let offsets: [Int]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 40,
              String(bytes: bytes[0..<8], encoding: .ascii) == "bplist00" else {
            throw FCPBundleError.unreadable(T("不是二进制 plist"))
        }
        let trailer = bytes.count - 32
        offsetIntSize = Int(bytes[trailer + 6])
        objectRefSize = Int(bytes[trailer + 7])
        let count = Self.readUInt(bytes, at: trailer + 8, size: 8)
        topObject = Int(Self.readUInt(bytes, at: trailer + 16, size: 8))
        let offsetTable = Int(Self.readUInt(bytes, at: trailer + 24, size: 8))

        guard offsetIntSize > 0, offsetIntSize <= 8,
              objectRefSize > 0, objectRefSize <= 8,
              count > 0, count < 1_000_000,
              offsetTable > 0, offsetTable < bytes.count else {
            throw FCPBundleError.unreadable(T("二进制 plist 尾部信息不完整"))
        }
        objectCount = Int(count)

        var table: [Int] = []
        table.reserveCapacity(objectCount)
        for index in 0..<objectCount {
            table.append(Int(Self.readUInt(bytes, at: offsetTable + index * offsetIntSize, size: offsetIntSize)))
        }
        offsets = table
        self.bytes = bytes
    }

    func parse() throws -> BinaryPlistValue {
        try object(at: topObject, depth: 0)
    }

    private func object(at index: Int, depth: Int) throws -> BinaryPlistValue {
        guard depth < 60, index >= 0, index < offsets.count else {
            throw FCPBundleError.unreadable(T("对象引用越界"))
        }
        let start = offsets[index]
        guard start >= 0, start < bytes.count else {
            throw FCPBundleError.unreadable(T("对象偏移越界"))
        }
        let marker = bytes[start]
        let type = marker >> 4
        let info = Int(marker & 0x0F)

        switch type {
        case 0x0:
            if info == 0x08 { return .bool(false) }
            if info == 0x09 { return .bool(true) }
            return .null
        case 0x1:
            let size = 1 << info
            guard size <= 8 else { throw FCPBundleError.unreadable(T("整数宽度不对")) }
            let raw = Self.readUInt(bytes, at: start + 1, size: size, limit: bytes.count)
            let bits = size * 8
            // plist 里的整数是补码，可能是负数，直接 Int64(raw) 会溢出崩溃
            let value = bits == 64
                ? Int64(bitPattern: raw)
                : Int64(bitPattern: raw << (64 - bits)) >> (64 - bits)
            return .int(value)
        case 0x2:
            let size = 1 << info
            if size == 4 {
                let bits = UInt32(Self.readUInt(bytes, at: start + 1, size: 4, limit: bytes.count))
                return .real(Double(Float(bitPattern: bits)))
            }
            let bits = Self.readUInt(bytes, at: start + 1, size: 8, limit: bytes.count)
            return .real(Double(bitPattern: bits))
        case 0x4:
            let (count, header) = try length(at: start, info: info)
            let begin = start + header
            guard begin + count <= bytes.count else { throw FCPBundleError.unreadable(T("数据段越界")) }
            return .data(Data(bytes[begin..<(begin + count)]))
        case 0x5:
            let (count, header) = try length(at: start, info: info)
            let begin = start + header
            guard begin + count <= bytes.count else { throw FCPBundleError.unreadable(T("字符串越界")) }
            return .string(String(bytes: bytes[begin..<(begin + count)], encoding: .ascii) ?? "")
        case 0x6:
            let (count, header) = try length(at: start, info: info)
            let begin = start + header
            guard begin + count * 2 <= bytes.count else { throw FCPBundleError.unreadable(T("UTF-16 字符串越界")) }
            let data = Data(bytes[begin..<(begin + count * 2)])
            return .string(String(data: data, encoding: .utf16BigEndian) ?? "")
        case 0x8:
            let size = info + 1
            return .uid(Int(Self.readUInt(bytes, at: start + 1, size: size, limit: bytes.count)))
        case 0xA, 0xC:
            let (count, header) = try length(at: start, info: info)
            let begin = start + header
            guard begin + count * objectRefSize <= bytes.count else { throw FCPBundleError.unreadable(T("数组越界")) }
            var values: [BinaryPlistValue] = []
            values.reserveCapacity(count)
            for item in 0..<count {
                let ref = Int(Self.readUInt(bytes, at: begin + item * objectRefSize, size: objectRefSize, limit: bytes.count))
                values.append(try object(at: ref, depth: depth + 1))
            }
            return .array(values)
        case 0xD:
            let (count, header) = try length(at: start, info: info)
            let begin = start + header
            guard begin + count * 2 * objectRefSize <= bytes.count else { throw FCPBundleError.unreadable(T("字典越界")) }
            var result: [String: BinaryPlistValue] = [:]
            for item in 0..<count {
                let keyRef = Int(Self.readUInt(bytes, at: begin + item * objectRefSize, size: objectRefSize, limit: bytes.count))
                let valueRef = Int(Self.readUInt(bytes, at: begin + (count + item) * objectRefSize, size: objectRefSize, limit: bytes.count))
                guard case .string(let key) = try object(at: keyRef, depth: depth + 1) else { continue }
                result[key] = try object(at: valueRef, depth: depth + 1)
            }
            return .dictionary(result)
        default:
            throw FCPBundleError.unreadable(T("未知的 plist 对象类型：%d", Int(marker)))
        }
    }

    private func length(at start: Int, info: Int) throws -> (count: Int, header: Int) {
        if info != 0x0F {
            return (info, 1)
        }
        guard start + 1 < bytes.count else { throw FCPBundleError.unreadable(T("长度字段越界")) }
        let marker = bytes[start + 1]
        guard marker >> 4 == 0x1 else { throw FCPBundleError.unreadable(T("长度字段格式不对")) }
        let size = 1 << Int(marker & 0x0F)
        let count = Int(Self.readUInt(bytes, at: start + 2, size: size, limit: bytes.count))
        return (count, 2 + size)
    }

    private static func readUInt(_ bytes: [UInt8], at offset: Int, size: Int, limit: Int? = nil) -> UInt64 {
        let bound = limit ?? bytes.count
        guard size > 0, size <= 8, offset >= 0, offset + size <= bound else { return 0 }
        var value: UInt64 = 0
        for index in 0..<size {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }
}
