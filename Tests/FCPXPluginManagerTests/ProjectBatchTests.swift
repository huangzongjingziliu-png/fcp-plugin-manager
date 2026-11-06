import XCTest
@testable import FCPXPluginManager

/// 工程停用批次：精确恢复、跨工程不混淆、单个失败不中断。
/// 全部在临时目录里做，不碰真实插件目录。
@MainActor
final class ProjectBatchTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPBatchTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    private func makePlugin(named name: String, source: PluginSource = .userEffects) throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent(source.shortLocation, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "v1".write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginItem(path: dir.path, source: source))
    }

    private func makeViewModel() -> PluginViewModel {
        PluginViewModel(storageRootOverride: root) { _ in
            AdminRunResult(succeeded: false, message: "测试未注入管理员执行器")
        }
    }

    private func disable(_ plugin: PluginItem, in viewModel: PluginViewModel) async throws -> DisabledItem {
        switch await viewModel.disablePlugin(plugin) {
        case .disabled(let item):
            return item
        case .needAuthentication:
            throw XCTSkip("测试插件不应需要管理员权限")
        case .failure(let message):
            XCTFail("停用失败：\(message)")
            throw NSError(domain: "test", code: 1)
        }
    }

    // MARK: - 记录与持久化

    func testRecordBatchPersistsAcrossLaunches() async throws {
        let a = try makePlugin(named: "效果A")
        let b = try makePlugin(named: "效果B")
        let viewModel = makeViewModel()
        let itemA = try await disable(a, in: viewModel)
        let itemB = try await disable(b, in: viewModel)

        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "宣传片",
            projectPath: "/tmp/宣传片.fcpxml",
            disabled: [itemA, itemB],
            includedSystem: false
        ))
        XCTAssertEqual(batch.entries.count, 2)
        XCTAssertEqual(batch.pendingCount, 2)
        XCTAssertNil(batch.restoredAt)

        let reopened = makeViewModel()
        XCTAssertEqual(reopened.projectBatches.count, 1)
        let loaded = try XCTUnwrap(reopened.projectBatches.first)
        XCTAssertEqual(loaded.id, batch.id)
        XCTAssertEqual(loaded.projectName, "宣传片")
        XCTAssertEqual(Set(loaded.entries.map(\.originalPath)), [a.path, b.path])
        XCTAssertEqual(loaded.pendingCount, 2)
    }

    func testRecordBatchDeduplicatesSamePlugin() async throws {
        let a = try makePlugin(named: "重复效果")
        let viewModel = makeViewModel()
        let item = try await disable(a, in: viewModel)

        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "工程",
            projectPath: "/tmp/x.fcpxml",
            disabled: [item, item],
            includedSystem: false
        ))
        XCTAssertEqual(batch.entries.count, 1)
    }

    // MARK: - 精确恢复

    func testRestoreOnlyTouchesThisBatch() async throws {
        let a = try makePlugin(named: "批次效果A")
        let b = try makePlugin(named: "批次效果B")
        let manual = try makePlugin(named: "手动停用的")
        let viewModel = makeViewModel()

        let itemA = try await disable(a, in: viewModel)
        let itemB = try await disable(b, in: viewModel)
        _ = try await disable(manual, in: viewModel)

        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "工程A",
            projectPath: "/tmp/A.fcpxml",
            disabled: [itemA, itemB],
            includedSystem: false
        ))

        let outcome = await viewModel.restoreProjectBatch(batch.id)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(Set(outcome.restored), ["批次效果A", "批次效果B"])

        // 这一批回到原位
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertTrue(fm.fileExists(atPath: b.path))
        // 手动停用的没被动
        XCTAssertFalse(fm.fileExists(atPath: manual.path))
        XCTAssertTrue(
            viewModel.disabledItems.contains { $0.name == "手动停用的" },
            "手动停用的记录应保留，实际：\(viewModel.disabledItems.map(\.name))"
        )

        let stored = try XCTUnwrap(viewModel.projectBatches.first { $0.id == batch.id })
        XCTAssertTrue(stored.isFullyRestored)
        XCTAssertNotNil(stored.restoredAt)
        XCTAssertEqual(stored.pendingCount, 0)
    }

    func testRestoreIsIdempotent() async throws {
        let a = try makePlugin(named: "只恢复一次")
        let viewModel = makeViewModel()
        let item = try await disable(a, in: viewModel)
        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "工程",
            projectPath: "/tmp/once.fcpxml",
            disabled: [item],
            includedSystem: false
        ))

        _ = await viewModel.restoreProjectBatch(batch.id)
        let second = await viewModel.restoreProjectBatch(batch.id)
        XCTAssertTrue(second.restored.isEmpty)
        XCTAssertTrue(second.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    // MARK: - 跨工程不混淆

    func testDifferentProjectsKeepSeparateBatches() async throws {
        let a = try makePlugin(named: "工程A专用")
        let b = try makePlugin(named: "工程B专用")
        let viewModel = makeViewModel()

        let itemA = try await disable(a, in: viewModel)
        let batchA = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "工程A",
            projectPath: "/tmp/项目/工程A.fcpxml",
            disabled: [itemA],
            includedSystem: false
        ))
        let itemB = try await disable(b, in: viewModel)
        let batchB = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "工程B",
            projectPath: "/tmp/项目/工程B.fcpxml",
            disabled: [itemB],
            includedSystem: false
        ))

        XCTAssertEqual(viewModel.batches(forProjectPath: "/tmp/项目/工程A.fcpxml").map(\.id), [batchA.id])
        XCTAssertEqual(viewModel.batches(forProjectPath: "/tmp/项目/工程B.fcpxml").map(\.id), [batchB.id])
        XCTAssertTrue(viewModel.batches(forProjectPath: "/tmp/项目/工程C.fcpxml").isEmpty)

        // 恢复 A 的批次，不能碰 B 的停用项
        _ = await viewModel.restoreProjectBatch(batchA.id)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path), "另一个工程停用的插件必须保持停用")

        let storedB = try XCTUnwrap(viewModel.projectBatches.first { $0.id == batchB.id })
        XCTAssertTrue(storedB.hasPending)
        XCTAssertEqual(storedB.pendingCount, 1)
    }

    // MARK: - 单个失败不中断

    func testMissingRecordIsSkippedAndDoesNotBlockOthers() async throws {
        let a = try makePlugin(named: "能恢复的")
        let viewModel = makeViewModel()
        let item = try await disable(a, in: viewModel)
        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "混合批次",
            projectPath: "/tmp/mixed.fcpxml",
            disabled: [item],
            includedSystem: false
        ))

        // 人为加一条找不到禁用记录的条目，模拟用户已在别处恢复过
        viewModel.projectBatches[0].entries.append(
            ProjectBatchEntry(
                pluginName: "已经没记录的",
                originalPath: "/tmp/从未停用过/已经没记录的",
                disabledRecordID: "/tmp/从未停用过/记录",
                category: PluginCategory.effects.rawValue,
                isSystemLevel: false,
                state: .pending,
                note: nil
            )
        )

        let outcome = await viewModel.restoreProjectBatch(batch.id)
        XCTAssertEqual(outcome.restored, ["能恢复的"])
        XCTAssertEqual(outcome.skipped, ["已经没记录的"])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path), "一条记录缺失不能影响其它插件恢复")

        let stored = try XCTUnwrap(viewModel.projectBatches.first { $0.id == batch.id })
        XCTAssertEqual(stored.restoredCount, 1)
        XCTAssertEqual(stored.skippedCount, 1)
        XCTAssertEqual(stored.pendingCount, 0)
        XCTAssertNotNil(stored.restoredAt)
    }

    func testFailureKeepsEntryPendingForRetry() async throws {
        let a = try makePlugin(named: "会被卡住的")
        let viewModel = makeViewModel()
        let item = try await disable(a, in: viewModel)
        let batch = try XCTUnwrap(viewModel.recordProjectBatch(
            projectName: "失败批次",
            projectPath: "/tmp/fail.fcpxml",
            disabled: [item],
            includedSystem: false
        ))

        // 把禁用目录里的插件本体删掉，恢复时必然失败（但记录还在）
        try fm.removeItem(at: URL(fileURLWithPath: item.currentPath))

        let outcome = await viewModel.restoreProjectBatch(batch.id)
        XCTAssertEqual(outcome.failed, ["会被卡住的"])
        XCTAssertTrue(fm.fileExists(atPath: item.entryPath), "失败时不能破坏禁用记录")

        let stored = try XCTUnwrap(viewModel.projectBatches.first { $0.id == batch.id })
        XCTAssertEqual(stored.pendingCount, 1, "失败条目保留 pending，方便再点一次重试")
        XCTAssertNil(stored.restoredAt)
        XCTAssertNotNil(stored.entries.first?.note)
    }
}
