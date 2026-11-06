import XCTest
@testable import FCPXPluginManager

/// 译名表解析 + 改名台账 + 恢复原名的回归测试。
/// 全部在临时目录里跑，不接触真实插件目录。
@MainActor
final class RenameLedgerTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPPluginManagerLedgerTests-\(UUID().uuidString)", isDirectory: true)
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

    private func makeViewModel() -> PluginViewModel {
        PluginViewModel(storageRootOverride: root)
    }

    private func ledgerEntries(from viewModel: PluginViewModel) -> [RenameLedgerEntry] {
        viewModel.renameLedger
    }

    // MARK: - 译名表解析

    func testCSVParserHandlesHeaderQuotedCommaAndTab() throws {
        let csv = """
        原名,新名字
        插件A,Plugin A
        "插件,带逗号",Comma Name
        """
        let entries = try RenameMapParser.parse(data: Data(csv.utf8), fileExtension: "csv")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].key, "插件A")
        XCTAssertEqual(entries[0].newName, "Plugin A")
        XCTAssertEqual(entries[0].line, 2)
        XCTAssertEqual(entries[1].key, "插件,带逗号")
        XCTAssertEqual(entries[1].newName, "Comma Name")
        XCTAssertEqual(entries[1].line, 3)

        let tsv = "插件B\tPlugin B\n"
        let tabEntries = try RenameMapParser.parse(data: Data(tsv.utf8))
        XCTAssertEqual(tabEntries.first?.key, "插件B")
        XCTAssertEqual(tabEntries.first?.newName, "Plugin B")
    }

    func testCSVParserReportsLineNumberForBadRow() {
        let csv = """
        原名,新名字
        插件A,Plugin A
        只有一列
        """
        XCTAssertThrowsError(try RenameMapParser.parse(data: Data(csv.utf8), fileExtension: "csv")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("第 3 行"), "错误应指出第 3 行，实际：\(message)")
        }
    }

    func testJSONParserSupportsDictionaryAndArray() throws {
        let dict = #"{"插件A":"Plugin A","插件B":"Plugin B"}"#
        let dictEntries = try RenameMapParser.parse(data: Data(dict.utf8), fileExtension: "json")
        XCTAssertEqual(dictEntries.count, 2)

        let array = #"[{"path":"/tmp/插件A","name":"Plugin A"}]"#
        let arrayEntries = try RenameMapParser.parse(data: Data(array.utf8), fileExtension: "json")
        XCTAssertEqual(arrayEntries.first?.key, "/tmp/插件A")
        XCTAssertEqual(arrayEntries.first?.newName, "Plugin A")
    }

    func testParserRejectsEmptyName() {
        let csv = "插件A,\n"
        XCTAssertThrowsError(try RenameMapParser.parse(data: Data(csv.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("新名字为空"))
        }
    }

    // MARK: - 改名台账

    func testRenameRecordsLedgerAndRestoresOriginalName() async throws {
        let plugin = try makePlugin(named: "原名插件")
        let viewModel = makeViewModel()

        guard case .success = await viewModel.renamePlugin(plugin, to: "新名字插件") else {
            return XCTFail("改名应成功")
        }
        let entries = ledgerEntries(from: viewModel)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.oldName, "原名插件")
        XCTAssertEqual(entries.first?.newName, "新名字插件")
        XCTAssertEqual(entries.first?.directory, plugin.path.replacingOccurrences(of: "/原名插件", with: ""))
        XCTAssertEqual(entries.first?.status, .applied)

        let renamedPath = root
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(PluginSource.userEffects.shortLocation, isDirectory: true)
            .appendingPathComponent("新名字插件").path
        XCTAssertTrue(fm.fileExists(atPath: renamedPath))

        guard let entry = entries.first else { return XCTFail("台账为空") }
        switch await viewModel.restoreOriginalName(entry) {
        case .success(let oldName):
            XCTAssertEqual(oldName, "原名插件")
        default:
            return XCTFail("应恢复原名成功")
        }
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "应改回原名")
        XCTAssertFalse(fm.fileExists(atPath: renamedPath), "新名字目录应消失")
        XCTAssertEqual(viewModel.renameLedger.first?.status, .restored)
    }

    func testRestoreOriginalNameRefusesWhenTargetExists() async throws {
        let plugin = try makePlugin(named: "原名插件")
        let viewModel = makeViewModel()

        guard case .success = await viewModel.renamePlugin(plugin, to: "新名字插件") else {
            return XCTFail("改名应成功")
        }
        guard let entry = viewModel.renameLedger.first else { return XCTFail("台账为空") }

        // 把原名位置重新占住
        try fm.createDirectory(atPath: plugin.path, withIntermediateDirectories: true)

        switch await viewModel.restoreOriginalName(entry) {
        case .targetExists(let reason):
            XCTAssertTrue(reason.contains("不覆盖"), "应说明不覆盖，实际：\(reason)")
        default:
            XCTFail("目标已存在时应拒绝")
        }
        XCTAssertTrue(fm.fileExists(atPath: entry.newPath), "改名后的插件不能被删")
        XCTAssertEqual(viewModel.renameLedger.first?.status, .applied, "拒绝后状态不变")
    }

    func testLedgerSurvivesRestartAndFiltersByCategory() async throws {
        let effect = try makePlugin(named: "效果插件", source: .userEffects)
        let transition = try makePlugin(named: "转场插件", source: .userTransitions)
        let viewModel = makeViewModel()

        guard case .success = await viewModel.renamePlugin(effect, to: "Effect Plugin") else {
            return XCTFail("效果改名失败")
        }
        guard case .success = await viewModel.renamePlugin(transition, to: "Transition Plugin") else {
            return XCTFail("转场改名失败")
        }
        XCTAssertEqual(viewModel.renameLedgerEntries(in: .effects).count, 1)
        XCTAssertEqual(viewModel.renameLedgerEntries(in: .transitions).count, 1)
        XCTAssertEqual(viewModel.renameLedgerEntries(in: .all).count, 2)

        // 新实例读同一个存储目录，台账应还在
        let reopened = makeViewModel()
        XCTAssertEqual(reopened.renameLedger.count, 2)
        XCTAssertEqual(reopened.renameLedgerEntries(in: .effects).first?.newName, "Effect Plugin")
    }

    func testCorruptLedgerIsReportedInsteadOfGuessing() throws {
        let dir = root.appendingPathComponent("Renames", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("ledger.json"))

        let viewModel = makeViewModel()
        XCTAssertTrue(viewModel.renameLedger.isEmpty)
        XCTAssertNotNil(viewModel.renameLedgerProblem, "台账损坏必须明确提示，不能静默")
        XCTAssertTrue(viewModel.renameLedgerProblem?.contains("原名") == true)
    }

    func testSystemLevelRenameIsPendingUntilCommandRuns() async throws {
        let plugin = try makePlugin(named: "系统插件", source: .systemEffects)
        let viewModel = makeViewModel()

        guard case .needAuthentication(_, let newPath, _) = await viewModel.renamePlugin(plugin, to: "System Plugin") else {
            return XCTFail("系统级改名应返回管理员命令")
        }
        XCTAssertEqual(viewModel.renameLedger.first?.status, .renamePending)
        XCTAssertTrue(fm.fileExists(atPath: plugin.path), "未执行命令前不能动原文件")

        // 模拟用户执行 sudo mv
        try fm.moveItem(atPath: plugin.path, toPath: newPath)
        viewModel.refreshRenameLedgerStatuses()
        XCTAssertEqual(viewModel.renameLedger.first?.status, .applied)
    }

    // MARK: - 译名表预览

    func testBuildRenamePlanMarksReadyFailedAndAdmin() throws {
        let user = try makePlugin(named: "用户插件", source: .userEffects)
        let system = try makePlugin(named: "系统插件", source: .systemEffects)
        let viewModel = makeViewModel()
        viewModel.plugins = [user, system]

        let entries = [
            RenameMapEntry(line: 1, key: "用户插件", newName: "User Plugin"),
            RenameMapEntry(line: 2, key: "系统插件", newName: "System Plugin"),
            RenameMapEntry(line: 3, key: "不存在的插件", newName: "Nope"),
            RenameMapEntry(line: 4, key: "用户插件", newName: "Bad/Name")
        ]
        let plan = viewModel.buildRenamePlan(entries: entries)

        XCTAssertEqual(plan.total, 4)
        XCTAssertEqual(plan.readyCount, 1)
        XCTAssertEqual(plan.adminCount, 1)
        XCTAssertEqual(plan.failedCount, 2)

        guard case .ready = plan.items[0].status else { return XCTFail("用户级应可改名") }
        guard case .adminRequired(let command) = plan.items[1].status else {
            return XCTFail("系统级应给管理员命令")
        }
        XCTAssertTrue(command.contains("sudo mv"))
        guard case .failed(let reason) = plan.items[2].status else {
            return XCTFail("不存在的插件应失败")
        }
        XCTAssertTrue(reason.contains("找不到"))
        guard case .failed = plan.items[3].status else {
            return XCTFail("非法名字应失败")
        }
    }

    func testApplyRenamePlanLogsRenameAndKeepsLedger() async throws {
        let plugin = try makePlugin(named: "批量插件")
        let viewModel = makeViewModel()
        viewModel.plugins = [plugin]

        let plan = viewModel.buildRenamePlan(
            entries: [RenameMapEntry(line: 1, key: "批量插件", newName: "Batch Plugin")]
        )
        let outcome = await viewModel.applyRenamePlan(plan)
        XCTAssertEqual(outcome.renames.count, 1)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(viewModel.renameLedger.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: outcome.renames[0].newPath))
    }
}
