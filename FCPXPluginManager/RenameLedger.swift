import Foundation

// MARK: - 改名台账

/// 改名台账的状态。台账独立存在，不依赖备份记录，也不依赖操作日志。
enum RenameLedgerStatus: String, Codable {
    /// 改名已生效
    case applied
    /// 系统级改名命令还没执行
    case renamePending
    /// 已恢复原名
    case restored
    /// 系统级恢复原名命令还没执行
    case restorePending

    var isActive: Bool {
        switch self {
        case .applied, .renamePending, .restorePending: return true
        case .restored: return false
        }
    }
}

/// 一条改名记录：原名、改后名字、时间、所在目录，一个都不能少。
struct RenameLedgerEntry: Identifiable, Codable {
    let id: UUID
    let oldName: String
    let newName: String
    /// 所在目录（父目录），恢复原名时按这个目录拼回去
    let directory: String
    let oldPath: String
    let newPath: String
    let categoryRaw: String
    let isSystemLevel: Bool
    let date: Date
    var status: RenameLedgerStatus

    var category: PluginCategory {
        PluginCategory(rawValue: categoryRaw) ?? .effects
    }

    var isActive: Bool { status.isActive }

    var statusDescription: String {
        switch status {
        case .applied: return T("已生效")
        case .renamePending: return T("待执行（系统级改名命令）")
        case .restored: return T("已恢复原名")
        case .restorePending: return T("待执行（系统级恢复命令）")
        }
    }
}

enum RenameRestoreOutcome {
    case success(oldName: String)
    case needAuthentication(command: String)
    case targetExists(String)
    case failure(String)
}

struct RenameRestoreBulkOutcome {
    var restored: [String] = []
    var failures: [String] = []
    var commands: [String] = []
}

// MARK: - 台账读写与恢复原名

@MainActor
extension PluginViewModel {
    private var renameLedgerFile: URL {
        ensureDirectory(storageRoot.appendingPathComponent("Renames", isDirectory: true))
            .appendingPathComponent("ledger.json")
    }

    func loadRenameLedger() {
        let url = renameLedgerFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            renameLedger = []
            renameLedgerProblem = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            renameLedger = try decoder.decode([RenameLedgerEntry].self, from: data)
            renameLedgerProblem = nil
        } catch {
            // 读不出来就明确告诉用户，绝不猜一个原名
            renameLedger = []
            renameLedgerProblem = T(
                "改名台账读取失败（%@）。本应用无法得知任何插件的原名，请不要手动改回，先备份台账文件再排查。",
                error.localizedDescription
            )
        }
    }

    func saveRenameLedger() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(renameLedger)
            try data.write(to: renameLedgerFile, options: .atomic)
        } catch {
            // 台账写不进去时，重命名本身已经生效了；留一条提示避免用户以为能撤销
            renameLedgerProblem = T("改名台账写入失败：%@", error.localizedDescription)
        }
    }

    /// 每次真的改了名都记一条。同一个插件重复改名时更新最后一条，避免台账膨胀。
    func recordRenameInLedger(
        oldPath: String,
        newPath: String,
        category: PluginCategory,
        isSystemLevel: Bool,
        status: RenameLedgerStatus
    ) {
        guard !oldPath.isEmpty, !newPath.isEmpty else { return }
        let oldURL = URL(fileURLWithPath: oldPath)
        let newURL = URL(fileURLWithPath: newPath)
        let oldName = oldURL.lastPathComponent
        let newName = newURL.lastPathComponent
        guard !oldName.isEmpty, !newName.isEmpty else { return }

        if let index = renameLedger.firstIndex(where: { $0.oldPath == oldPath && $0.isActive }) {
            renameLedger[index].status = status
        } else {
            renameLedger.append(
                RenameLedgerEntry(
                    id: UUID(),
                    oldName: oldName,
                    newName: newName,
                    directory: oldURL.deletingLastPathComponent().path,
                    oldPath: oldPath,
                    newPath: newPath,
                    categoryRaw: category.rawValue,
                    isSystemLevel: isSystemLevel,
                    date: Date(),
                    status: status
                )
            )
        }
        saveRenameLedger()
    }

    func markRenameLedgerRestored(oldPath: String, newPath: String) {
        guard let index = renameLedger.firstIndex(where: {
            $0.oldPath == oldPath && $0.newPath == newPath && $0.isActive
        }) else { return }
        renameLedger[index].status = .restored
        saveRenameLedger()
    }

    /// 系统级的 sudo 命令执行完、或用户在访达里手动改了名，刷新时按磁盘实际情况更新状态。
    func refreshRenameLedgerStatuses() {
        var changed = false
        for index in renameLedger.indices {
            let entry = renameLedger[index]
            let oldExists = FileManager.default.fileExists(atPath: entry.oldPath)
            let newExists = FileManager.default.fileExists(atPath: entry.newPath)
            switch entry.status {
            case .renamePending where !oldExists && newExists:
                renameLedger[index].status = .applied
                changed = true
            case .restorePending where oldExists && !newExists:
                renameLedger[index].status = .restored
                changed = true
            default:
                break
            }
        }
        if changed {
            saveRenameLedger()
        }
    }

    /// 按类别取还需要恢复原名的记录
    func renameLedgerEntries(in category: PluginCategory) -> [RenameLedgerEntry] {
        renameLedger
            .filter { $0.isActive && (category == .all || $0.categoryRaw == category.rawValue) }
            .sorted { $0.date > $1.date }
    }

    /// 单个恢复原名。目标位置有同名插件一律拒绝，绝不覆盖。
    func restoreOriginalName(_ entry: RenameLedgerEntry) async -> RenameRestoreOutcome {
        guard !entry.oldPath.isEmpty, !entry.oldName.isEmpty else {
            return .failure(T("改名台账缺少原名信息，原名已无从得知，不能自动恢复。"))
        }

        let fm = FileManager.default
        let oldExists = fm.fileExists(atPath: entry.oldPath)
        let newExists = fm.fileExists(atPath: entry.newPath)

        // 系统级改名命令还没执行：本来就没改名，把台账状态收尾即可
        if entry.status == .renamePending, oldExists, !newExists {
            updateLedgerStatus(entry, to: .restored)
            return .success(oldName: entry.oldName)
        }

        if oldExists {
            return .targetExists(T("「%@」已经存在，按规矩不覆盖，原名没有恢复。", entry.oldPath))
        }
        guard newExists else {
            return .failure(T("找不到改名后的插件：%@", entry.newPath))
        }

        if entry.isSystemLevel {
            updateLedgerStatus(entry, to: .restorePending)
            return .needAuthentication(
                command: AdminCommandBuilder.renameCommand(oldPath: entry.newPath, newPath: entry.oldPath)
            )
        }

        let parent = URL(fileURLWithPath: entry.oldPath).deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let source = entry.newPath
        let target = URL(fileURLWithPath: entry.oldPath)
        let moveResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.moveItem(at: URL(fileURLWithPath: source), to: target)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch moveResult {
        case .failure(let error):
            return .failure(T("恢复原名失败：%@", Self.describe(error)))
        case .success:
            updateBackupOriginalPaths(from: entry.newPath, to: entry.oldPath)
            updateLedgerStatus(entry, to: .restored)
            return .success(oldName: entry.oldName)
        }
    }

    func restoreOriginalNames(_ entries: [RenameLedgerEntry]) async -> RenameRestoreBulkOutcome {
        var outcome = RenameRestoreBulkOutcome()
        for entry in entries {
            switch await restoreOriginalName(entry) {
            case .success(let oldName):
                outcome.restored.append(oldName)
            case .needAuthentication(let command):
                outcome.commands.append(command)
            case .targetExists(let reason):
                outcome.failures.append("\(entry.newName)：\(reason)")
            case .failure(let message):
                outcome.failures.append("\(entry.newName)：\(message)")
            }
        }
        return outcome
    }

    private func updateLedgerStatus(_ entry: RenameLedgerEntry, to status: RenameLedgerStatus) {
        guard let index = renameLedger.firstIndex(where: { $0.id == entry.id }) else { return }
        renameLedger[index].status = status
        saveRenameLedger()
    }
}
