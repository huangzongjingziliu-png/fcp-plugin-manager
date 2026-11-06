import Foundation
import Combine
import AppKit

// MARK: - Plugin Item

struct PluginItem: Identifiable, Equatable {
    let name: String
    let path: String
    let category: PluginCategory
    let source: PluginSource
    let isSystemLevel: Bool
    /// 从插件包 Info.plist 读到的版本号，模板包通常没有
    let version: String?
    /// 版权/厂商信息，能读到就显示
    let vendor: String?
    let bundleIdentifier: String?
    let sizeBytes: Int64?
    let installDate: Date?

    /// 用路径做稳定标识：同一路径在多次扫描之间不会变，列表不会串行
    var id: String { path }

    var displayName: String { name }

    var shortLocation: String { source.shortLocation }

    /// 界面显示用；shortLocation 仍作为内部标识，不跟语言变
    var localizedLocation: String { source.localizedLocation }

    var sizeDescription: String? {
        guard let sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var installDateDescription: String? {
        guard let installDate else { return nil }
        return Self.dateFormatter.string(from: installDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init?(path: String, source: PluginSource) {
        let url = URL(fileURLWithPath: path)
        let component = url.lastPathComponent
        guard !component.hasPrefix(".") &&
              !component.hasSuffix(".localized") &&
              component != ".DS_Store" &&
              !component.isEmpty else {
            return nil
        }
        let info = Self.readBundleInfo(at: url)
        self.name = component
        self.path = path
        self.source = source
        self.category = Self.categorize(from: source)
        self.isSystemLevel = source.isSystemLevel
        self.version = info.version
        self.vendor = info.vendor
        self.bundleIdentifier = info.bundleIdentifier
        self.sizeBytes = Self.directorySize(at: url)
        self.installDate = Self.installDate(at: url)
    }

    // MARK: 详情读取

    private struct BundleInfo {
        var version: String?
        var vendor: String?
        var bundleIdentifier: String?
    }

    private static func readBundleInfo(at url: URL) -> BundleInfo {
        let fm = FileManager.default
        let candidates = [
            url.appendingPathComponent("Contents/Info.plist"),
            url.appendingPathComponent("Info.plist")
        ]
        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            guard let dict = NSDictionary(contentsOf: candidate) as? [String: Any] else { continue }
            var info = BundleInfo()
            info.version = (dict["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (dict["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            info.bundleIdentifier = (dict["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            let rawVendor = (dict["NSHumanReadableCopyright"] as? String)
                ?? (dict["CFBundleGetInfoString"] as? String)
            if let rawVendor {
                let trimmed = rawVendor.trimmingCharacters(in: .whitespacesAndNewlines)
                info.vendor = trimmed.isEmpty ? nil : String(trimmed.prefix(120))
            }
            return info
        }
        return BundleInfo()
    }

    private static func directorySize(at url: URL) -> Int64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func installDate(at url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}

// MARK: - Backup Item

struct BackupItem: Identifiable {
    let name: String
    let backupPath: String
    let originalPath: String
    let category: PluginCategory
    let isSystemLevel: Bool

    var id: String { backupPath }
    var displayName: String { name }
    var shortLocation: String { T("已备份") }
}

// MARK: - Disabled Item

struct DisabledItem: Identifiable {
    let name: String
    /// 实际插件所在的路径（应用自己的 Disabled 目录内）
    let currentPath: String
    /// 这条禁用记录的外层目录，里面还有 .metadata
    let entryPath: String
    let originalPath: String
    let category: PluginCategory
    let isSystemLevel: Bool
    let disabledDate: Date?

    var id: String { originalPath.isEmpty ? entryPath : originalPath }
    var displayName: String { name }
    var shortLocation: String { T("已禁用") }

    /// 禁用目录里到底有没有插件本体
    var hasPayload: Bool {
        !currentPath.isEmpty && FileManager.default.fileExists(atPath: currentPath)
    }

    /// 原位置还在不在
    var originalExists: Bool {
        !originalPath.isEmpty && FileManager.default.fileExists(atPath: originalPath)
    }

    /// 只有「原位置已经不存在」才算真正停用。
    /// 系统级插件以前只复制了一份、原文件没动，FCP 仍然会加载，不能算已停用。
    var isEffective: Bool {
        guard !originalPath.isEmpty else { return false }
        return !originalExists
    }

    /// 禁用目录里有一份副本，但原位置也还在：
    /// 旧版本「只复制、没移走」留下的无效记录，插件其实一直在用。
    var isRedundantCopy: Bool {
        hasPayload && originalExists
    }

    /// 没有 .metadata 的老记录，拿不到原路径。不能猜，也不能显示成「待执行管理员命令」。
    var isRecordIncomplete: Bool {
        originalPath.isEmpty
    }

    var statusDescription: String {
        if isRecordIncomplete { return T("记录信息缺失（原位置未知）") }
        if isEffective { return T("已停用（已生效）") }
        if isRedundantCopy { return T("未生效（原插件仍在用）") }
        return T("待执行管理员命令（未生效）")
    }
}

// MARK: - Plugin Source

enum PluginSource: CaseIterable {
    case systemEffects
    case systemGenerators
    case systemTitles
    case systemTransitions
    case userEffects
    case userGenerators
    case userTitles
    case userTransitions
    /// FxPlug 插件包，装在这里的厂商插件不在 Motion Templates 里
    case systemPlugIns
    case userPlugIns

    private static let systemTemplates = "/Library/Application Support/Final Cut Pro/Templates.localized"
    private static let legacySystemTemplates = "/Library/Application Support/Final Cut Pro/Templates"

    /// 一个分类可能有多个安装位置（.localized 与非 .localized 两种命名都见过）
    var directoryURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLocalized = home.appendingPathComponent("Movies/Motion Templates.localized", isDirectory: true)
        let userPlain = home.appendingPathComponent("Movies/Motion Templates", isDirectory: true)

        switch self {
        case .systemEffects:
            return [
                URL(fileURLWithPath: "\(Self.systemTemplates)/Effects.localized", isDirectory: true),
                URL(fileURLWithPath: "\(Self.legacySystemTemplates)/Effects", isDirectory: true)
            ]
        case .systemGenerators:
            return [
                URL(fileURLWithPath: "\(Self.systemTemplates)/Generators.localized", isDirectory: true),
                URL(fileURLWithPath: "\(Self.legacySystemTemplates)/Generators", isDirectory: true)
            ]
        case .systemTitles:
            return [
                URL(fileURLWithPath: "\(Self.systemTemplates)/Titles.localized", isDirectory: true),
                URL(fileURLWithPath: "\(Self.legacySystemTemplates)/Titles", isDirectory: true)
            ]
        case .systemTransitions:
            return [
                URL(fileURLWithPath: "\(Self.systemTemplates)/Transitions.localized", isDirectory: true),
                URL(fileURLWithPath: "\(Self.legacySystemTemplates)/Transitions", isDirectory: true)
            ]
        case .userEffects:
            return [
                userLocalized.appendingPathComponent("Effects.localized", isDirectory: true),
                userPlain.appendingPathComponent("Effects", isDirectory: true)
            ]
        case .userGenerators:
            return [
                userLocalized.appendingPathComponent("Generators.localized", isDirectory: true),
                userPlain.appendingPathComponent("Generators", isDirectory: true)
            ]
        case .userTitles:
            return [
                userLocalized.appendingPathComponent("Titles.localized", isDirectory: true),
                userPlain.appendingPathComponent("Titles", isDirectory: true)
            ]
        case .userTransitions:
            return [
                userLocalized.appendingPathComponent("Transitions.localized", isDirectory: true),
                userPlain.appendingPathComponent("Transitions", isDirectory: true)
            ]
        case .systemPlugIns:
            return [URL(fileURLWithPath: "/Library/Plug-ins/FxPlug", isDirectory: true)]
        case .userPlugIns:
            return [home.appendingPathComponent("Library/Plug-ins/FxPlug", isDirectory: true)]
        }
    }

    var shortLocation: String {
        switch self {
        case .systemEffects: return "系统/效果"
        case .systemGenerators: return "系统/发生器"
        case .systemTitles: return "系统/标题"
        case .systemTransitions: return "系统/转场"
        case .userEffects: return "用户/效果"
        case .userGenerators: return "用户/发生器"
        case .userTitles: return "用户/标题"
        case .userTransitions: return "用户/转场"
        case .systemPlugIns: return "系统/插件"
        case .userPlugIns: return "用户/插件"
        }
    }

    var isSystemLevel: Bool {
        switch self {
        case .userEffects, .userGenerators, .userTitles, .userTransitions, .userPlugIns:
            return false
        default:
            return true
        }
    }

    /// 界面显示用的位置名；shortLocation 继续作为内部稳定标识
    var localizedLocation: String { T(shortLocation) }
}

extension PluginItem {
    static func categorize(from source: PluginSource) -> PluginCategory {
        switch source {
        case .systemEffects, .userEffects, .systemPlugIns, .userPlugIns: return .effects
        case .systemGenerators, .userGenerators: return .generators
        case .systemTitles, .userTitles: return .titles
        case .systemTransitions, .userTransitions: return .transitions
        }
    }
}

// MARK: - Scanner

struct ScannedLocation: Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let exists: Bool
    let foundCount: Int
}

struct ScanReport {
    let items: [PluginItem]
    let locations: [ScannedLocation]
}

/// 一个扫描根目录。测试时可以注入临时目录，生产环境用 PluginSource 的默认位置。
struct ScanRoot {
    let source: PluginSource
    let url: URL
}

struct PluginScanner {
    private let fm = FileManager.default
    private let roots: [ScanRoot]

    /// 单文件形态的插件，模板目录里混着的图片不会被当成插件
    private static let pluginFileExtensions: Set<String> = [
        "plugin", "fxplug", "app", "component", "pluginkit"
    ]

    init(roots: [ScanRoot]? = nil) {
        if let roots {
            self.roots = roots
        } else {
            self.roots = PluginSource.allCases.flatMap { source in
                source.directoryURLs.map { ScanRoot(source: source, url: $0) }
            }
        }
    }

    func scan() -> ScanReport {
        var items: [PluginItem] = []
        var locations: [ScannedLocation] = []

        for root in roots {
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: root.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            let found = exists ? scanDirectory(root.url, source: root.source) : []
            items.append(contentsOf: found)
            locations.append(
                ScannedLocation(
                    label: root.source.localizedLocation,
                    path: root.url.path,
                    exists: exists,
                    foundCount: found.count
                )
            )
        }

        return ScanReport(items: items, locations: locations)
    }

    func scanDirectory(_ url: URL, source: PluginSource) -> [PluginItem] {
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            // FCP 与 FxFactory 的分组容器，里面才是真正的条目
            if name.hasPrefix(".") || name.hasSuffix(".localized") { return nil }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { return nil }
            if !isDirectory.boolValue,
               !Self.pluginFileExtensions.contains(entry.pathExtension.lowercased()) {
                return nil
            }
            return PluginItem(path: entry.path, source: source)
        }
    }
}

// MARK: - Operation Log

enum OperationKind: String, Codable {
    case deletePlugins
    case restoreBackups
    case deleteBackups
    case disablePlugins
    case enablePlugins
    case renamePlugin
    case clearBackups

    var displayName: String {
        switch self {
        case .deletePlugins: return T("备份并删除")
        case .restoreBackups: return T("恢复备份")
        case .deleteBackups: return T("删除备份")
        case .disablePlugins: return T("禁用插件")
        case .enablePlugins: return T("启用插件")
        case .renamePlugin: return T("重命名插件")
        case .clearBackups: return T("清空备份")
        }
    }
}

struct BackupSnapshot: Codable {
    let name: String
    let backupPath: String
    let originalPath: String
    let categoryRaw: String
    let isSystemLevel: Bool

    init(_ backup: BackupItem) {
        self.name = backup.name
        self.backupPath = backup.backupPath
        self.originalPath = backup.originalPath
        self.categoryRaw = backup.category.rawValue
        self.isSystemLevel = backup.isSystemLevel
    }

    var backupItem: BackupItem {
        BackupItem(
            name: name,
            backupPath: backupPath,
            originalPath: originalPath,
            category: PluginCategory(rawValue: categoryRaw) ?? .all,
            isSystemLevel: isSystemLevel
        )
    }
}

struct DisabledSnapshot: Codable {
    let name: String
    let currentPath: String
    let entryPath: String
    let originalPath: String
    let categoryRaw: String
    let isSystemLevel: Bool

    init(_ item: DisabledItem) {
        self.name = item.name
        self.currentPath = item.currentPath
        self.entryPath = item.entryPath
        self.originalPath = item.originalPath
        self.categoryRaw = item.category.rawValue
        self.isSystemLevel = item.isSystemLevel
    }

    var disabledItem: DisabledItem {
        DisabledItem(
            name: name,
            currentPath: currentPath,
            entryPath: entryPath,
            originalPath: originalPath,
            category: PluginCategory(rawValue: categoryRaw) ?? .all,
            isSystemLevel: isSystemLevel,
            disabledDate: nil
        )
    }
}

struct RenameSnapshot: Codable {
    let oldPath: String
    let newPath: String
}

struct OperationRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let kind: OperationKind
    let summary: String
    let backups: [BackupSnapshot]
    let disabled: [DisabledSnapshot]
    /// 旧日志没有这个字段，用可选类型保证还能读出来
    var renames: [RenameSnapshot]?
    var undone: Bool

    /// 有可回退的数据、且还没撤销过，才显示「撤销上一步」
    var isUndoable: Bool {
        !undone && (!backups.isEmpty || !disabled.isEmpty || !(renames ?? []).isEmpty)
    }
}

struct UndoOutcome {
    var restoredCount = 0
    var failures: [String] = []
    var needsAuth: [String] = []
    var isComplete: Bool { failures.isEmpty && needsAuth.isEmpty }
}

// MARK: - Admin Execution

/// 管理员命令的执行结果（osascript 授权对话框的返回值）
struct AdminRunResult: Sendable {
    let succeeded: Bool
    let message: String
}

struct AdminApplyOutcome {
    var attemptedCount = 0
    var succeededCount = 0
    var stillPendingNames: [String] = []
    var wasCancelled = false
    var message = ""
}

/// 拼管理员命令。测试里可以单独验证，不执行。
struct AdminCommandBuilder {
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 真正停用：原文件还在、禁用目录里没本体 → 移进去；
    /// 老版本留下的「复制件 + 原文件」→ 删掉原文件，保留应用内的那份。
    static func disableScript(for items: [DisabledItem]) -> String {
        var lines = ["set -u"]
        let uid = getuid()
        let gid = getgid()
        for item in items {
            let entry = quote(item.entryPath)
            let payload = quote(item.currentPath)
            let original = quote(item.originalPath)
            lines.append("mkdir -p \(entry)")
            lines.append("if [ -d \(payload) ]; then rm -rf \(original); else mv \(original) \(payload) && chown -R \(uid):\(gid) \(entry); fi")
        }
        return lines.joined(separator: "\n")
    }

    /// 真正恢复：把禁用目录里的本体移回原位置，再清掉记录。
    static func enableScript(for items: [DisabledItem]) -> String {
        var lines = ["set -u"]
        for item in items {
            let entry = quote(item.entryPath)
            let payload = quote(item.currentPath)
            let original = quote(item.originalPath)
            let parent = quote(URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path)
            lines.append("mkdir -p \(parent)")
            lines.append("if [ -d \(payload) ] && [ ! -e \(original) ]; then mv \(payload) \(original) && rm -rf \(entry); fi")
        }
        return lines.joined(separator: "\n")
    }

    /// 给用户手动粘贴的版本（自动授权被系统拦截时用）
    static func manualDisableCommands(for items: [DisabledItem]) -> String {
        let uid = getuid()
        let gid = getgid()
        return items.map { item -> String in
            let entry = quote(item.entryPath)
            let payload = quote(item.currentPath)
            let original = quote(item.originalPath)
            if item.hasPayload {
                return "# \(item.displayName)：保留应用内副本，删除系统目录原文件\nsudo rm -rf \(original)\nsudo chown -R \(uid):\(gid) \(entry)"
            }
            return "# \(item.displayName)：把系统目录里的插件移进应用禁用目录\nsudo mkdir -p \(entry)\nsudo mv \(original) \(payload)\nsudo chown -R \(uid):\(gid) \(entry)"
        }.joined(separator: "\n\n")
    }

    static func manualEnableCommands(for items: [DisabledItem]) -> String {
        items.map { item -> String in
            let entry = quote(item.entryPath)
            let payload = quote(item.currentPath)
            let original = quote(item.originalPath)
            let parent = quote(URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path)
            return "# \(item.displayName)：放回系统目录\nsudo mkdir -p \(parent)\nsudo mv \(payload) \(original)\nsudo rm -rf \(entry)"
        }.joined(separator: "\n\n")
    }

    static func renameCommand(oldPath: String, newPath: String) -> String {
        "sudo mv \(quote(oldPath)) \(quote(newPath))"
    }
}

// MARK: - View Model

// MARK: - 批量进度

/// 批量操作的进度，给界面显示进度条和「停止」用。
struct BatchProgress {
    var title: String
    var completed: Int
    var total: Int
    var isCancelling = false
}

// MARK: - Plugin ViewModel

@MainActor
class PluginViewModel: ObservableObject {
    @Published var plugins: [PluginItem] = []
    @Published var backups: [BackupItem] = []
    @Published var disabledItems: [DisabledItem] = []
    @Published var operations: [OperationRecord] = []
    /// 改名台账：独立于备份记录，专门用来把名字改回去
    @Published var renameLedger: [RenameLedgerEntry] = []
    /// 台账读不出来时这里会有说明，界面必须明确告诉用户「原名已无从得知」
    @Published var renameLedgerProblem: String?
    /// 批量任务进度；为 nil 表示当前没有批量任务
    @Published var batchProgress: BatchProgress?
    private var batchStopRequested = false
    @Published var selectedPluginIDs: Set<String> = []
    @Published var isScanning = false
    /// 本次扫描覆盖了哪些目录、各找到几个，用于空状态排查
    @Published var scanLocations: [ScannedLocation] = []

    private let fm = FileManager.default
    /// 测试时指向临时目录，生产环境为 nil，走 Application Support
    private let storageRootOverride: URL?
    /// 管理员命令执行器。测试注入假实现，生产走 osascript 授权对话框
    private let adminRunner: @Sendable (String) -> AdminRunResult

    init(
        storageRootOverride: URL? = nil,
        adminRunner: @escaping @Sendable (String) -> AdminRunResult = { PluginViewModel.runWithAdministrator($0) }
    ) {
        self.storageRootOverride = storageRootOverride
        self.adminRunner = adminRunner
        loadBackups()
        loadDisabled()
        loadOperations()
        loadRenameLedger()
    }

    /// 弹出 macOS 标准管理员授权对话框执行命令；用户取消会返回失败。
    nonisolated static func runWithAdministrator(_ script: String) -> AdminRunResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return AdminRunResult(succeeded: false, message: T("无法启动授权对话框：%@", describe(error)))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            return AdminRunResult(succeeded: true, message: output)
        }
        if output.contains("User canceled") || output.contains("-128") {
            return AdminRunResult(succeeded: false, message: T("已取消管理员授权，插件仍在原位置，没有改动。"))
        }
        return AdminRunResult(succeeded: false, message: output.isEmpty ? T("管理员命令执行失败") : output)
    }

    // MARK: - Scan

    func scan() {
        isScanning = true

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                PluginScanner().scan()
            }.value

            await MainActor.run { [weak self] in
                self?.applyScanReport(report)
                self?.isScanning = false
            }
        }
    }

    /// 命令行用：等扫描真正结束再返回
    @discardableResult
    func scanNow() async -> [PluginItem] {
        let report = await Task.detached(priority: .userInitiated) {
            PluginScanner().scan()
        }.value
        applyScanReport(report)
        return plugins
    }

    private func applyScanReport(_ report: ScanReport) {
        var items = report.items
        items.sort {
            if $0.isSystemLevel != $1.isSystemLevel {
                return !$0.isSystemLevel && $1.isSystemLevel
            }
            if $0.category != $1.category {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.displayName < $1.displayName
        }
        plugins = items
        scanLocations = report.locations
        selectedPluginIDs.removeAll()
        // 系统级的 sudo 命令可能在应用外执行过，扫描后按磁盘实际情况更新台账
        refreshRenameLedgerStatuses()
    }

    // MARK: - Paths

    var storageRoot: URL {
        if let storageRootOverride { return storageRootOverride }
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return supportDir.appendingPathComponent("FCPPluginManager", isDirectory: true)
    }

    func ensureDirectory(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    var backupDirectory: URL {
        ensureDirectory(storageRoot.appendingPathComponent("Backups", isDirectory: true))
    }

    var disabledDirectory: URL {
        ensureDirectory(storageRoot.appendingPathComponent("Disabled", isDirectory: true))
    }

    private var operationsFile: URL {
        ensureDirectory(storageRoot.appendingPathComponent("Operations", isDirectory: true))
            .appendingPathComponent("log.json")
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    /// 同名已存在时追加 -2、-3…，绝不覆盖或删除已有目录
    private func uniqueURL(in directory: URL, baseName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    // MARK: - Backup

    func backupPlugin(_ plugin: PluginItem, date: Date = Date()) async -> BackupResult {
        guard fm.fileExists(atPath: plugin.path) else {
            return .failure(T("插件路径不存在：%@", plugin.path))
        }

        let baseName = "\(plugin.name)_\(Self.backupDateFormatter.string(from: date))"
        let backupURL = uniqueURL(in: backupDirectory, baseName: baseName)

        // 复制放后台线程，插件可能有几十 G，不能卡住界面
        let sourcePath = plugin.path
        let copyResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: sourcePath),
                    to: backupURL
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch copyResult {
        case .failure(let error):
            // 只清理本次复制出来的半成品，旧备份不受影响
            try? fm.removeItem(at: backupURL)
            return .failure(Self.describe(error))
        case .success:
            break
        }

        let backup = BackupItem(
            name: plugin.name,
            backupPath: backupURL.path,
            originalPath: plugin.path,
            category: plugin.category,
            isSystemLevel: plugin.isSystemLevel
        )

        do {
            try writeMetadata(for: backup, date: date)
        } catch {
            // 没有 .metadata 就无法恢复，按备份失败处理
            try? fm.removeItem(at: backupURL)
            return .failure(T("写入备份信息失败：%@", Self.describe(error)))
        }

        return .success(backup)
    }

    /// 先备份成功、再移入废纸篓；备份失败一律不删除
    func backupAndRecycle(_ plugin: PluginItem) async -> PluginDeleteResult {
        switch await backupPlugin(plugin) {
        case .failure(let message):
            return .backupFailed(message)
        case .success(let backup):
            backups.append(backup)
            switch await PluginService.recycle(plugin.path) {
            case .success:
                return .deleted(backup)
            case .needAuthentication:
                return .needAuthentication(backup)
            case .failure(let message):
                return .trashFailed(Self.describe(message))
            }
        }
    }

    func restoreTargetExists(for backup: BackupItem) -> Bool {
        guard !backup.originalPath.isEmpty else { return false }
        return fm.fileExists(atPath: backup.originalPath)
    }

    func restoreBackup(_ backup: BackupItem, overwriteExisting: Bool = false) async -> RestoreResult {
        guard fm.fileExists(atPath: backup.backupPath) else {
            return .failure(T("备份文件不存在：%@", backup.backupPath))
        }
        guard !backup.originalPath.isEmpty else {
            return .failure(T("备份缺少原始位置信息，无法恢复"))
        }

        let originalURL = URL(fileURLWithPath: backup.originalPath)
        let parentDir = originalURL.deletingLastPathComponent()
        var targetExistedBefore = fm.fileExists(atPath: originalURL.path)

        do {
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if targetExistedBefore {
                guard overwriteExisting else { return .targetExists }
                // 已存在的插件不直接删掉，走废纸篓，用户还能找回
                switch await PluginService.recycle(originalURL.path) {
                case .success:
                    targetExistedBefore = false
                case .needAuthentication:
                    return .needAuthentication(T("当前位置的插件需要管理员密码才能移入废纸篓"))
                case .failure(let message):
                    return .failure(T("无法移走已存在的插件：%@", message))
                }
            }
            // 复制放后台线程，避免恢复大插件时界面失去响应
            let backupPath = backup.backupPath
            let restoreResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.copyItem(
                        at: URL(fileURLWithPath: backupPath),
                        to: originalURL
                    )
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            if case .failure(let error) = restoreResult {
                throw error
            }
            do {
                try fm.removeItem(at: URL(fileURLWithPath: backup.backupPath))
            } catch {
                // 恢复已经成功，只是备份没清掉；提示但不当作失败
                return .successWithWarning(T("已恢复，但旧备份未能删除：%@", Self.describe(error)))
            }
            return .success
        } catch {
            // 只清理本次复制留下的半成品，备份本身不动
            if !targetExistedBefore, fm.fileExists(atPath: originalURL.path) {
                try? fm.removeItem(at: originalURL)
            }
            let reason = Self.describe(error)
            if backup.isSystemLevel && Self.isPermissionError(error) {
                return .needAuthentication(reason)
            }
            return .failure(reason)
        }
    }

    /// 把 NSError 的域和错误码一起带上，排障时能看出到底是哪种失败
    nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
    }

    nonisolated static func describe(_ message: String) -> String {
        message.isEmpty ? T("未知错误") : message
    }

    /// 只有「没权限写」才算需要管理员密码，其它错误照实返回
    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EACCES) || ns.code == Int(EPERM)
        }
        if ns.domain == NSCocoaErrorDomain {
            // NSFileReadNoPermission / NSFileWriteNoPermission / 只读卷
            return [257, 513, 642].contains(ns.code)
        }
        return false
    }

    func deleteBackup(_ backup: BackupItem) async -> TrashResult {
        await PluginService.recycle(backup.backupPath)
    }

    private func writeMetadata(for backup: BackupItem, date: Date) throws {
        let metaURL = URL(fileURLWithPath: backup.backupPath).appendingPathComponent(".metadata")
        let meta: [String: String] = [
            "originalPath": backup.originalPath,
            "category": backup.category.rawValue,
            "isSystemLevel": backup.isSystemLevel ? "true" : "false",
            "backupDate": ISO8601DateFormatter().string(from: date)
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: metaURL)
    }

    func loadBackups() {
        guard fm.fileExists(atPath: backupDirectory.path) else { return }

        var items: [BackupItem] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for entryURL in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDir),
                  isDir.boolValue,
                  !entryURL.lastPathComponent.hasPrefix(".") else { continue }

            let metaURL = entryURL.appendingPathComponent(".metadata")
            var category: PluginCategory = .all
            var originalPath = ""
            var isSystemLevel = false

            if let meta = try? String(contentsOf: metaURL, encoding: .utf8),
               let data = meta.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                originalPath = json["originalPath"] ?? ""
                if let catRaw = json["category"] {
                    category = PluginCategory(rawValue: catRaw) ?? .all
                }
                isSystemLevel = (json["isSystemLevel"] == "true")
            } else {
                originalPath = ""
            }

            let displayName: String
            if !originalPath.isEmpty {
                displayName = URL(fileURLWithPath: originalPath).lastPathComponent
            } else {
                displayName = entryURL.lastPathComponent
            }

            let backup = BackupItem(
                name: displayName,
                backupPath: entryURL.path,
                originalPath: originalPath,
                category: category,
                isSystemLevel: isSystemLevel
            )
            items.append(backup)
        }

        items.sort { $0.name < $1.name }
        self.backups = items
    }

    // MARK: - Disable / Enable

    func disablePlugin(_ plugin: PluginItem, date: Date = Date()) async -> DisableResult {
        guard fm.fileExists(atPath: plugin.path) else {
            return .failure(T("插件路径不存在：%@", plugin.path))
        }

        let baseName = "\(plugin.name)_\(Self.backupDateFormatter.string(from: date))"
        let entryURL = uniqueURL(in: disabledDirectory, baseName: baseName)
        let payloadURL = entryURL.appendingPathComponent("Plugin", isDirectory: true)

        do {
            try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
            if !plugin.isSystemLevel {
                // 用户级：直接移走，立即生效
                let source = plugin.path
                let destination = payloadURL
                let moveResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        try FileManager.default.moveItem(
                            at: URL(fileURLWithPath: source),
                            to: destination
                        )
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value
                if case .failure(let error) = moveResult {
                    throw error
                }
            }
            // 系统级：这里不复制（插件可能有几十 G），先建记录，
            // 随后由 applyPendingDisables 用一次管理员授权把原文件移进来。
        } catch {
            try? fm.removeItem(at: entryURL)
            return .failure(Self.describe(error))
        }

        let item = DisabledItem(
            name: plugin.name,
            currentPath: payloadURL.path,
            entryPath: entryURL.path,
            originalPath: plugin.path,
            category: plugin.category,
            isSystemLevel: plugin.isSystemLevel,
            disabledDate: date
        )

        do {
            try writeDisabledMetadata(item)
        } catch {
            // 没有元数据就无法启用回来，把插件放回原处
            if plugin.isSystemLevel {
                try? fm.removeItem(at: entryURL)
            } else {
                try? fm.moveItem(at: payloadURL, to: URL(fileURLWithPath: plugin.path))
            }
            return .failure(T("写入禁用信息失败：%@", Self.describe(error)))
        }

        disabledItems.append(item)
        disabledItems.sort { $0.name < $1.name }

        if plugin.isSystemLevel {
            return .needAuthentication(item, T("系统级插件需要管理员授权，才能把原文件移出系统目录"))
        }
        return .disabled(item)
    }

    func enableDisabled(_ item: DisabledItem, overwriteExisting: Bool = false) async -> RestoreResult {
        let payloadExists = item.hasPayload
        let originalExists = item.originalExists

        // 原位置还在 → 这条禁用从来没有生效过（旧版本只复制了一份，或者后来又装回来了）。
        // 插件本身一直在用，这里只把多余的副本/记录移到废纸篓，绝不碰原位置。
        if originalExists {
            switch await PluginService.recycle(item.entryPath) {
            case .success:
                disabledItems.removeAll { $0.entryPath == item.entryPath }
                return payloadExists
                    ? .successWithWarning(T("原插件本来就在原位，已把多余的副本移到废纸篓（可还原）"))
                    : .success
            case .needAuthentication:
                return .needAuthentication(T("清掉多余的禁用记录需要管理员权限"))
            case .failure(let message):
                return .failure(T("清掉多余记录失败：%@", message))
            }
        }

        guard payloadExists else {
            return .failure(T("禁用目录和原位置都找不到这个插件：%@", item.originalPath))
        }

        guard !item.originalPath.isEmpty else {
            return .failure(T("禁用记录缺少原始位置信息，无法启用"))
        }

        // 系统级插件要写回 /Library，只能走管理员授权
        if item.isSystemLevel {
            if originalExists { return .targetExists }
            return .needAuthentication(T("系统级插件需要管理员授权才能放回系统目录"))
        }

        let originalURL = URL(fileURLWithPath: item.originalPath)
        let parentDir = originalURL.deletingLastPathComponent()
        var targetExistedBefore = originalExists

        do {
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if targetExistedBefore {
                guard overwriteExisting else { return .targetExists }
                switch await PluginService.recycle(originalURL.path) {
                case .success:
                    targetExistedBefore = false
                case .needAuthentication:
                    return .needAuthentication(T("当前位置的插件需要管理员密码才能移入废纸篓"))
                case .failure(let message):
                    return .failure(T("无法移走已存在的插件：%@", message))
                }
            }
            // 移动放后台线程，避免大插件卡住界面
            let source = item.currentPath
            let destination = originalURL
            let moveResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.moveItem(
                        at: URL(fileURLWithPath: source),
                        to: destination
                    )
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            if case .failure(let error) = moveResult {
                throw error
            }
        } catch {
            if !targetExistedBefore, fm.fileExists(atPath: originalURL.path) {
                try? fm.removeItem(at: originalURL)
            }
            let reason = Self.describe(error)
            if item.isSystemLevel && Self.isPermissionError(error) {
                return .needAuthentication(reason)
            }
            return .failure(reason)
        }

        do {
            try fm.removeItem(at: URL(fileURLWithPath: item.entryPath))
        } catch {
            return .successWithWarning(T("已启用，但禁用记录里残留文件未能删除：%@", Self.describe(error)))
        }
        disabledItems.removeAll { $0.entryPath == item.entryPath }
        return .success
    }

    // MARK: - 重命名

    /// 改名前的校验。返回 nil 表示可以改，否则返回给用户看的原因。
    func validateNewName(_ rawName: String, for plugin: PluginItem) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return T("名字不能为空。") }
        if name.contains("/") { return T("名字里不能有「/」。") }
        if name.contains(":") { return T("名字里不能有「:」。") }
        if name == "." || name == ".." { return T("这个名字不合法。") }
        if name.count > 255 { return T("名字太长，最多 255 个字符。") }
        if name == plugin.name { return T("和原来的名字一样，不需要改。") }

        let target = URL(fileURLWithPath: plugin.path)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) {
            return T("同目录下已经有叫「%@」的插件，不能覆盖。", name)
        }
        return nil
    }

    /// 改真实文件夹名。FCP 菜单读的就是文件夹名，改完重扫即可看到新名字。
    func renamePlugin(_ plugin: PluginItem, to rawName: String) async -> RenameResult {
        if let error = validateNewName(rawName, for: plugin) {
            return .failure(error)
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldURL = URL(fileURLWithPath: plugin.path)
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name)

        if plugin.isSystemLevel {
            // 系统级不能静默改，但先把台账记成「待执行」，执行完刷新会自动转成已生效
            recordRenameInLedger(
                oldPath: plugin.path,
                newPath: newURL.path,
                category: plugin.category,
                isSystemLevel: true,
                status: .renamePending
            )
            return .needAuthentication(
                oldPath: plugin.path,
                newPath: newURL.path,
                reason: T("系统级插件在 /Library 下，需要管理员权限才能改文件夹名")
            )
        }

        let source = plugin.path
        let moveResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: source),
                    to: newURL
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch moveResult {
        case .failure(let error):
            // moveItem 是单步操作，失败时原目录不动，不会留下半个状态
            return .failure(T("改名失败：%@", Self.describe(error)))
        case .success:
            let updated = updateBackupOriginalPaths(from: plugin.path, to: newURL.path)
            recordRenameInLedger(
                oldPath: plugin.path,
                newPath: newURL.path,
                category: plugin.category,
                isSystemLevel: false,
                status: .applied
            )
            return .success(oldPath: plugin.path, newPath: newURL.path, updatedBackups: updated)
        }
    }

    /// 改名后同步更新备份记录里的 originalPath，否则旧备份会恢复不回去。
    /// 返回成功更新的备份数量。
    @discardableResult
    func updateBackupOriginalPaths(from oldPath: String, to newPath: String) -> Int {
        // 以磁盘上的元数据为准，避免只调过 backupPlugin、列表还没刷新的情况
        loadBackups()
        var updated = 0
        for backup in backups {
            guard backup.originalPath == oldPath || backup.originalPath.hasPrefix(oldPath + "/") else {
                continue
            }
            let suffix = String(backup.originalPath.dropFirst(oldPath.count))
            if rewriteBackupMetadata(backup, originalPath: newPath + suffix) {
                updated += 1
            }
        }
        if updated > 0 {
            loadBackups()
        }
        return updated
    }

    private func rewriteBackupMetadata(_ backup: BackupItem, originalPath: String) -> Bool {
        let metaURL = URL(fileURLWithPath: backup.backupPath).appendingPathComponent(".metadata")
        guard let raw = try? Data(contentsOf: metaURL),
              var json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: String] else {
            return false
        }
        json["originalPath"] = originalPath
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        return (try? data.write(to: metaURL)) != nil
    }

    /// 撤销改名：把文件夹名改回去
    func renameBack(_ snapshot: RenameSnapshot) async -> RestoreResult {
        guard fm.fileExists(atPath: snapshot.newPath) else {
            return .failure(T("找不到改名后的插件：%@", snapshot.newPath))
        }
        guard !fm.fileExists(atPath: snapshot.oldPath) else {
            return .targetExists
        }
        let source = snapshot.newPath
        let target = URL(fileURLWithPath: snapshot.oldPath)
        let moveResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: source),
                    to: target
                )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch moveResult {
        case .failure(let error):
            return .failure(T("撤销改名失败：%@", Self.describe(error)))
        case .success:
            updateBackupOriginalPaths(from: snapshot.newPath, to: snapshot.oldPath)
            markRenameLedgerRestored(oldPath: snapshot.oldPath, newPath: snapshot.newPath)
            return .success
        }
    }

    func deleteDisabled(_ item: DisabledItem) async -> TrashResult {
        await PluginService.recycle(item.entryPath)
    }

    // MARK: - 批量禁用 / 启用

    /// 批量禁用：一次传进来的插件按同一个范围处理，系统级单独归到 adminItems
    func disableAll(_ plugins: [PluginItem]) async -> BulkDisableOutcome {
        var outcome = BulkDisableOutcome()
        beginBatch(T("正在停用 %lld 个插件", plugins.count), total: plugins.count)
        defer { endBatch() }
        for plugin in plugins {
            switch await disablePlugin(plugin) {
            case .disabled(let item):
                outcome.disabledNames.append(item.displayName)
                outcome.disabledItems.append(item)
            case .needAuthentication(let item, let reason):
                outcome.adminItems.append(item)
                outcome.adminReasons[item.entryPath] = reason
            case .failure(let message):
                outcome.failures.append("\(plugin.displayName)：\(message)")
            }
            if !advanceBatch() { break }
        }
        return outcome
    }

    /// 批量启用：真正停用的按原样放回；从没停用过的（原文件还在）只清重复记录
    func enableAllDisabled(_ items: [DisabledItem]) async -> BulkEnableOutcome {
        var outcome = BulkEnableOutcome()
        beginBatch(T("正在启用 %lld 个插件", items.count), total: items.count)
        defer { endBatch() }
        for item in items {
            switch await enableDisabled(item) {
            case .success, .successWithWarning:
                outcome.enabledNames.append(item.displayName)
            case .targetExists:
                outcome.failures.append(T("%@：原始位置已存在", item.displayName))
            case .needAuthentication(let reason):
                outcome.adminItems.append(item)
                outcome.adminReasons[item.entryPath] = reason
            case .failure(let message):
                outcome.failures.append("\(item.displayName)：\(message)")
            }
            if !advanceBatch() { break }
        }
        return outcome
    }

    // MARK: - 批量进度

    func beginBatch(_ title: String, total: Int) {
        batchStopRequested = false
        batchProgress = BatchProgress(title: title, completed: 0, total: total)
    }

    /// 走完一项后调用；返回 false 表示用户点了「停止」，调用方应跳出循环
    @discardableResult
    func advanceBatch() -> Bool {
        guard batchProgress != nil else { return true }
        batchProgress?.completed += 1
        return !batchStopRequested
    }

    func endBatch() {
        batchProgress = nil
        batchStopRequested = false
    }

    func requestBatchStop() {
        batchStopRequested = true
        batchProgress?.isCancelling = true
    }

    // MARK: - 管理员批量执行

    /// 用一次管理员授权，把所有「待执行」的系统级禁用记录真正移走。
    func applyPendingDisables(_ items: [DisabledItem]) async -> AdminApplyOutcome {
        let targets = items.filter { !$0.isEffective }
        var outcome = AdminApplyOutcome()
        outcome.attemptedCount = targets.count
        guard !targets.isEmpty else {
            outcome.message = T("没有待执行的插件。")
            return outcome
        }

        let script = AdminCommandBuilder.disableScript(for: targets)
        let result = await runAdmin(script)
        outcome.message = result.message
        outcome.wasCancelled = !result.succeeded

        loadDisabled()
        let stillPending = disabledItems.filter { $0.isEffective == false }
        outcome.succeededCount = targets.count - stillPending.filter { target in
            targets.contains { $0.entryPath == target.entryPath }
        }.count
        outcome.stillPendingNames = stillPending.map(\.displayName)
        return outcome
    }

    /// 用一次管理员授权，把所有真正停用的系统级插件放回原目录。
    func applyPendingEnables(_ items: [DisabledItem]) async -> AdminApplyOutcome {
        let targets = items.filter { $0.isSystemLevel && $0.hasPayload && !$0.originalExists }
        var outcome = AdminApplyOutcome()
        outcome.attemptedCount = targets.count
        guard !targets.isEmpty else {
            outcome.message = T("没有需要管理员权限恢复的插件。")
            return outcome
        }

        let script = AdminCommandBuilder.enableScript(for: targets)
        let result = await runAdmin(script)
        outcome.message = result.message
        outcome.wasCancelled = !result.succeeded

        loadDisabled()
        let remaining = disabledItems.filter { item in
            targets.contains { $0.entryPath == item.entryPath }
        }
        outcome.succeededCount = targets.count - remaining.count
        outcome.stillPendingNames = remaining.map(\.displayName)
        return outcome
    }

    private func runAdmin(_ script: String) async -> AdminRunResult {
        let runner = adminRunner
        return await Task.detached(priority: .userInitiated) {
            runner(script)
        }.value
    }

    /// 复核：重新读禁用目录并重扫插件，UI 上「已生效 / 未生效」立刻跟着变
    func refreshDisabledState() {
        loadDisabled()
        scan()
    }

    func manualDisableCommands(for items: [DisabledItem]) -> String {
        AdminCommandBuilder.manualDisableCommands(for: items)
    }

    func manualEnableCommands(for items: [DisabledItem]) -> String {
        AdminCommandBuilder.manualEnableCommands(for: items)
    }

    private func writeDisabledMetadata(_ item: DisabledItem) throws {
        let metaURL = URL(fileURLWithPath: item.entryPath).appendingPathComponent(".metadata")
        let meta: [String: String] = [
            "originalPath": item.originalPath,
            "category": item.category.rawValue,
            "isSystemLevel": item.isSystemLevel ? "true" : "false",
            "disabledDate": ISO8601DateFormatter().string(from: item.disabledDate ?? Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: meta)
        try data.write(to: metaURL)
    }

    func loadDisabled() {
        guard fm.fileExists(atPath: disabledDirectory.path) else { return }

        var items: [DisabledItem] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: disabledDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for entryURL in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDir),
                  isDir.boolValue,
                  !entryURL.lastPathComponent.hasPrefix(".") else { continue }

            let payloadURL = entryURL.appendingPathComponent("Plugin", isDirectory: true)
            let metaURL = entryURL.appendingPathComponent(".metadata")
            let hasPayload = fm.fileExists(atPath: payloadURL.path)
            // 系统级插件在授权前只有记录、没有本体（原文件还在系统目录），
            // 这类「待执行」记录也要保留，否则用户会以为已经停用了。
            guard hasPayload || fm.fileExists(atPath: metaURL.path) else { continue }

            var originalPath = ""
            var category: PluginCategory = .all
            var isSystemLevel = false
            var disabledDate: Date?

            if let meta = try? String(contentsOf: metaURL, encoding: .utf8),
               let data = meta.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                originalPath = json["originalPath"] ?? ""
                category = PluginCategory(rawValue: json["category"] ?? "") ?? .all
                isSystemLevel = (json["isSystemLevel"] == "true")
                if let raw = json["disabledDate"] {
                    disabledDate = ISO8601DateFormatter().date(from: raw)
                }
            }

            let name = originalPath.isEmpty
                ? entryURL.lastPathComponent
                : URL(fileURLWithPath: originalPath).lastPathComponent

            items.append(
                DisabledItem(
                    name: name,
                    currentPath: payloadURL.path,
                    entryPath: entryURL.path,
                    originalPath: originalPath,
                    category: category,
                    isSystemLevel: isSystemLevel,
                    disabledDate: disabledDate
                )
            )
        }

        items.sort { $0.name < $1.name }
        self.disabledItems = items
    }

    // MARK: - Operation Log

    var lastUndoableOperation: OperationRecord? {
        operations.last { $0.isUndoable }
    }

    func addOperation(
        kind: OperationKind,
        summary: String,
        backups: [BackupItem] = [],
        disabled: [DisabledItem] = [],
        renames: [RenameSnapshot] = []
    ) {
        let record = OperationRecord(
            id: UUID(),
            date: Date(),
            kind: kind,
            summary: summary,
            backups: backups.map(BackupSnapshot.init),
            disabled: disabled.map(DisabledSnapshot.init),
            renames: renames.isEmpty ? nil : renames,
            undone: false
        )
        operations.append(record)
        if operations.count > 100 {
            operations.removeFirst(operations.count - 100)
        }
        saveOperations()
    }

    func undo(_ record: OperationRecord) async -> UndoOutcome {
        var outcome = UndoOutcome()

        for snapshot in record.backups {
            let backup = snapshot.backupItem
            switch await restoreBackup(backup) {
            case .success, .successWithWarning:
                outcome.restoredCount += 1
                backups.removeAll { $0.backupPath == backup.backupPath }
            case .targetExists:
                outcome.failures.append(T("%@：原始位置已有同名插件，未覆盖", backup.displayName))
            case .needAuthentication(let reason):
                outcome.needsAuth.append("\(backup.displayName)：\(reason)")
            case .failure(let message):
                outcome.failures.append("\(backup.displayName)：\(message)")
            }
        }

        for snapshot in record.disabled {
            let item = snapshot.disabledItem
            switch await enableDisabled(item) {
            case .success, .successWithWarning:
                outcome.restoredCount += 1
            case .targetExists:
                outcome.failures.append(T("%@：原始位置已有同名插件，未覆盖", item.displayName))
            case .needAuthentication(let reason):
                outcome.needsAuth.append("\(item.displayName)：\(reason)")
            case .failure(let message):
                outcome.failures.append("\(item.displayName)：\(message)")
            }
        }

        for snapshot in record.renames ?? [] {
            let name = URL(fileURLWithPath: snapshot.oldPath).lastPathComponent
            switch await renameBack(snapshot) {
            case .success, .successWithWarning:
                outcome.restoredCount += 1
            case .targetExists:
                outcome.failures.append(T("%@：原名位置已经有同名插件，未覆盖", name))
            case .needAuthentication(let reason):
                outcome.needsAuth.append("\(name)：\(reason)")
            case .failure(let message):
                outcome.failures.append("\(name)：\(message)")
            }
        }

        if outcome.isComplete, let index = operations.firstIndex(where: { $0.id == record.id }) {
            operations[index].undone = true
            saveOperations()
        }
        return outcome
    }

    private func saveOperations() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(operations)
            try data.write(to: operationsFile)
        } catch {
            // 日志写不进去不影响主流程，只是下次打开看不到历史记录
        }
    }

    private func loadOperations() {
        guard let data = try? Data(contentsOf: operationsFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([OperationRecord].self, from: data) else { return }
        operations = records
    }
}

enum BackupResult {
    case success(BackupItem)
    case failure(String)
}

enum RestoreResult {
    case success
    /// 恢复成功，但备份副本没清掉，附带提示
    case successWithWarning(String)
    case targetExists
    /// 真正因为没权限才需要管理员密码，附带真实原因
    case needAuthentication(String)
    case failure(String)
}

enum PluginDeleteResult {
    case deleted(BackupItem)
    case backupFailed(String)
    case needAuthentication(BackupItem)
    case trashFailed(String)
}

enum DisableResult {
    case disabled(DisabledItem)
    /// 已建好禁用记录，但原位置还需要管理员权限移走
    case needAuthentication(DisabledItem, String)
    case failure(String)
}

enum RenameResult {
    case success(oldPath: String, newPath: String, updatedBackups: Int)
    case needAuthentication(oldPath: String, newPath: String, reason: String)
    case failure(String)
}

struct BulkDisableOutcome {
    var disabledNames: [String] = []
    var disabledItems: [DisabledItem] = []
    var adminItems: [DisabledItem] = []
    var adminReasons: [String: String] = [:]
    var failures: [String] = []
}

struct BulkEnableOutcome {
    var enabledNames: [String] = []
    var adminItems: [DisabledItem] = []
    var adminReasons: [String: String] = [:]
    var failures: [String] = []
}

// MARK: - Plugin Service (trash / delete)

struct PluginService {
    /// 走系统回收站 API：由 Finder 生成「放回原处」所需的元数据，
    /// 重名时系统自己处理，不会覆盖废纸篓里已有的同名项目。
    static func recycle(_ path: String) async -> TrashResult {
        if path.hasPrefix("/Library/") { return .needAuthentication }

        let url = URL(fileURLWithPath: path)
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                } else {
                    continuation.resume(returning: .success)
                }
            }
        }
    }
}

enum TrashResult {
    case success
    case needAuthentication
    case failure(String)
}
