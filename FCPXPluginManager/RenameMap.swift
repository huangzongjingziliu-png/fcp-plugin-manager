import Foundation

// MARK: - 译名表解析

/// 译名表的一行。
struct RenameMapEntry {
    /// 在源文件里的行号（JSON 用条目序号），报错时告诉用户是哪一行
    let line: Int
    /// 原插件标识：完整路径或插件原名
    let key: String
    /// 新名字
    let newName: String
}

enum RenameMapError: LocalizedError {
    case unreadable(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): return message
        case .invalid(let message): return message
        }
    }
}

/// CSV / JSON 译名表解析。GUI 的「导入译名表」和 CLI 的 `rename --map` 共用这一份。
enum RenameMapParser {
    /// 根据扩展名或内容自动判断格式
    static func parse(data: Data, fileExtension: String? = nil) throws -> [RenameMapEntry] {
        let text = try decode(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RenameMapError.invalid(T("文件是空的。"))
        }

        let looksLikeJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if looksLikeJSON || fileExtension?.lowercased() == "json" {
            return try parseJSON(trimmed)
        }
        return try parseCSV(text)
    }

    // MARK: 编码

    private static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text.replacingOccurrences(of: "\u{FEFF}", with: "")
        }
        // Excel 在中文 Windows 上常存成 GB18030，先兜一下，避免直接报「乱码」
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) {
            return text
        }
        throw RenameMapError.unreadable(T("文件编码不支持，请另存为 UTF-8 后再导入。"))
    }

    // MARK: JSON

    private static func parseJSON(_ text: String) throws -> [RenameMapEntry] {
        guard let data = text.data(using: .utf8) else {
            throw RenameMapError.unreadable(T("文件编码不支持，请另存为 UTF-8 后再导入。"))
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RenameMapError.invalid(T("JSON 格式不对：%@", error.localizedDescription))
        }

        if let dict = json as? [String: String] {
            return dict
                .sorted { $0.key < $1.key }
                .enumerated()
                .map { index, pair in
                    RenameMapEntry(line: index + 1, key: pair.key, newName: pair.value)
                }
        }

        guard let array = json as? [[String: Any]] else {
            throw RenameMapError.invalid(
                T("JSON 格式不对。支持 {\"原路径或原名\": \"新名字\"} 或 [{\"path\":\"…\",\"name\":\"…\"}]。")
            )
        }

        var entries: [RenameMapEntry] = []
        for (index, item) in array.enumerated() {
            let line = index + 1
            let key = (item["path"] as? String)
                ?? (item["originalPath"] as? String)
                ?? (item["original"] as? String)
                ?? (item["name"] as? String)
                ?? ""
            let newName = (item["newName"] as? String)
                ?? (item["new"] as? String)
                ?? (item["name"] as? String)
                ?? ""
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RenameMapError.invalid(T("第 %lld 条：缺少原名或路径。", line))
            }
            if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw RenameMapError.invalid(T("第 %lld 条：新名字为空。", line))
            }
            entries.append(RenameMapEntry(line: line, key: key, newName: newName))
        }
        if entries.isEmpty {
            throw RenameMapError.invalid(T("没有可导入的条目。"))
        }
        return entries
    }

    // MARK: CSV

    private static func parseCSV(_ text: String) throws -> [RenameMapEntry] {
        let rawLines = text.components(separatedBy: .newlines)
        var entries: [RenameMapEntry] = []
        var isFirstRow = true

        for (index, rawLine) in rawLines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let delimiter: Character = line.contains("\t") ? "\t"
                : (line.contains(";") ? ";" : ",")
            var cells = splitCSVLine(line, delimiter: delimiter)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            // 去掉 Excel 导出的表头
            if isFirstRow {
                isFirstRow = false
                if cells.count >= 2, isHeaderRow(cells) { continue }
            }

            if cells.count < 2 {
                throw RenameMapError.invalid(
                    T("第 %lld 行：只有一列，需要「原名,新名字」两列。", lineNumber)
                )
            }
            if cells.count > 2 {
                throw RenameMapError.invalid(
                    T("第 %lld 行：超过两列。新名字里如果有逗号，请用英文双引号包起来。", lineNumber)
                )
            }

            let key = cells[0]
            let newName = cells[1]
            if key.isEmpty {
                throw RenameMapError.invalid(T("第 %lld 行：原名为空。", lineNumber))
            }
            if newName.isEmpty {
                throw RenameMapError.invalid(T("第 %lld 行：新名字为空。", lineNumber))
            }
            entries.append(RenameMapEntry(line: lineNumber, key: key, newName: newName))
        }

        if entries.isEmpty {
            throw RenameMapError.invalid(T("没有可导入的条目。"))
        }
        return entries
    }

    private static func isHeaderRow(_ cells: [String]) -> Bool {
        let headers: Set<String> = [
            "原名", "原插件", "原路径", "路径", "插件",
            "original", "originalpath", "old", "oldname", "path", "name",
            "新名", "新名字", "newname", "new"
        ]
        let first = cells[0].lowercased()
        let second = cells[1].lowercased()
        return headers.contains(first) || headers.contains(second)
    }

    /// 处理带英文双引号的 CSV 字段（名字里含逗号时用得上）
    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var cells: [String] = []
        var current = ""
        var insideQuotes = false

        for character in line {
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == delimiter && !insideQuotes {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        return cells
    }
}

// MARK: - 改名预览

enum RenamePlanStatus {
    case ready
    case adminRequired(command: String)
    case failed(reason: String)
}

struct RenamePlanItem {
    let entry: RenameMapEntry
    let plugin: PluginItem?
    let newName: String
    let status: RenamePlanStatus
}

struct RenamePlan {
    var items: [RenamePlanItem] = []

    var total: Int { items.count }
    var readyCount: Int { items.filter { if case .ready = $0.status { return true }; return false }.count }
    var adminCount: Int { items.filter { if case .adminRequired = $0.status { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
}

// MARK: - GUI / CLI 共用的改名流程

@MainActor
extension PluginViewModel {
    /// 把译名表条目对到实际插件，并逐条校验，生成可预览的计划。
    func buildRenamePlan(entries: [RenameMapEntry], category: PluginCategory? = nil) -> RenamePlan {
        var plan = RenamePlan()
        var usedPluginPaths: Set<String> = []
        var usedTargets: Set<String> = []

        for entry in entries {
            let matches = plugins.filter { $0.path == entry.key || $0.name == entry.key }
            let filtered = category == nil ? matches : matches.filter { $0.category == category }

            guard filtered.count == 1 else {
                let reason: String
                if filtered.isEmpty {
                    reason = category == nil
                        ? T("找不到这个插件。")
                        : T("在「%@」分类里找不到这个插件。", category?.rawValue ?? "")
                } else {
                    reason = T("匹配到 %lld 个同名插件，请改用完整路径。", filtered.count)
                }
                plan.items.append(
                    RenamePlanItem(entry: entry, plugin: nil, newName: entry.newName, status: .failed(reason: reason))
                )
                continue
            }

            let plugin = filtered[0]
            if usedPluginPaths.contains(plugin.path) {
                plan.items.append(
                    RenamePlanItem(
                        entry: entry,
                        plugin: plugin,
                        newName: entry.newName,
                        status: .failed(reason: T("同一个插件在译名表里出现了多次。"))
                    )
                )
                continue
            }

            if let invalid = validateNewName(entry.newName, for: plugin) {
                plan.items.append(
                    RenamePlanItem(entry: entry, plugin: plugin, newName: entry.newName, status: .failed(reason: invalid))
                )
                continue
            }

            let trimmed = entry.newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetPath = URL(fileURLWithPath: plugin.path)
                .deletingLastPathComponent()
                .appendingPathComponent(trimmed).path
            if usedTargets.contains(targetPath) {
                plan.items.append(
                    RenamePlanItem(
                        entry: entry,
                        plugin: plugin,
                        newName: entry.newName,
                        status: .failed(reason: T("和译名表里另一条会改成同一个名字，不能同时执行。"))
                    )
                )
                continue
            }

            usedPluginPaths.insert(plugin.path)
            usedTargets.insert(targetPath)

            if plugin.isSystemLevel {
                plan.items.append(
                    RenamePlanItem(
                        entry: entry,
                        plugin: plugin,
                        newName: entry.newName,
                        status: .adminRequired(
                            command: AdminCommandBuilder.renameCommand(oldPath: plugin.path, newPath: targetPath)
                        )
                    )
                )
            } else {
                plan.items.append(
                    RenamePlanItem(entry: entry, plugin: plugin, newName: entry.newName, status: .ready)
                )
            }
        }
        return plan
    }

    struct RenamePlanOutcome {
        var renames: [RenameSnapshot] = []
        var renamedNames: [String] = []
        var failures: [String] = []
        var adminCommands: [String] = []
    }

    /// 执行预览里状态为「可以改名」的条目。系统级只收集命令，不自己提权。
    func applyRenamePlan(_ plan: RenamePlan) async -> RenamePlanOutcome {
        var outcome = RenamePlanOutcome()
        for item in plan.items {
            switch item.status {
            case .failed(let reason):
                outcome.failures.append("\(item.entry.key)：\(reason)")
            case .adminRequired(let command):
                outcome.adminCommands.append(command)
            case .ready:
                guard let plugin = item.plugin else { continue }
                switch await renamePlugin(plugin, to: item.newName) {
                case .success(let oldPath, let newPath, _):
                    outcome.renames.append(RenameSnapshot(oldPath: oldPath, newPath: newPath))
                    outcome.renamedNames.append(URL(fileURLWithPath: newPath).lastPathComponent)
                case .needAuthentication(let oldPath, let newPath, _):
                    outcome.adminCommands.append(
                        AdminCommandBuilder.renameCommand(oldPath: oldPath, newPath: newPath)
                    )
                case .failure(let message):
                    outcome.failures.append("\(plugin.name)：\(message)")
                }
            }
        }
        return outcome
    }
}
