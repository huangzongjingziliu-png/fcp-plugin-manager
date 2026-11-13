import Foundation

// MARK: - 工程扫描

/// 一次工程扫描的结果。
/// `parsed == false` 表示这份工程没解析出任何效果引用，界面必须明确提示，不能拿空清单当「全都没用」。
struct ProjectScanResult: Identifiable {
    let id = UUID()
    let fileURL: URL
    let projectName: String
    /// 工程里出现的效果引用条数（去重前）
    var referenceCount: Int
    /// 本工程实际用到、并且本机已安装的插件路径
    var usedPaths: Set<String> = []
    /// 用到但本机找不到对应插件的引用（uid 或名字），用来提示风险
    var unmatched: [String] = []
    /// 解析失败或需要用户导出 XML 时的说明
    var warning: String?
    /// 直接读 .fcpbundle 时的完整库结构；XML 扫描为 nil
    var bundle: FCPBundleScanResult?

    var parsed: Bool { referenceCount > 0 && warning == nil }
}

enum ProjectScanError: LocalizedError {
    case unsupportedType(String)
    case unreadable(String)
    case needsExport

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return T("不支持的文件类型：%@。请选择 .fcpxml 或 .fcpbundle。", ext)
        case .unreadable(let name):
            return T("读不出「%@」的内容。请确认文件没有损坏，或在 Final Cut Pro 里重新导出 XML。", name)
        case .needsExport:
            return T("这个 .fcpbundle 里没有可直接读取的 XML。请在 Final Cut Pro 里打开该工程，用「文件 → 导出 XML」导出 .fcpxml，再拖进来扫描。")
        }
    }
}

/// 从工程文件里抽出的效果引用
struct FCPProjectReferences {
    /// 原始 uid（已做百分号解码）
    var uids: Set<String> = []
    /// <effect> 的显示名
    var names: Set<String> = []
    /// 解析时读到的工程名
    var projectName: String?

    var count: Int { uids.count + names.count }
    var isEmpty: Bool { uids.isEmpty && names.isEmpty }

    mutating func formUnion(_ other: FCPProjectReferences) {
        uids.formUnion(other.uids)
        names.formUnion(other.names)
    }
}

// MARK: - XML 解析

/// 解析 FCPXML。只做一件事：把 `uid` 属性和 `<effect>` 的 `name` 收集出来。
/// 不尝试还原时间线结构，因为判断「用没用到某个插件」只需要引用，不需要剪辑细节。
final class FCPXMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var references = FCPProjectReferences()
    private var foundProjectName = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if let uid = attributeDict["uid"], !uid.isEmpty {
            let decoded = uid.removingPercentEncoding ?? uid
            references.uids.insert(decoded)
        }
        if elementName == "effect", let name = attributeDict["name"], !name.isEmpty {
            references.names.insert(name)
        }
        if !foundProjectName, elementName == "project", let name = attributeDict["name"], !name.isEmpty {
            references.projectName = name
            foundProjectName = true
        }
    }
}

enum FCPProjectScanner {
    /// 解析一个 .fcpxml 或 .fcpbundle（目录）
    static func scan(url: URL) throws -> (references: FCPProjectReferences, sourceDescription: String) {
        let ext = url.pathExtension.lowercased()

        if ext == "fcpxml" {
            return (try parseXML(at: url), url.lastPathComponent)
        }

        if ext == "fcpbundle" {
            // 包里可能有导出的 XML，先尽力找；找不到就明确要求用户导出，绝不猜
            guard let embedded = findEmbeddedXML(in: url) else {
                throw ProjectScanError.needsExport
            }
            let refs = try parseXML(at: embedded)
            return (refs, embedded.lastPathComponent)
        }

        throw ProjectScanError.unsupportedType(ext.isEmpty ? T("无扩展名") : ext)
    }

    private static func parseXML(at url: URL) throws -> FCPProjectReferences {
        // 用流式解析，几百 MB 的工程也不会一次性读进内存
        guard let stream = InputStream(url: url) else {
            throw ProjectScanError.unreadable(url.lastPathComponent)
        }
        stream.open()
        defer { stream.close() }

        let parser = XMLParser(stream: stream)
        let delegate = FCPXMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ProjectScanError.unreadable(url.lastPathComponent)
        }
        return delegate.references
    }

    /// 在 .fcpbundle 里找 *.fcpxml（最多 4 层，够用又不至于扫太深）
    private static func findEmbeddedXML(in bundle: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if enumerator.level > 4 { enumerator.skipDescendants() }
            if fileURL.pathExtension.lowercased() == "fcpxml" {
                return fileURL
            }
        }
        return nil
    }
}

// MARK: - 匹配

enum PluginMatcher {
    private static let strippableExtensions: Set<String> = [
        "localized", "motr", "moti", "moef", "plugin", "fxplug", "app", "component", "bundle"
    ]

    /// 把 uid 或名字归一化：解码、小写、逐段去掉已知扩展名
    static func normalize(_ raw: String) -> String {
        var text = (raw.removingPercentEncoding ?? raw).lowercased()
        text = text.replacingOccurrences(of: "\\", with: "/")
        let segments = text
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                var value = String(segment)
                while true {
                    let ext = (value as NSString).pathExtension
                    guard !ext.isEmpty, strippableExtensions.contains(ext) else { break }
                    value = (value as NSString).deletingPathExtension
                }
                return value
            }
        return segments.joined(separator: "/")
    }

    static func lastComponent(_ raw: String) -> String {
        let normalized = normalize(raw)
        return (normalized as NSString).lastPathComponent
    }

    /// 判断一个已安装插件是否被工程引用。
    /// 判定顺序：路径包含 → 包标识 → 目录/文件名一致。任何一条命中就算用到（宁可多保护，不乱禁用）。
    static func isUsed(_ plugin: PluginItem, references: FCPProjectReferences) -> Bool {
        let pluginPath = normalize(plugin.path)
        let pluginName = normalize(plugin.name)
        guard !pluginName.isEmpty else { return false }
        let bundleID = plugin.bundleIdentifier?.lowercased()

        for uid in references.uids.map(normalize) {
            if uid.contains(pluginPath) { return true }
            if uid.hasSuffix("/" + pluginName) { return true }
            if lastComponent(uid) == pluginName { return true }
            // 库内 effectID 常写成 ~/Titles.localized/<插件目录>/<效果>.moti，
            // 没有绝对路径前缀，这里按路径段比对插件目录名。
            if uid.split(separator: "/").contains(where: { $0 == pluginName }) { return true }
            if let bundleID, !bundleID.isEmpty, uid.contains(bundleID) { return true }
        }

        for name in references.names {
            if normalize(name) == pluginName { return true }
        }
        return false
    }

    /// 找出工程引用里，本机装了但名字对不上的那些（用于提示「可能还有没匹配上的」）
    static func unmatchedReferences(_ references: FCPProjectReferences, plugins: [PluginItem]) -> [String] {
        var unmatched: [String] = []
        for uid in references.uids {
            let used = plugins.contains { isUsed($0, references: FCPProjectReferences(uids: [uid], names: [])) }
            if !used {
                unmatched.append(lastComponent(uid))
            }
        }
        return Array(Set(unmatched)).sorted()
    }
}

// MARK: - 保护名单与工程扫描（数据层）

/// 收藏 + 工程保护名单，存在应用自己的目录里，跨启动保留
private struct StoredProtection: Codable {
    var favorites: [String] = []
    var projectProtected: [String] = []
    var projectName: String?
    var updatedAt: Date?
}

@MainActor
extension PluginViewModel {
    private var protectionFile: URL {
        storageRoot
            .appendingPathComponent("Protection", isDirectory: true)
            .appendingPathComponent("protection.json")
    }

    // MARK: 读写

    func loadProtection() {
        guard let data = try? Data(contentsOf: protectionFile),
              let stored = try? JSONDecoder().decode(StoredProtection.self, from: data) else {
            return
        }
        favorites = Set(stored.favorites)
        projectProtectedPaths = Set(stored.projectProtected)
    }

    private func saveProtection(projectName: String? = nil) {
        _ = ensureDirectory(protectionFile.deletingLastPathComponent())
        let stored = StoredProtection(
            favorites: favorites.sorted(),
            projectProtected: projectProtectedPaths.sorted(),
            projectName: projectName ?? projectScan?.projectName,
            updatedAt: Date()
        )
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: protectionFile, options: .atomic)
        }
    }

    // MARK: 收藏

    func isFavorite(_ plugin: PluginItem) -> Bool { favorites.contains(plugin.path) }

    func isProjectProtected(_ plugin: PluginItem) -> Bool { projectProtectedPaths.contains(plugin.path) }

    /// 收藏和工程保护都算「受保护」，批量禁用一律跳过
    func isProtected(_ plugin: PluginItem) -> Bool {
        isFavorite(plugin) || isProjectProtected(plugin)
    }

    func toggleFavorite(_ plugin: PluginItem) {
        if favorites.contains(plugin.path) {
            favorites.remove(plugin.path)
        } else {
            favorites.insert(plugin.path)
        }
        saveProtection()
    }

    // MARK: 工程扫描

    func scanProject(at url: URL) async throws -> ProjectScanResult {
        // 真库：直接读 .fcpbundle，不再要求用户手动导出 XML
        if url.pathExtension.lowercased() == "fcpbundle", FCPBundleReader.isLibrary(url) {
            let bundle = try await Task.detached(priority: .userInitiated) {
                try FCPBundleReader.scan(url: url)
            }.value

            var result = ProjectScanResult(
                fileURL: url,
                projectName: bundle.libraryName,
                referenceCount: 0
            )
            result.bundle = bundle
            applyBundleSelection(to: &result)
            projectScan = result
            saveProtection(projectName: result.projectName)
            return result
        }

        let scanned = try await Task.detached(priority: .userInitiated) {
            try FCPProjectScanner.scan(url: url)
        }.value

        let references = scanned.references
        var result = ProjectScanResult(
            fileURL: url,
            projectName: references.projectName ?? url.deletingPathExtension().lastPathComponent,
            referenceCount: references.count
        )

        if references.isEmpty {
            result.warning = T("这份工程里没有读到任何效果引用，无法判断用到了哪些插件。请确认导出的是 FCPXML（文件 → 导出 XML），而不是只有媒体清单。")
            projectScan = result
            // 解析不出清单时不能沿用上一个工程的保护名单，否则会一直误保护
            projectProtectedPaths = []
            saveProtection(projectName: result.projectName)
            return result
        }

        let used = plugins.filter { PluginMatcher.isUsed($0, references: references) }
        result.usedPaths = Set(used.map(\.path))
        result.unmatched = Array(
            PluginMatcher.unmatchedReferences(references, plugins: plugins).prefix(12)
        )

        // 保护名单只跟随「当前扫描的工程」：被这个工程用到的自动保护，
        // 换一个工程后按新清单重算（收藏项不受影响）。
        projectProtectedPaths = result.usedPaths
        projectScan = result
        saveProtection(projectName: result.projectName)
        return result
    }

    func clearProjectScan() {
        projectScan = nil
        projectProtectedPaths.removeAll()
        saveProtection(projectName: "")
    }

    // MARK: 库扫描的选择

    /// 停用批次里显示的名字：「整库「库名」」或「工程「工程名」」
    var currentScanBatchName: String {
        guard let scan = projectScan else { return "" }
        if let bundle = scan.bundle { return bundle.selectionLabel }
        return scan.projectName
    }

    func setBundleWholeLibrary(_ whole: Bool) {
        guard var scan = projectScan, var bundle = scan.bundle else { return }
        bundle.wholeLibrary = whole
        if whole {
            bundle.selectedProjectIDs = Set(bundle.allProjects.map(\.id))
        }
        scan.bundle = bundle
        applyBundleSelection(to: &scan)
        projectScan = scan
        saveProtection(projectName: scan.projectName)
    }

    func toggleBundleProject(_ id: String) {
        guard var scan = projectScan, var bundle = scan.bundle else { return }
        // 从「整库」里点掉一个工程时，先展开成全部工程再取消这一个
        if bundle.wholeLibrary {
            bundle.wholeLibrary = false
            bundle.selectedProjectIDs = Set(bundle.allProjects.map(\.id))
        }
        if bundle.selectedProjectIDs.contains(id) {
            bundle.selectedProjectIDs.remove(id)
        } else {
            bundle.selectedProjectIDs.insert(id)
        }
        scan.bundle = bundle
        applyBundleSelection(to: &scan)
        projectScan = scan
        saveProtection(projectName: scan.projectName)
    }

    /// 按当前选择重算「用到 / 未使用」，并同步保护名单。
    /// 只要选中范围里有读不完整的工程，或一条引用都没有，就明确标记 warning，
    /// 界面据此禁用「停用未使用」，绝不输出猜测清单。
    private func applyBundleSelection(to result: inout ProjectScanResult) {
        guard let bundle = result.bundle else { return }
        let references = bundle.references(
            wholeLibrary: bundle.wholeLibrary,
            selected: bundle.selectedProjectIDs
        )
        let used = plugins.filter { PluginMatcher.isUsed($0, references: references) }
        result.usedPaths = Set(used.map(\.path))
        result.referenceCount = references.count
        result.unmatched = Array(
            PluginMatcher.unmatchedReferences(references, plugins: plugins).prefix(12)
        )

        if references.isEmpty {
            result.warning = T("选中的范围里没有读到任何效果引用，无法判断用到了哪些插件。为避免误停用，本次不提供停用操作。")
        } else if bundle.hasUnreadableSelection(
            wholeLibrary: bundle.wholeLibrary,
            selected: bundle.selectedProjectIDs
        ) {
            result.warning = T("选中的范围里有工程读不完整，无法判断它用到的插件。为避免误停用，请先检查这些工程，或改用 XML 导出。")
        } else {
            result.warning = nil
        }

        projectProtectedPaths = result.usedPaths
    }

    // MARK: 批量禁用的候选

    /// 统一在这里算「这次能停谁」：
    /// 只看来源——Apple 自带默认不碰，第三方和来源未知都要处理；
    /// 收藏和当前工程正在用的一律跳过。装在哪不影响是否参与。
    func batchDisableCandidates(
        in category: PluginCategory,
        includeApple: Bool = false
    ) -> (targets: [PluginItem], skippedApple: Int, skippedProtected: Int) {
        let scoped = category == .all ? plugins : plugins.filter { $0.category == category }
        var targets: [PluginItem] = []
        var skippedApple = 0
        var skippedProtected = 0

        for plugin in scoped {
            if isProtected(plugin) {
                skippedProtected += 1
                continue
            }
            if plugin.origin == .apple && !includeApple {
                skippedApple += 1
                continue
            }
            targets.append(plugin)
        }
        return (targets, skippedApple, skippedProtected)
    }

    /// 工程扫描里「没用到」的插件，同样只排除 Apple 自带与受保护项
    func projectUnusedCandidates(includeApple: Bool = false) -> [PluginItem] {
        guard let scan = projectScan, scan.parsed else { return [] }
        return plugins.filter { plugin in
            !scan.usedPaths.contains(plugin.path)
                && !isProtected(plugin)
                && (includeApple || plugin.origin != .apple)
        }
    }

    // MARK: 停用「未使用」（界面与命令行共用）

    struct ProjectDisableSummary {
        var disabled: [DisabledItem] = []
        /// 装在所有用户目录、需要一次管理员授权才真正生效的条目
        var adminPending: [DisabledItem] = []
        var failures: [String] = []
        var batch: ProjectBatch?
    }

    /// 停用当前扫描范围里没用到的插件，并记成同一套批次。
    /// 界面和 `fcpplugin --cli scan-project --yes` 都走这里，避免两边行为不一致。
    func disableProjectUnused() async -> ProjectDisableSummary {
        var summary = ProjectDisableSummary()
        guard projectScan != nil else { return summary }
        let targets = projectUnusedCandidates()
        guard !targets.isEmpty else { return summary }

        let batchName = currentScanBatchName
        let outcome = await disableAll(targets)
        summary.disabled = outcome.disabledItems
        summary.adminPending = outcome.adminItems
        summary.failures = outcome.failures

        if !outcome.disabledItems.isEmpty {
            addOperation(
                kind: .disablePlugins,
                summary: T("停用「%@」未使用的 %@ 个插件", batchName, outcome.disabledItems.count),
                disabled: outcome.disabledItems
            )
        }
        if let scan = projectScan, !outcome.disabledItems.isEmpty {
            summary.batch = recordProjectBatch(
                projectName: batchName,
                projectPath: scan.fileURL.path,
                disabled: outcome.disabledItems,
                includedSystem: targets.contains(where: \.isSystemLevel)
            )
        }
        return summary
    }

    /// 命令行用：只保留某个工程的选中状态（整库取消，其它工程取消）
    func selectOnlyBundleProject(_ id: String) {
        guard var scan = projectScan, var bundle = scan.bundle else { return }
        bundle.wholeLibrary = false
        bundle.selectedProjectIDs = [id]
        scan.bundle = bundle
        applyBundleSelection(to: &scan)
        projectScan = scan
        saveProtection(projectName: scan.projectName)
    }
}

