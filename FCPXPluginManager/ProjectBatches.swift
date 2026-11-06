import Foundation

// MARK: - 工程停用批次

/// 批次里单个插件的恢复状态。
/// 只有 pending 会参与「恢复该批次」，失败也保持 pending，方便再点一次重试。
enum BatchEntryState: String, Codable {
    case pending
    case restored
    case skipped
}

struct ProjectBatchEntry: Codable, Identifiable, Equatable {
    let pluginName: String
    /// 插件原来的位置
    let originalPath: String
    /// 对应的禁用记录目录（Disabled 目录里的那一条），恢复时靠它精确定位
    let disabledRecordID: String
    let category: String
    let isSystemLevel: Bool
    var state: BatchEntryState = .pending
    var note: String?

    var id: String { disabledRecordID.isEmpty ? originalPath : disabledRecordID }
}

/// 一次「为某个工程停用未使用的插件」= 一批。
/// 不同工程各存各的，互不覆盖；恢复只认这一批。
struct ProjectBatch: Codable, Identifiable, Equatable {
    let id: UUID
    var projectName: String
    var projectPath: String
    var createdAt: Date
    /// 全部条目都恢复完才写时间；部分恢复时保持 nil
    var restoredAt: Date?
    var includedSystem: Bool
    var entries: [ProjectBatchEntry]

    var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    var restoredCount: Int { entries.filter { $0.state == .restored }.count }
    var skippedCount: Int { entries.filter { $0.state == .skipped }.count }

    /// 批次已完整恢复，可继续保留在历史里查看
    var isFullyRestored: Bool { !entries.isEmpty && pendingCount == 0 && skippedCount == 0 }
    var hasPending: Bool { pendingCount > 0 }
}

struct BatchRestoreOutcome {
    var restored: [String] = []
    var failed: [String] = []
    var skipped: [String] = []
    var cancelled = false
    /// 失败/跳过的原因，界面汇总用
    var notes: [String] = []

    var summary: String {
        var parts = [T("成功 %@", restored.count)]
        if !failed.isEmpty { parts.append(T("失败 %@", failed.count)) }
        if !skipped.isEmpty { parts.append(T("跳过 %@", skipped.count)) }
        return parts.joined(separator: T(" / "))
    }
}

private struct StoredProjectBatches: Codable {
    var batches: [ProjectBatch] = []
}

/// 路径比对：/var 与 /private/var 这类符号链接要视为同一个位置
private func sameFilePath(_ lhs: String, _ rhs: String) -> Bool {
    guard !lhs.isEmpty, !rhs.isEmpty else { return false }
    if lhs == rhs { return true }
    let a = URL(fileURLWithPath: lhs).resolvingSymlinksInPath().path
    let b = URL(fileURLWithPath: rhs).resolvingSymlinksInPath().path
    return a == b
}

// MARK: - PluginViewModel：批次记录与精确恢复

@MainActor
extension PluginViewModel {
    private var projectBatchesFile: URL {
        storageRoot
            .appendingPathComponent("ProjectBatches", isDirectory: true)
            .appendingPathComponent("batches.json")
    }

    private static func makeBatchDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeBatchEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func loadProjectBatches() {
        ensureDirectory(projectBatchesFile.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: projectBatchesFile),
              let stored = try? Self.makeBatchDecoder().decode(StoredProjectBatches.self, from: data) else {
            projectBatches = []
            return
        }
        projectBatches = stored.batches.sorted { $0.createdAt > $1.createdAt }
    }

    private func saveProjectBatches() {
        ensureDirectory(projectBatchesFile.deletingLastPathComponent())
        guard let data = try? Self.makeBatchEncoder().encode(StoredProjectBatches(batches: projectBatches)) else { return }
        try? data.write(to: projectBatchesFile, options: .atomic)
    }

    /// 同一个工程（按路径比对）的历史批次，新的在前
    func batches(forProjectPath path: String) -> [ProjectBatch] {
        projectBatches.filter { sameFilePath($0.projectPath, path) }
    }

    /// 当前扫描工程里还有没恢复的批次（最近的一批）
    var latestPendingBatchForCurrentProject: ProjectBatch? {
        guard let scan = projectScan else { return nil }
        return batches(forProjectPath: scan.fileURL.path).first(where: \.hasPending)
    }

    /// 为工程停用后立刻记一批。只记录真正生成停用记录的插件。
    @discardableResult
    func recordProjectBatch(
        projectName: String,
        projectPath: String,
        disabled: [DisabledItem],
        includedSystem: Bool
    ) -> ProjectBatch? {
        var seen = Set<String>()
        let entries = disabled.compactMap { item -> ProjectBatchEntry? in
            guard !item.originalPath.isEmpty, !seen.contains(item.originalPath) else { return nil }
            seen.insert(item.originalPath)
            return ProjectBatchEntry(
                pluginName: item.displayName,
                originalPath: URL(fileURLWithPath: item.originalPath).resolvingSymlinksInPath().path,
                disabledRecordID: URL(fileURLWithPath: item.entryPath).resolvingSymlinksInPath().path,
                category: item.category.rawValue,
                isSystemLevel: item.isSystemLevel,
                state: .pending,
                note: item.isEffective ? nil : T("等待管理员授权")
            )
        }
        guard !entries.isEmpty else { return nil }

        let batch = ProjectBatch(
            id: UUID(),
            projectName: projectName,
            projectPath: projectPath,
            createdAt: Date(),
            restoredAt: nil,
            includedSystem: includedSystem,
            entries: entries
        )
        projectBatches.insert(batch, at: 0)
        saveProjectBatches()
        return batch
    }

    /// 只恢复这一批里还没恢复的插件，不碰其它停用项。
    func restoreProjectBatch(_ batchID: UUID) async -> BatchRestoreOutcome {
        var outcome = BatchRestoreOutcome()
        guard let index = projectBatches.firstIndex(where: { $0.id == batchID }) else {
            return outcome
        }

        // 1. 把批次条目映射到当前真实存在的禁用记录
        var itemByEntryID: [String: DisabledItem] = [:]
        for entry in projectBatches[index].entries where entry.state == .pending {
            if let item = disabledItems.first(where: {
                sameFilePath($0.entryPath, entry.disabledRecordID)
                    || sameFilePath($0.originalPath, entry.originalPath)
            }) {
                itemByEntryID[entry.id] = item
            }
        }

        // 2. 找不到记录的条目标为跳过：它可能已在别处恢复，不能算失败
        for entryIndex in projectBatches[index].entries.indices {
            let entry = projectBatches[index].entries[entryIndex]
            guard entry.state == .pending, itemByEntryID[entry.id] == nil else { continue }
            projectBatches[index].entries[entryIndex].state = .skipped
            projectBatches[index].entries[entryIndex].note = T("找不到对应的停用记录，可能已在别处恢复")
            outcome.skipped.append(entry.pluginName)
            outcome.notes.append(T("%@：找不到停用记录", entry.pluginName))
        }

        // 3. 逐个恢复：单个失败不影响其余，进度条与「停止」沿用现有批量机制
        let pendingItems = projectBatches[index].entries
            .filter { $0.state == .pending }
            .compactMap { itemByEntryID[$0.id] }
        let entryIDByRecordID = Dictionary(
            uniqueKeysWithValues: itemByEntryID.map { ($0.value.entryPath, $0.key) }
        )

        if !pendingItems.isEmpty {
            beginBatch(T("正在恢复 %lld 个插件", pendingItems.count), total: pendingItems.count)
            defer { endBatch() }

            for item in pendingItems {
                let result = await enableDisabled(item)
                let entryID = entryIDByRecordID[item.entryPath]
                let entryIndex = entryID.flatMap { id in
                    projectBatches[index].entries.firstIndex { $0.id == id }
                }

                switch result {
                case .success, .successWithWarning:
                    if let entryIndex {
                        projectBatches[index].entries[entryIndex].state = .restored
                        projectBatches[index].entries[entryIndex].note = nil
                    }
                    outcome.restored.append(item.displayName)
                case .needAuthentication(let reason):
                    if let entryIndex {
                        projectBatches[index].entries[entryIndex].note = reason
                    }
                    outcome.failed.append(item.displayName)
                    outcome.notes.append(T("%@：%@", item.displayName, reason))
                case .targetExists:
                    let reason = T("原位置已有同名插件，未覆盖")
                    if let entryIndex {
                        projectBatches[index].entries[entryIndex].note = reason
                    }
                    outcome.failed.append(item.displayName)
                    outcome.notes.append(T("%@：%@", item.displayName, reason))
                case .failure(let message):
                    if let entryIndex {
                        projectBatches[index].entries[entryIndex].note = message
                    }
                    outcome.failed.append(item.displayName)
                    outcome.notes.append(T("%@：%@", item.displayName, message))
                }

                if !advanceBatch() {
                    outcome.cancelled = true
                    break
                }
            }
        }

        // 4. 全部处理完才把批次标为已恢复；部分失败保留 pending 方便重试
        if projectBatches[index].pendingCount == 0 {
            projectBatches[index].restoredAt = Date()
        }
        saveProjectBatches()
        loadDisabled()
        return outcome
    }
}
