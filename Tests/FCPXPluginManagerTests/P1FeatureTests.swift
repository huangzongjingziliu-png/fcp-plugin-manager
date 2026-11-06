import XCTest
@testable import FCPXPluginManager

/// P1 / P2 功能回归测试。
/// 全部使用系统临时目录，不接触真实插件目录、备份目录或 Application Support。
@MainActor
final class P1FeatureTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPPluginManagerFeatureTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func makePlugin(
        named name: String,
        source: PluginSource = .userEffects,
        contents: String = "v1"
    ) throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(source.shortLocation, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginItem(path: dir.path, source: source))
    }

    private func makeViewModel(
        adminRunner: @escaping @Sendable (String) -> AdminRunResult = { _ in
            AdminRunResult(succeeded: false, message: "测试未注入管理员执行器")
        }
    ) -> PluginViewModel {
        PluginViewModel(storageRootOverride: root, adminRunner: adminRunner)
    }

    private func contents(of path: String) -> String? {
        try? String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("info.txt"), encoding: .utf8)
    }

    // MARK: - 备份 → 删除 → 恢复闭环

    func testBackupDeleteRestoreRoundTrip() async throws {
        let plugin = try makePlugin(named: "闭环插件", contents: "原始内容")
        let viewModel = makeViewModel()

        let result = await viewModel.backupAndRecycle(plugin)
        guard case .deleted(let backup) = result else {
            return XCTFail("应备份并删除成功，实际是 \(result)")
        }
        XCTAssertFalse(fm.fileExists(atPath: plugin.path), "插件应已离开原位置")
        XCTAssertTrue(fm.fileExists(atPath: backup.backupPath), "备份应存在")
        XCTAssertEqual(viewModel.backups.count, 1)

        switch await viewModel.restoreBackup(backup) {
        case .success:
            break
        default:
            return XCTFail("恢复应成功")
        }
        XCTAssertEqual(contents(of: plugin.path), "原始内容", "恢复后内容应与原插件一致")
        XCTAssertFalse(fm.fileExists(atPath: backup.backupPath), "恢复成功后备份应被消费")
    }

    // MARK: - P0-5 恢复失败不吞错

    func testSystemLevelRestoreReturnsRealErrorInsteadOfNeedAuthentication() async throws {
        let plugin = try makePlugin(named: "系统插件", source: .systemEffects)
        let viewModel = makeViewModel()

        guard case .success(let backup) = await viewModel.backupPlugin(plugin) else {
            return XCTFail("备份应成功")
        }

        // 用一个普通文件挡住父目录，制造「不是权限问题」的写入失败
        let blocker = root.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)

        let brokenBackup = BackupItem(
            name: backup.name,
            backupPath: backup.backupPath,
            originalPath: blocker.appendingPathComponent("sub/Plugin").path,
            category: backup.category,
            isSystemLevel: true
        )

        let result = await viewModel.restoreBackup(brokenBackup)
        switch result {
        case .failure(let reason):
            XCTAssertFalse(reason.isEmpty, "失败原因不能为空")
            XCTAssertTrue(reason.contains("NSCocoaErrorDomain") || reason.contains("NSPOSIXErrorDomain"),
                          "应带上错误域，方便排障，实际：\(reason)")
        case .needAuthentication:
            XCTFail("非权限错误不能伪装成需要管理员密码")
        default:
            XCTFail("应返回带真实原因的失败，实际是 \(result)")
        }
    }

    // MARK: - 禁用 / 启用

    func testDisableAndEnableUserPluginKeepsContent() async throws {
        let plugin = try makePlugin(named: "暂停插件", contents: "暂停前内容")
        let viewModel = makeViewModel()

        let disableResult = await viewModel.disablePlugin(plugin)
        guard case .disabled(let item) = disableResult else {
            return XCTFail("用户级插件应禁用成功，实际是 \(disableResult)")
        }
        XCTAssertFalse(fm.fileExists(atPath: plugin.path), "禁用后原位置应没有插件")
        XCTAssertTrue(fm.fileExists(atPath: item.currentPath), "插件应在禁用目录里")
        XCTAssertEqual(viewModel.disabledItems.count, 1)

        let enableResult = await viewModel.enableDisabled(item)
        guard case .success = enableResult else {
            return XCTFail("启用应成功，实际是 \(enableResult)")
        }
        XCTAssertEqual(contents(of: plugin.path), "暂停前内容", "启用后内容应保持")
        XCTAssertFalse(fm.fileExists(atPath: item.entryPath), "启用后禁用记录应清理")
        XCTAssertTrue(viewModel.disabledItems.isEmpty)
    }

    func testSystemLevelDisableStaysPendingUntilAuthorized() async throws {
        let plugin = try makePlugin(named: "系统暂停插件", source: .systemEffects)

        // 假的管理员执行器：模拟把原文件移进禁用目录（测试环境里本来就是可写的）
        let fakeRunner: @Sendable (String) -> AdminRunResult = { script in
            let pattern = #"mv '([^']+)' '([^']+)'"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let sourceRange = Range(match.range(at: 1), in: script),
                  let destinationRange = Range(match.range(at: 2), in: script) else {
                return AdminRunResult(succeeded: false, message: "命令格式不符合预期")
            }
            do {
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: String(script[sourceRange])),
                    to: URL(fileURLWithPath: String(script[destinationRange]))
                )
                return AdminRunResult(succeeded: true, message: "ok")
            } catch {
                return AdminRunResult(succeeded: false, message: "\(error)")
            }
        }

        let viewModel = makeViewModel(adminRunner: fakeRunner)
        let result = await viewModel.disablePlugin(plugin)
        guard case .needAuthentication(let item, let reason) = result else {
            return XCTFail("系统级插件应走管理员流程，实际是 \(result)")
        }
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "未授权时不能动原位置")
        XCTAssertFalse(item.hasPayload, "新流程不应再复制几十 G 的副本")
        XCTAssertFalse(item.isEffective, "原文件还在时不能算已停用")
        XCTAssertFalse(reason.isEmpty)

        // 授权后应真正移走，才算生效
        let outcome = await viewModel.applyPendingDisables([item])
        XCTAssertEqual(outcome.succeededCount, 1)
        XCTAssertFalse(fm.fileExists(atPath: plugin.path), "授权后原位置应已不存在")
        XCTAssertTrue(fm.fileExists(atPath: item.currentPath), "插件本体应在禁用目录里")
        XCTAssertTrue(viewModel.disabledItems.first?.isEffective == true)
    }

    func testExistingCopyAndOriginalBothPresentCanBeRemovedByAuthorization() async throws {
        let plugin = try makePlugin(named: "旧版复制件插件", source: .systemEffects)
        let viewModel = makeViewModel()
        let entry = root.appendingPathComponent("Disabled/OldEntry", isDirectory: true)
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        let payload = entry.appendingPathComponent("Plugin", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try "copy".write(to: payload.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        let metadata: [String: Any] = [
            "originalPath": plugin.path,
            "category": "效果",
            "isSystemLevel": "true"
        ]
        let metaData = try JSONSerialization.data(withJSONObject: metadata)
        try metaData.write(to: entry.appendingPathComponent(".metadata"))

        viewModel.refreshDisabledState()
        let item = try XCTUnwrap(viewModel.disabledItems.first { $0.entryPath.hasSuffix("/OldEntry") })
        XCTAssertTrue(item.hasPayload)
        XCTAssertFalse(item.isEffective)

        // 模拟授权：删原文件，保留应用内副本
        let fakeRunner: @Sendable (String) -> AdminRunResult = { script in
            guard let range = script.range(of: "rm -rf '") else {
                return AdminRunResult(succeeded: false, message: "没有删除命令")
            }
            let rest = script[range.upperBound...]
            guard let end = rest.firstIndex(of: "'") else {
                return AdminRunResult(succeeded: false, message: "命令格式不对")
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: String(rest[..<end])))
            return AdminRunResult(succeeded: true, message: "ok")
        }
        let authorized = makeViewModel(adminRunner: fakeRunner)
        authorized.refreshDisabledState()
        let pending = try XCTUnwrap(authorized.disabledItems.first { $0.entryPath.hasSuffix("/OldEntry") })
        let outcome = await authorized.applyPendingDisables([pending])
        XCTAssertEqual(outcome.succeededCount, 1)
        XCTAssertFalse(fm.fileExists(atPath: plugin.path))
        XCTAssertTrue(fm.fileExists(atPath: payload.path), "应用内副本必须保留")
    }

    func testEnableCleansRedundantCopyAndLeavesOriginalUntouched() async throws {
        // 复现用户机器上的旧记录：旧版本只复制、没移走，原位置还在
        let plugin = try makePlugin(named: "冗余副本插件", source: .userEffects, contents: "原插件内容")
        let viewModel = makeViewModel()
        let entry = root.appendingPathComponent("Disabled/StaleEntry", isDirectory: true)
        let payload = entry.appendingPathComponent("Plugin", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try "copy".write(to: payload.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        let metadata: [String: Any] = [
            "originalPath": plugin.path,
            "category": "效果",
            "isSystemLevel": "false"
        ]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: entry.appendingPathComponent(".metadata"))

        viewModel.refreshDisabledState()
        let item = try XCTUnwrap(viewModel.disabledItems.first { $0.entryPath.hasSuffix("/StaleEntry") })
        XCTAssertFalse(item.isEffective, "原位置还在，不能算已停用")

        let result = await viewModel.enableDisabled(item)
        guard case .successWithWarning = result else {
            return XCTFail("应清理副本并给出提示，实际是 \(result)")
        }
        XCTAssertEqual(contents(of: plugin.path), "原插件内容", "原插件不能被改动")
        XCTAssertFalse(fm.fileExists(atPath: item.entryPath), "多余的副本记录应被清理")
        XCTAssertTrue(viewModel.disabledItems.isEmpty)
    }

    func testBulkDisableOnlyAffectsGivenScope() async throws {
        let effect = try makePlugin(named: "效果A", source: .userEffects)
        let transition = try makePlugin(named: "转场A", source: .userTransitions)
        let viewModel = makeViewModel()

        let outcome = await viewModel.disableAll([effect])
        XCTAssertEqual(outcome.disabledNames, [effect.name])
        XCTAssertTrue(fm.fileExists(atPath: transition.path), "未传入的转场不能被禁用")
        XCTAssertFalse(fm.fileExists(atPath: effect.path))
        XCTAssertEqual(viewModel.disabledItems.count, 1)
        XCTAssertEqual(viewModel.disabledItems.first?.category, .effects)
    }

    // MARK: - 操作日志与撤销

    func testOperationLogPersistsAndUndoRestoresDeletedPlugin() async throws {
        let plugin = try makePlugin(named: "可撤销插件", contents: "撤销内容")
        let viewModel = makeViewModel()

        guard case .deleted(let backup) = await viewModel.backupAndRecycle(plugin) else {
            return XCTFail("应备份并删除成功")
        }
        viewModel.addOperation(kind: .deletePlugins, summary: "备份并删除 1 个插件", backups: [backup])

        // 重新创建一个 ViewModel，确认日志落盘
        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.operations.count, 1)
        let record = try XCTUnwrap(reloaded.lastUndoableOperation)

        let outcome = await reloaded.undo(record)
        XCTAssertEqual(outcome.restoredCount, 1)
        XCTAssertTrue(outcome.isComplete, "撤销不应有失败：\(outcome.failures)")
        XCTAssertEqual(contents(of: plugin.path), "撤销内容")
        XCTAssertTrue(reloaded.operations.first?.undone == true, "撤销后应标记为已撤销")
    }

    func testUndoOfDisableReenablesPlugin() async throws {
        let plugin = try makePlugin(named: "撤销禁用", contents: "重新启用内容")
        let viewModel = makeViewModel()

        guard case .disabled(let item) = await viewModel.disablePlugin(plugin) else {
            return XCTFail("禁用应成功")
        }
        viewModel.addOperation(kind: .disablePlugins, summary: "禁用 1 个插件", disabled: [item])

        let record = try XCTUnwrap(viewModel.lastUndoableOperation)
        let outcome = await viewModel.undo(record)
        XCTAssertEqual(outcome.restoredCount, 1)
        XCTAssertEqual(contents(of: plugin.path), "重新启用内容")
    }

    // MARK: - 扫描（注入临时根目录）

    func testScannerUsesInjectedRoots() throws {
        let sample = root.appendingPathComponent("Sample/Effects.localized", isDirectory: true)
        try fm.createDirectory(at: sample, withIntermediateDirectories: true)
        try fm.createDirectory(at: sample.appendingPathComponent("插件一"), withIntermediateDirectories: true)
        try "x".write(to: sample.appendingPathComponent("封面.png"), atomically: true, encoding: .utf8)

        let scanner = PluginScanner(roots: [ScanRoot(source: .userEffects, url: sample)])
        let report = scanner.scan()

        XCTAssertEqual(report.locations.count, 1)
        XCTAssertEqual(report.locations.first?.foundCount, 1)
        XCTAssertEqual(report.items.map(\.name), ["插件一"])
    }

    func testScannerReportsMissingRoot() throws {
        let missing = root.appendingPathComponent("NotThere", isDirectory: true)
        let scanner = PluginScanner(roots: [ScanRoot(source: .userTitles, url: missing)])
        let report = scanner.scan()

        XCTAssertEqual(report.locations.count, 1)
        XCTAssertEqual(report.locations.first?.exists, false)
        XCTAssertTrue(report.items.isEmpty)
    }

    // MARK: - 详情字段

    func testPluginDetailReadsVendorVersionSizeAndDate() throws {
        let bundle = root.appendingPathComponent("Plugins/Details.fxplug/Contents", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleShortVersionString": "2.5.1",
            "CFBundleIdentifier": "com.example.details",
            "NSHumanReadableCopyright": "Copyright © Example Vendor"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        try String(repeating: "x", count: 1024)
            .write(to: bundle.appendingPathComponent("payload.bin"), atomically: true, encoding: .utf8)

        let plugin = try XCTUnwrap(PluginItem(
            path: root.appendingPathComponent("Plugins/Details.fxplug").path,
            source: .userPlugIns
        ))

        XCTAssertEqual(plugin.version, "2.5.1")
        XCTAssertEqual(plugin.bundleIdentifier, "com.example.details")
        XCTAssertEqual(plugin.vendor, "Copyright © Example Vendor")
        // 体积按磁盘占用块计算，只能确认至少覆盖 payload，不写死具体字节数
        XCTAssertGreaterThanOrEqual(plugin.sizeBytes ?? 0, Int64(1024))
        XCTAssertNotNil(plugin.installDate)
        XCTAssertFalse(plugin.sizeDescription?.isEmpty ?? true)
        XCTAssertFalse(plugin.installDateDescription?.isEmpty ?? true)
    }

    // MARK: - 选中身份稳定

    func testPluginIdentityUsesPathAndStaysUniqueForDuplicateNames() throws {
        let first = try makePlugin(named: "重名插件", source: .userEffects, contents: "a")
        let second = try makePlugin(named: "重名插件", source: .userTransitions, contents: "b")

        XCTAssertNotEqual(first.id, second.id, "同名不同路径不能串号")
        XCTAssertEqual(first.id, first.path)
        XCTAssertEqual(second.id, second.path)
    }

    // MARK: - 停用是否真的生效

    func testPendingRecordIsNotCountedAsEffective() async throws {
        let plugin = try makePlugin(named: "待授权插件", source: .systemEffects)
        let viewModel = makeViewModel()
        guard case .needAuthentication(let item, _) = await viewModel.disablePlugin(plugin) else {
            return XCTFail("应返回待授权记录")
        }

        XCTAssertFalse(item.isEffective, "原文件还在，不能算已停用")
        XCTAssertTrue(item.originalExists)
        XCTAssertFalse(item.hasPayload)

        // 对「从没真正停用」的记录点恢复：只清记录，原插件不动
        let outcome = await viewModel.enableAllDisabled([item])
        XCTAssertEqual(outcome.enabledNames.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "恢复不能动原插件")
        XCTAssertTrue(viewModel.disabledItems.isEmpty, "待授权记录应被清掉")
    }

    // MARK: - 改名

    func testRenameChangesFolderAndUpdatesBackupPath() async throws {
        let plugin = try makePlugin(named: "旧名字", contents: "内容")
        let viewModel = makeViewModel()
        guard case .success(let backup) = await viewModel.backupPlugin(plugin) else {
            return XCTFail("备份应成功")
        }

        let result = await viewModel.renamePlugin(plugin, to: "新名字")
        guard case .success(let oldPath, let newPath, let updated) = result else {
            return XCTFail("改名应成功，实际是 \(result)")
        }
        XCTAssertEqual(oldPath, plugin.path)
        XCTAssertTrue(newPath.hasSuffix("/新名字"))
        XCTAssertFalse(fm.fileExists(atPath: oldPath))
        XCTAssertTrue(fm.fileExists(atPath: newPath))
        XCTAssertEqual(updated, 1, "备份记录的 originalPath 应同步更新")
        XCTAssertEqual(viewModel.backups.first?.originalPath, newPath)
    }

    func testRenameRejectsInvalidAndDuplicateNames() async throws {
        let plugin = try makePlugin(named: "原名")
        let existing = try makePlugin(named: "已存在")
        let viewModel = makeViewModel()

        XCTAssertNotNil(viewModel.validateNewName("", for: plugin))
        XCTAssertNotNil(viewModel.validateNewName("a/b", for: plugin))
        XCTAssertNotNil(viewModel.validateNewName("..", for: plugin))
        XCTAssertNotNil(viewModel.validateNewName("已存在", for: plugin))
        XCTAssertNil(viewModel.validateNewName("可以", for: plugin))

        let result = await viewModel.renamePlugin(plugin, to: "已存在")
        guard case .failure = result else {
            return XCTFail("重名必须拒绝，实际是 \(result)")
        }
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "拒绝时不能改动任何文件")
        XCTAssertTrue(fm.fileExists(atPath: existing.path))
    }

    func testRenameUndoMovesFolderBack() async throws {
        let plugin = try makePlugin(named: "撤销前名字")
        let viewModel = makeViewModel()
        guard case .success(let oldPath, let newPath, _) = await viewModel.renamePlugin(plugin, to: "撤销后名字") else {
            return XCTFail("改名应成功")
        }
        viewModel.addOperation(
            kind: .renamePlugin,
            summary: "重命名",
            renames: [RenameSnapshot(oldPath: oldPath, newPath: newPath)]
        )
        let record = try XCTUnwrap(viewModel.lastUndoableOperation)
        let outcome = await viewModel.undo(record)
        XCTAssertEqual(outcome.restoredCount, 1)
        XCTAssertTrue(fm.fileExists(atPath: oldPath))
        XCTAssertFalse(fm.fileExists(atPath: newPath))
    }

    func testSystemLevelRenameReturnsAdminCommand() async throws {
        let plugin = try makePlugin(named: "系统插件", source: .systemEffects)
        let viewModel = makeViewModel()
        guard case .needAuthentication(let oldPath, let newPath, _) = await viewModel.renamePlugin(plugin, to: "新系统插件") else {
            return XCTFail("系统级改名应走管理员命令")
        }
        XCTAssertEqual(oldPath, plugin.path)
        XCTAssertTrue(newPath.hasSuffix("/新系统插件"))
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "CLI/界面都不能静默改系统级插件")

        let command = AdminCommandBuilder.renameCommand(oldPath: oldPath, newPath: newPath)
        XCTAssertTrue(command.hasPrefix("sudo mv "))
        XCTAssertTrue(command.contains("系统插件"))
    }

    func testAdminCommandQuotesPathsWithSpacesAndQuotes() {
        let item = DisabledItem(
            name: "名字",
            currentPath: "/tmp/a b/Plugin's",
            entryPath: "/tmp/a b/entry",
            originalPath: "/Library/Plug-ins/FxPlug/My Plugin",
            category: .effects,
            isSystemLevel: true,
            disabledDate: nil
        )
        let script = AdminCommandBuilder.disableScript(for: [item])
        XCTAssertTrue(script.contains("'/Library/Plug-ins/FxPlug/My Plugin'"))
        XCTAssertTrue(script.contains("'/tmp/a b/Plugin'\\''s'"), "单引号必须正确转义，实际：\(script)")
    }
}
