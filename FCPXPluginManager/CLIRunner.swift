import Foundation

/// 命令行入口：和 GUI 共用 PluginViewModel / PluginScanner / 文件操作，
/// 不复制任何业务逻辑。所有会改文件的命令默认只打印计划，必须加 --yes 才执行。
enum CLIRunner {
    static func run(arguments: [String]) -> Int32 {
        var exitCode: Int32 = 0
        var finished = false

        Task { @MainActor in
            do {
                exitCode = try await execute(arguments)
            } catch let error as CLIError {
                fputs("错误：\(error.message)\n", stderr)
                exitCode = 1
            } catch {
                fputs("错误：\(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            finished = true
        }

        // 命令行没有 NSApplication 事件循环，手动转主线程 RunLoop，等异步任务跑完
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return exitCode
    }

    // MARK: - Dispatch

    @MainActor
    private static func execute(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return 0
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "list", "ls":       return try await listCommand(rest)
        case "rename", "mv":     return try await renameCommand(rest)
        case "disable", "off":   return try await disableCommand(rest)
        case "enable", "on":     return try await enableCommand(rest)
        case "restore":          return try await restoreCommand(rest)
        case "restore-name", "unrename":
            return try await restoreNameCommand(rest)
        case "scan-project", "scan":
            return try await scanProjectCommand(rest)
        case "ledger":           return try await ledgerCommand(rest)
        case "log", "logs":      return try await logCommand(rest)
        case "--version", "-v", "version":
            print(AppInfo.version)
            return 0
        case "help", "--help", "-h":
            printHelp()
            return 0
        default:
            throw CLIError("未知命令「\(command)」。用 `fcpplugin --cli help` 查看用法。")
        }
    }

    // MARK: - list

    @MainActor
    private static func listCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        await viewModel.scanNow()
        viewModel.loadDisabled()

        let category = try options.category()
        let wantDisabled = options.flag("disabled")

        if wantDisabled {
            let items = viewModel.disabledItems.filter { category == nil || $0.category == category }
            if options.flag("json") {
                printJSON(items.map { item -> [String: Any] in
                    [
                        "name": item.displayName,
                        "category": item.category.rawValue,
                        "originalPath": item.originalPath,
                        "entryPath": item.entryPath,
                        "payloadPath": item.currentPath,
                        "isSystemLevel": item.isSystemLevel,
                        "isEffective": item.isEffective,
                        "hasPayload": item.hasPayload,
                        "originalExists": item.originalExists
                    ]
                })
            } else {
                if items.isEmpty { print("没有匹配的禁用记录。") }
                for item in items {
                    print("\(item.isEffective ? "[已生效]" : "[未生效]") \(item.displayName)  \(item.category.rawValue)  \(item.originalPath)")
                }
                let pending = items.filter { !$0.isEffective }.count
                print("\n共 \(items.count) 条，已真正停用 \(items.count - pending) 条，未生效 \(pending) 条。")
            }
            return 0
        }

        let items = viewModel.plugins.filter { category == nil || $0.category == category }
        if options.flag("json") {
            printJSON(items.map { plugin -> [String: Any] in
                [
                    "name": plugin.displayName,
                    "category": plugin.category.rawValue,
                    "path": plugin.path,
                    "isSystemLevel": plugin.isSystemLevel,
                    "origin": plugin.origin.rawValue,
                    "version": plugin.version ?? "",
                    "vendor": plugin.vendor ?? "",
                    "sizeBytes": plugin.sizeBytes ?? 0,
                    "source": plugin.source.shortLocation
                ]
            })
        } else {
            if items.isEmpty { print("没有匹配的插件。") }
            for plugin in items {
                let tag = plugin.isSystemLevel ? "所有用户安装" : "仅当前用户安装"
                print("\(plugin.name)  [\(plugin.category.rawValue)]  [\(plugin.origin.displayName)]  \(tag)  \(plugin.path)")
            }
            print("\n共 \(items.count) 个插件。")
        }
        return 0
    }

    // MARK: - rename

    @MainActor
    private static func renameCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        await viewModel.scanNow()

        var entries: [RenameMapEntry] = []
        if let path = options.value("path"), let name = options.value("name") {
            entries = [RenameMapEntry(line: 1, key: path, newName: name)]
        } else if let mapPath = options.value("map") {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: mapPath))
            } catch {
                throw CLIError("读不了映射文件：\(error.localizedDescription)")
            }
            do {
                entries = try RenameMapParser.parse(
                    data: data,
                    fileExtension: URL(fileURLWithPath: mapPath).pathExtension
                )
            } catch {
                throw CLIError(error.localizedDescription)
            }
        } else {
            throw CLIError("rename 需要 `--path <插件路径> --name <新名字>`，或 `--map <映射文件>`。")
        }

        let category = try options.category()
        // 解析、匹配、校验全部走 GUI 共用的那一套
        let plan = viewModel.buildRenamePlan(entries: entries, category: category)

        var errors: [String] = plan.items.compactMap { item in
            guard case .failed(let reason) = item.status else { return nil }
            return "\(item.entry.key) → \(item.entry.newName)：\(reason)"
        }
        if !errors.isEmpty {
            throw CLIError("改名被拒绝，没有改动任何文件：\n" + errors.joined(separator: "\n"))
        }

        var systemCommands: [String] = plan.items.compactMap { item in
            guard case .adminRequired(let command) = item.status else { return nil }
            return command
        }
        let readyItems = plan.items.filter { item in
            if case .ready = item.status { return true }
            return false
        }

        var doneCount = 0
        if options.flag("yes") {
            let outcome = await viewModel.applyRenamePlan(RenamePlan(items: readyItems))
            for (snapshot, name) in zip(outcome.renames, outcome.renamedNames) {
                doneCount += 1
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: "重命名「\(URL(fileURLWithPath: snapshot.oldPath).lastPathComponent)」→「\(name)」",
                    renames: [snapshot]
                )
                print("已改名：\(snapshot.oldPath) → \(snapshot.newPath)")
            }
            errors.append(contentsOf: outcome.failures)
            systemCommands.append(contentsOf: outcome.adminCommands)
        } else {
            for item in readyItems {
                print("[dry-run] 将把「\(item.plugin?.name ?? item.entry.key)」改名为「\(item.newName)」")
            }
            print("\n以上是预演，没有改动任何文件。确认无误后加 `--yes` 再执行。")
        }

        if !systemCommands.isEmpty {
            print("\n以下系统级插件需要管理员权限，请复制命令到终端执行（CLI 不会自己提权）：")
            print(systemCommands.joined(separator: "\n"))
            print("\n执行后重新运行 `fcpplugin list` 复核名字。")
        }
        if !errors.isEmpty {
            throw CLIError("部分改名失败：\n" + errors.joined(separator: "\n"))
        }
        if options.flag("yes") && doneCount == 0 {
            print("没有需要改名的插件。")
        }
        return 0
    }

    // MARK: - disable

    @MainActor
    private static func disableCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        await viewModel.scanNow()

        let targets = try selectPlugins(options, from: viewModel.plugins)
        guard !targets.isEmpty else { throw CLIError("没有匹配的插件。") }

        let sure = options.flag("yes")
        var systemCommands: [String] = []
        var doneCount = 0

        for plugin in targets {
            if plugin.isSystemLevel {
                // 系统级永远只输出命令，不自己提权
                let item = DisabledItem(
                    name: plugin.name,
                    currentPath: "",
                    entryPath: "",
                    originalPath: plugin.path,
                    category: plugin.category,
                    isSystemLevel: true,
                    disabledDate: nil
                )
                systemCommands.append(AdminCommandBuilder.manualDisableCommands(for: [item]))
                continue
            }
            if !sure {
                print("[dry-run] 将停用「\(plugin.name)」（\(plugin.path)）")
                continue
            }
            switch await viewModel.disablePlugin(plugin) {
            case .disabled(let item):
                doneCount += 1
                viewModel.addOperation(kind: .disablePlugins, summary: "停用「\(item.displayName)」", disabled: [item])
                print("已停用：\(item.displayName)")
            case .needAuthentication(let item, _):
                systemCommands.append(AdminCommandBuilder.manualDisableCommands(for: [item]))
            case .failure(let message):
                fputs("停用失败：\(plugin.name)：\(message)\n", stderr)
            }
        }

        if !sure && doneCount == 0 {
            print("\n以上是预演，没有改动任何文件。确认无误后加 `--yes` 再执行。")
        }
        if !systemCommands.isEmpty {
            print("\n系统级插件需要管理员权限，请复制命令执行（CLI 不会自己提权）：")
            print(systemCommands.joined(separator: "\n\n"))
            print("\n执行后运行 `fcpplugin list --disabled` 复核是否已生效。")
        }
        if doneCount > 0 {
            print("\n完成 \(doneCount) 个。重启 Final Cut Pro 后生效。")
        }
        return 0
    }

    // MARK: - enable

    @MainActor
    private static func enableCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        await viewModel.scanNow()
        viewModel.loadDisabled()

        let category = try options.category()
        let selected: [DisabledItem]
        if let path = options.value("path") {
            selected = viewModel.disabledItems.filter {
                $0.originalPath == path || $0.displayName == path || $0.entryPath == path
            }
        } else if options.flag("all") {
            selected = viewModel.disabledItems
        } else if let category {
            selected = viewModel.disabledItems.filter { $0.category == category }
        } else {
            throw CLIError("enable 需要 `--path <原路径或名字>`、`--category <类别>` 或 `--all`。")
        }

        guard !selected.isEmpty else { throw CLIError("没有匹配的禁用记录。") }
        let sure = options.flag("yes")
        var systemCommands: [String] = []
        var doneCount = 0

        for item in selected {
            if item.isSystemLevel && item.hasPayload && !item.originalExists {
                systemCommands.append(AdminCommandBuilder.manualEnableCommands(for: [item]))
                continue
            }
            if !sure {
                let action = item.hasPayload ? "把「\(item.displayName)」放回原目录" : "清掉「\(item.displayName)」的重复记录（插件本来就没停用）"
                print("[dry-run] 将\(action)")
                continue
            }
            switch await viewModel.enableDisabled(item) {
            case .success, .successWithWarning:
                doneCount += 1
                print("已恢复：\(item.displayName)")
            case .needAuthentication:
                systemCommands.append(AdminCommandBuilder.manualEnableCommands(for: [item]))
            case .targetExists:
                fputs("跳过：\(item.displayName) 原位置已有同名插件\n", stderr)
            case .failure(let message):
                fputs("恢复失败：\(item.displayName)：\(message)\n", stderr)
            }
        }

        if !sure && doneCount == 0 {
            print("\n以上是预演，没有改动任何文件。确认无误后加 `--yes` 再执行。")
        }
        if !systemCommands.isEmpty {
            print("\n系统级插件需要管理员权限，请复制命令执行（CLI 不会自己提权）：")
            print(systemCommands.joined(separator: "\n\n"))
        }
        if doneCount > 0 {
            print("\n完成 \(doneCount) 个。重启 Final Cut Pro 后生效。")
        }
        return 0
    }

    // MARK: - restore

    @MainActor
    private static func restoreCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        viewModel.loadBackups()

        let selected: [BackupItem]
        if let path = options.value("backup") {
            selected = viewModel.backups.filter {
                $0.backupPath == path || $0.originalPath == path || $0.displayName == path
            }
        } else if options.flag("all") {
            selected = viewModel.backups
        } else {
            throw CLIError("restore 需要 `--backup <备份路径或名字>` 或 `--all`。")
        }
        guard !selected.isEmpty else { throw CLIError("没有匹配的备份。") }

        let sure = options.flag("yes")
        var systemCommands: [String] = []
        var doneCount = 0
        var conflicts = 0

        for backup in selected {
            if viewModel.restoreTargetExists(for: backup) {
                conflicts += 1
                fputs("跳过：\(backup.displayName) 原位置已有同名插件（CLI 不覆盖，请到图形界面处理）\n", stderr)
                continue
            }
            if backup.isSystemLevel {
                systemCommands.append(
                    "sudo ditto \(AdminCommandBuilder.quote(backup.backupPath)) \(AdminCommandBuilder.quote(backup.originalPath))"
                )
                continue
            }
            if !sure {
                print("[dry-run] 将把备份「\(backup.displayName)」恢复到 \(backup.originalPath)")
                continue
            }
            switch await viewModel.restoreBackup(backup) {
            case .success, .successWithWarning:
                doneCount += 1
                print("已恢复：\(backup.displayName)")
            case .needAuthentication:
                systemCommands.append(
                    "sudo ditto \(AdminCommandBuilder.quote(backup.backupPath)) \(AdminCommandBuilder.quote(backup.originalPath))"
                )
            case .targetExists:
                conflicts += 1
            case .failure(let message):
                fputs("恢复失败：\(backup.displayName)：\(message)\n", stderr)
            }
        }

        if !sure && doneCount == 0 {
            print("\n以上是预演，没有改动任何文件。确认无误后加 `--yes` 再执行。")
        }
        if !systemCommands.isEmpty {
            print("\n系统级插件需要管理员权限，请复制命令执行（CLI 不会自己提权）：")
            print(systemCommands.joined(separator: "\n"))
        }
        if doneCount > 0 {
            print("\n完成 \(doneCount) 个。重启 Final Cut Pro 后生效。")
        }
        if conflicts > 0 {
            print("\n有 \(conflicts) 个因原位置已存在被跳过，没有覆盖任何文件。")
        }
        return 0
    }

    // MARK: - ledger / restore-name

    @MainActor
    private static func ledgerCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        viewModel.loadRenameLedger()
        viewModel.refreshRenameLedgerStatuses()

        if let problem = viewModel.renameLedgerProblem {
            fputs("注意：\(problem)\n", stderr)
        }

        let category = try options.category() ?? .all
        let entries = viewModel.renameLedgerEntries(in: category)

        if options.flag("json") {
            let formatter = ISO8601DateFormatter()
            printJSON(entries.map { entry -> [String: Any] in
                [
                    "oldName": entry.oldName,
                    "newName": entry.newName,
                    "directory": entry.directory,
                    "oldPath": entry.oldPath,
                    "newPath": entry.newPath,
                    "category": entry.categoryRaw,
                    "isSystemLevel": entry.isSystemLevel,
                    "status": entry.status.rawValue,
                    "date": formatter.string(from: entry.date)
                ]
            })
            return 0
        }

        if entries.isEmpty {
            print("没有可恢复原名的改名记录。")
            return 0
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for entry in entries {
            print("\(entry.oldName) → \(entry.newName)  [\(entry.statusDescription)]  \(formatter.string(from: entry.date))")
            print("  \(entry.directory)")
        }
        return 0
    }

    @MainActor
    private static func restoreNameCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()
        viewModel.loadRenameLedger()
        viewModel.refreshRenameLedgerStatuses()

        let category = try options.category()
        let target = options.value("path")
        let all = options.flag("all")
        guard all || category != nil || target != nil else {
            throw CLIError("restore-name 需要 `--path <插件路径或当前名字>`、`--category <类别>` 或 `--all`。")
        }

        let filterCategory = category ?? .all
        var entries = viewModel.renameLedgerEntries(in: filterCategory)
        if let target {
            entries = entries.filter {
                $0.oldPath == target || $0.newPath == target || $0.oldName == target || $0.newName == target
            }
        }
        guard !entries.isEmpty else {
            if let problem = viewModel.renameLedgerProblem { throw CLIError(problem) }
            throw CLIError("找不到对应的改名记录。如果插件是在本应用之外改的名，原名已无从得知。")
        }

        let sure = options.flag("yes")
        var commands: [String] = []
        var restored = 0
        var failures: [String] = []

        for entry in entries {
            if !sure {
                if entry.isSystemLevel {
                    commands.append(AdminCommandBuilder.renameCommand(oldPath: entry.newPath, newPath: entry.oldPath))
                } else {
                    print("[dry-run] 将把「\(entry.newName)」改回「\(entry.oldName)」：\(entry.newPath) → \(entry.oldPath)")
                }
                continue
            }
            switch await viewModel.restoreOriginalName(entry) {
            case .success(let oldName):
                restored += 1
                viewModel.addOperation(
                    kind: .renamePlugin,
                    summary: T("恢复原名「%@」", oldName),
                    renames: [RenameSnapshot(oldPath: entry.newPath, newPath: entry.oldPath)]
                )
                print("已恢复原名：\(entry.newPath) → \(entry.oldPath)")
            case .needAuthentication(let command):
                commands.append(command)
            case .targetExists(let reason), .failure(let reason):
                failures.append("\(entry.newName)：\(reason)")
            }
        }

        if !sure {
            print("\n以上是预演，没有改动任何文件。确认无误后加 `--yes` 再执行。")
        }
        if !commands.isEmpty {
            print("\n以下系统级插件恢复原名需要管理员权限，请复制命令到终端执行（CLI 不会自己提权）：")
            print(commands.joined(separator: "\n"))
            print("\n台账已标记为「待执行」；执行完重新运行 `fcpplugin ledger` 复核。")
        }
        if restored > 0 {
            print("\n已恢复 \(restored) 个原名。重启 Final Cut Pro 后生效。")
        }
        if !failures.isEmpty {
            throw CLIError("部分没有恢复：\n" + failures.joined(separator: "\n"))
        }
        return 0
    }

    // MARK: - log

    @MainActor
    private static func logCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        let viewModel = PluginViewModel()

        if options.flag("json") {
            let formatter = ISO8601DateFormatter()
            printJSON(viewModel.operations.map { record -> [String: Any] in
                [
                    "id": record.id.uuidString,
                    "date": formatter.string(from: record.date),
                    "kind": record.kind.rawValue,
                    "summary": record.summary,
                    "undone": record.undone,
                    "canUndo": record.isUndoable
                ]
            })
            return 0
        }

        if viewModel.operations.isEmpty {
            print("还没有操作记录。")
            return 0
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for record in viewModel.operations.reversed() {
            print("\(formatter.string(from: record.date))  [\(record.kind.displayName)]  \(record.summary)\(record.undone ? "（已撤销）" : "")")
        }
        return 0
    }

    // MARK: - Selection

    @MainActor
    private static func selectPlugins(_ options: Options, from plugins: [PluginItem]) throws -> [PluginItem] {
        if let path = options.value("path") {
            let matches = plugins.filter { $0.path == path || $0.name == path }
            guard !matches.isEmpty else { throw CLIError("找不到插件：\(path)") }
            return matches
        }
        if options.flag("all") { return plugins }
        if let category = try options.category() {
            return plugins.filter { $0.category == category }
        }
        throw CLIError("请指定 `--path <路径或名字>`、`--category <类别>` 或 `--all`。")
    }

    // MARK: - scan-project

    @MainActor
    private static func scanProjectCommand(_ args: [String]) async throws -> Int32 {
        let options = try Options(args)
        guard let rawPath = options.value("path") else {
            throw CLIError("scan-project 需要 `--path <工程.fcpxml 或资源库.fcpbundle>`。")
        }
        let path = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError("路径不存在：\(path)")
        }
        let url = URL(fileURLWithPath: path)

        let viewModel = PluginViewModel()
        await viewModel.scanNow()
        viewModel.loadDisabled()
        viewModel.loadProjectBatches()

        let result = try await viewModel.scanProject(at: url)

        if let wanted = options.value("project") {
            guard let bundle = result.bundle else {
                throw CLIError("--project 只能用于 .fcpbundle 资源库；XML 工程只有一个工程，不用指定。")
            }
            let matches = bundle.allProjects.filter { $0.id == wanted || $0.name == wanted }
            guard matches.count == 1, let project = matches.first else {
                let reason = matches.isEmpty ? "找不到这个工程" : "这个名字对应多个工程，请改用完整 id"
                let list = bundle.allProjects.map { "  \($0.id)" }.joined(separator: "\n")
                throw CLIError("\(reason)：\(wanted)\n可用工程：\n\(list)")
            }
            viewModel.selectOnlyBundleProject(project.id)
        }

        guard let scan = viewModel.projectScan else {
            throw CLIError("扫描没有返回结果。")
        }
        if let warning = scan.warning {
            throw CLIError(warning)
        }

        let usedPlugins = viewModel.plugins.filter { scan.usedPaths.contains($0.path) }
        let usedNames = usedPlugins.map(\.displayName).sorted()
        let targets = viewModel.projectUnusedCandidates()
        let unusedNames = targets.map(\.displayName).sorted()
        let adminCount = targets.filter(\.isSystemLevel).count
        let dryRun = !options.flag("yes")
        let wantsJSON = options.flag("json")

        if !wantsJSON {
            print(T("工程：%@", scan.projectName))
            if let bundle = scan.bundle {
                print(T("库内 %@ 个事件、%@ 个工程；本次范围：%@",
                        bundle.events.count, bundle.projectCount, bundle.selectionLabel))
            }
            print(T("用到 %@ 个插件：", usedNames.count))
            for name in usedNames { print("  · \(name)") }
            if usedNames.isEmpty { print("  （没有）") }
            if !scan.unmatched.isEmpty {
                print(T("另有 %@ 条引用没匹配到本机插件（不会因此停用对应插件）：", scan.unmatched.count))
                for item in scan.unmatched.prefix(10) { print("  ? \(item)") }
            }
            print(T("未使用、可停用 %@ 个：", unusedNames.count))
            for name in unusedNames.prefix(20) { print("  - \(name)") }
            if unusedNames.count > 20 {
                print(T("  …另有 %@ 个", unusedNames.count - 20))
            }
            if adminCount > 0 {
                print(T("其中 %@ 个装在所有用户目录，真正停用需要一次管理员授权。", adminCount))
            }
        }

        if dryRun {
            if wantsJSON {
                printJSON([
                    "path": scan.fileURL.path,
                    "project": scan.projectName,
                    "projects": scan.bundle?.projectCount ?? 1,
                    "events": scan.bundle?.events.count ?? 0,
                    "used": usedNames,
                    "unused": unusedNames,
                    "unmatched": scan.unmatched,
                    "adminRequired": adminCount,
                    "applied": false
                ])
            } else {
                print("")
                print(T("以上是预演，没有改动任何文件。确认无误后加 `--yes` 执行。"))
            }
            return 0
        }

        guard !targets.isEmpty else {
            if wantsJSON {
                printJSON(["path": scan.fileURL.path, "applied": false, "reason": "nothing-unused"])
            } else {
                print(T("没有可停用的插件，什么都不用做。"))
            }
            return 0
        }

        let summary = await viewModel.disableProjectUnused()

        if wantsJSON {
            printJSON([
                "path": scan.fileURL.path,
                "project": scan.projectName,
                "used": usedNames,
                "unused": unusedNames,
                "applied": true,
                "disabled": summary.disabled.map(\.displayName),
                "adminRequired": summary.adminPending.map(\.displayName),
                "batch": summary.batch?.projectName ?? "",
                "failures": summary.failures
            ])
            return summary.failures.isEmpty ? 0 : 1
        }

        print("")
        print(T("已停用 %@ 个未使用的插件。", summary.disabled.count))
        if let batch = summary.batch {
            print(T("已记入批次「%@」，可在界面「已停用」页整批恢复。", batch.projectName))
        }
        if !summary.adminPending.isEmpty {
            print(T("以下 %@ 个需要管理员权限，请复制到终端执行（CLI 不会自己提权）：", summary.adminPending.count))
            for item in summary.adminPending {
                print("sudo mv '\(item.originalPath)' '\(item.currentPath)'")
            }
        }
        if !summary.failures.isEmpty {
            print(T("有 %@ 个停用失败：", summary.failures.count))
            for failure in summary.failures { print("  ! \(failure)") }
        }
        return summary.failures.isEmpty ? 0 : 1
    }

    // MARK: - Output

    private static func printJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            print("[]")
            return
        }
        print(text)
    }

    private static func printHelp() {
        print("""
        fcpplugin — Final Cut Pro 插件管理命令行

        用法：
          fcpplugin --cli --version
          fcpplugin list [--category effects|generators|transitions|titles] [--json]
          fcpplugin list --disabled [--category <类别>] [--json]
          fcpplugin rename --path <插件路径或名字> --name <新名字> [--yes]
          fcpplugin rename --map <映射.json> [--category <类别>] [--yes]
          fcpplugin disable --path <路径或名字> | --category <类别> | --all [--yes]
          fcpplugin enable  --path <原路径或名字> | --category <类别> | --all [--yes]
          fcpplugin restore --backup <备份路径或名字> | --all [--yes]
          fcpplugin scan-project --path <工程.fcpxml 或库.fcpbundle> [--project <工程 id>] [--json] [--yes]
          fcpplugin ledger [--category <类别>] [--json]
          fcpplugin restore-name --path <路径或当前名字> | --category <类别> | --all [--yes]
          fcpplugin log [--json]

        注意：一定要先写 --cli，否则会启动图形界面。

        安全规则：
          • 所有会改文件的命令默认只预演，必须加 --yes 才执行。
          • 系统级插件只输出 sudo 命令，CLI 自己不提权。
          • CLI 不提供批量删除。
          • 恢复遇到原位置同名插件会跳过，不覆盖。

        翻译流程：
          1. fcpplugin list --json > plugins.json
          2. 让 agent 按这份清单生成映射：{"原路径": "英文名"}
          3. fcpplugin rename --map map.json --yes
        """)
    }
}

// MARK: - Helpers

struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct Options {
    private let args: [String]

    init(_ args: [String]) throws {
        self.args = args
    }

    func value(_ name: String) -> String? {
        guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    func flag(_ name: String) -> Bool {
        args.contains("--\(name)")
    }

    func category() throws -> PluginCategory? {
        guard let raw = value("category") else { return nil }
        switch raw.lowercased() {
        case "effects", "effect", "效果": return .effects
        case "generators", "generator", "发生器": return .generators
        case "transitions", "transition", "转场": return .transitions
        case "titles", "title", "标题": return .titles
        case "all", "全部": return .all
        default:
            throw CLIError("未知类别「\(raw)」。可用：effects / generators / transitions / titles。")
        }
    }
}
