import XCTest
@testable import FCPXPluginManager

/// P0 数据安全回归测试。
/// 所有文件操作都在系统临时目录里，不接触真实插件目录和 Application Support。
@MainActor
final class P0DataSafetyTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var backupRoot: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPPluginManagerTests-\(UUID().uuidString)", isDirectory: true)
        backupRoot = root.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func makePlugin(named name: String = "测试插件", contents: String = "v1") throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Effects.localized", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginItem(path: dir.path, source: .userEffects))
    }

    private func makeViewModel(backupDirectory: URL) -> PluginViewModel {
        // 统一用临时根目录，备份放在 root/Backups
        if backupDirectory == backupRoot {
            return PluginViewModel(storageRootOverride: root)
        }
        return PluginViewModel(storageRootOverride: backupDirectory)
    }

    private func contentsOfPlugin(_ plugin: PluginItem) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: plugin.path).appendingPathComponent("info.txt"), encoding: .utf8)
    }

    // MARK: - P0-1 备份失败必须中止删除

    func testBackupFailureSkipsDeletion() async throws {
        let plugin = try makePlugin()
        // 用一个普通文件冒充备份目录，复制必然失败
        let notADirectory = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try "x".write(to: notADirectory, atomically: true, encoding: .utf8)

        let viewModel = makeViewModel(backupDirectory: notADirectory)
        let result = await viewModel.backupAndRecycle(plugin)

        guard case .backupFailed = result else {
            return XCTFail("备份失败时应返回 .backupFailed，实际是 \(result)")
        }
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "备份失败后插件必须原封不动")
        XCTAssertEqual(try contentsOfPlugin(plugin), "v1")
        XCTAssertTrue(viewModel.backups.isEmpty, "失败的备份不应出现在备份列表里")
    }

    // MARK: - P0-2 备份重名不删旧备份

    func testBackupWithSameDateKeepsBothBackups() async throws {
        let plugin = try makePlugin()
        let viewModel = makeViewModel(backupDirectory: backupRoot)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        guard case .success(let first) = await viewModel.backupPlugin(plugin, date: fixedDate) else {
            return XCTFail("第一次备份应成功")
        }
        guard case .success(let second) = await viewModel.backupPlugin(plugin, date: fixedDate) else {
            return XCTFail("同名第二次备份应成功")
        }

        XCTAssertNotEqual(first.backupPath, second.backupPath)
        XCTAssertTrue(fm.fileExists(atPath: first.backupPath), "旧备份不能被删除")
        XCTAssertTrue(fm.fileExists(atPath: second.backupPath))
        XCTAssertTrue(second.backupPath.hasSuffix("-2"), "重名应追加序号，实际：\(second.backupPath)")
        XCTAssertTrue(
            fm.fileExists(atPath: URL(fileURLWithPath: first.backupPath).appendingPathComponent(".metadata").path),
            "备份必须带 .metadata，否则无法恢复"
        )
    }

    // MARK: - P0-3 恢复时目标已存在先确认

    func testRestoreDoesNotOverwriteExistingTargetWithoutConfirmation() async throws {
        let plugin = try makePlugin(contents: "备份内容")
        let viewModel = makeViewModel(backupDirectory: backupRoot)
        guard case .success(let backup) = await viewModel.backupPlugin(plugin) else {
            return XCTFail("备份应成功")
        }

        // 模拟用户之后又装了一个同名插件
        try fm.removeItem(at: URL(fileURLWithPath: plugin.path))
        try fm.createDirectory(atPath: plugin.path, withIntermediateDirectories: true)
        try "新装内容".write(
            to: URL(fileURLWithPath: plugin.path).appendingPathComponent("info.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(viewModel.restoreTargetExists(for: backup))

        let result = await viewModel.restoreBackup(backup, overwriteExisting: false)
        guard case .targetExists = result else {
            return XCTFail("目标已存在时应返回 .targetExists，实际是 \(result)")
        }
        XCTAssertEqual(try contentsOfPlugin(plugin), "新装内容", "未确认时不能覆盖")
        XCTAssertTrue(fm.fileExists(atPath: backup.backupPath), "未确认时备份应保留")
    }

    func testRestoreWithConfirmationRecyclesExistingTarget() async throws {
        let plugin = try makePlugin(contents: "备份内容")
        let viewModel = makeViewModel(backupDirectory: backupRoot)
        guard case .success(let backup) = await viewModel.backupPlugin(plugin) else {
            return XCTFail("备份应成功")
        }

        try fm.removeItem(at: URL(fileURLWithPath: plugin.path))
        try fm.createDirectory(atPath: plugin.path, withIntermediateDirectories: true)
        try "新装内容".write(
            to: URL(fileURLWithPath: plugin.path).appendingPathComponent("info.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = await viewModel.restoreBackup(backup, overwriteExisting: true)
        guard case .success = result else {
            return XCTFail("确认覆盖后应恢复成功，实际是 \(result)")
        }
        XCTAssertEqual(try contentsOfPlugin(plugin), "备份内容", "恢复后应是备份内容")
        XCTAssertFalse(fm.fileExists(atPath: backup.backupPath), "恢复成功后备份目录应被消费掉")
    }

    func testRestoreRejectsBackupWithoutOriginalPath() async throws {
        let viewModel = makeViewModel(backupDirectory: backupRoot)
        let orphanBackup = root.appendingPathComponent("Orphan", isDirectory: true)
        try fm.createDirectory(at: orphanBackup, withIntermediateDirectories: true)

        let backup = BackupItem(
            name: "Orphan",
            backupPath: orphanBackup.path,
            originalPath: "",
            category: .effects,
            isSystemLevel: false
        )
        let result = await viewModel.restoreBackup(backup)
        guard case .failure = result else {
            return XCTFail("缺少 originalPath 的备份必须拒绝恢复，实际是 \(result)")
        }
    }

    // MARK: - P0-4 删除统一走系统回收站

    func testRecycleRefusesSystemLevelPath() async {
        let result = await PluginService.recycle("/Library/Application Support/Final Cut Pro/Templates.localized")
        guard case .needAuthentication = result else {
            return XCTFail("系统级路径应返回 .needAuthentication，实际是 \(result)")
        }
    }

    func testRecycleMovesFileIntoTrash() async throws {
        let file = root.appendingPathComponent("RecycleMe-\(UUID().uuidString).txt")
        try "trash".write(to: file, atomically: true, encoding: .utf8)

        let result = await PluginService.recycle(file.path)
        guard case .success = result else {
            return XCTFail("移入废纸篓应成功，实际是 \(result)")
        }
        XCTAssertFalse(fm.fileExists(atPath: file.path), "文件应已离开原位置")
    }

    // MARK: - P1 扫描：同样只用临时目录

    func testScannerSkipsContainersImagesAndPlainFiles() throws {
        let sample = root.appendingPathComponent("Sample/Effects.localized", isDirectory: true)
        try fm.createDirectory(at: sample, withIntermediateDirectories: true)
        // 真正的插件目录
        try fm.createDirectory(at: sample.appendingPathComponent("我的插件"), withIntermediateDirectories: true)
        // FCP / FxFactory 的分组容器，应跳过
        try fm.createDirectory(at: sample.appendingPathComponent("1128.localized"), withIntermediateDirectories: true)
        // 模板目录里混着的图片，应跳过
        try "x".write(to: sample.appendingPathComponent("poster.png"), atomically: true, encoding: .utf8)
        // 普通文本文件，应跳过
        try "x".write(to: sample.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        // 插件包，应保留
        try fm.createDirectory(at: sample.appendingPathComponent("NeatVideo.fxplug"), withIntermediateDirectories: true)

        let items = PluginScanner().scanDirectory(sample, source: .userEffects)
        XCTAssertEqual(Set(items.map(\.name)), ["我的插件", "NeatVideo.fxplug"])
    }

    func testScannerReadsVersionFromBundleInfoPlist() throws {
        let bundleContents = root
            .appendingPathComponent("Sample/Effects.localized/Test.fxplug/Contents", isDirectory: true)
        try fm.createDirectory(at: bundleContents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleVersion": "1.2.3"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleContents.appendingPathComponent("Info.plist"))

        let items = PluginScanner().scanDirectory(
            root.appendingPathComponent("Sample/Effects.localized", isDirectory: true),
            source: .userEffects
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.version, "1.2.3")
    }
}
