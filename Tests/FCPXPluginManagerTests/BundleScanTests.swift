import XCTest
import SQLite3
@testable import FCPXPluginManager

/// .fcpbundle 只读解析测试。
/// 夹具用 SQLite + NSKeyedArchiver（二进制 plist）按真实库结构伪造，
/// 覆盖单事件单工程、多事件、空工程、字段缺失、损坏文件。
@MainActor
final class BundleScanTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    // 真实格式的归档片段（由 NSKeyedArchiver 生成，内容已脱敏）
    private static let eventBlob = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGHiFZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKnBwgJCgsME1UkbnVsbFtkaXNwbGF5TmFtZVxyZWxhdGl2ZVBhdGhjbTtSqABBVzAxRXZlbnTSDQ4PEFgkY2xhc3Nlc1okY2xhc3NuYW1loxAREl8QE05TTXV0YWJsZURpY3Rpb25hcnlcTlNEaWN0aW9uYXJ5WE5TT2JqZWN00xQVFhcYG1YkY2xhc3NXTlMua2V5c1pOUy5vYmplY3RzgAWiGRqAAYACohwdgAOABNEfIFRyb290gAYSAAGGoAAIABEAGwAkACkAMgBEAEwAUgBeAGsAcgB6AH8AiACTAJcArQC6AMMAygDRANkA5ADmAOkA6wDtAPAA8gD0APcA/AD+AAAAAAAAAgEAAAAAAAAAIgAAAAAAAAAAAAAAAAAAAQM=
    """)!

    private static let projectBlob = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGHSBZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKnBwgJCgoLElUkbnVsbFtkaXNwbGF5TmFtZVxyZWxhdGl2ZVBhdGhSUjHSDA0OD1gkY2xhc3Nlc1okY2xhc3NuYW1low8QEV8QE05TTXV0YWJsZURpY3Rpb25hcnlcTlNEaWN0aW9uYXJ5WE5TT2JqZWN00xMUFRYXGlYkY2xhc3NXTlMua2V5c1pOUy5vYmplY3RzgAWiGBmAAYACohscgAOABNEeH1Ryb290gAYSAAGGoAgRGyQpMkRMUl5rbnN8h4uhrre+xc3Y2t3f4eTm6Ovw8gAAAAAAAAEBAAAAAAAAACEAAAAAAAAAAAAAAAAAAAD3
    """)!

    private static let effectBlob = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGIiVZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKpBwgJCgsMDQ4VVSRudWxsWGVmZmVjdElEW2Rpc3BsYXlOYW1lWmVmZmVjdFR5cGVfEDJ+L1RpdGxlcy5sb2NhbGl6ZWQvU2FtcGxlIFBsdWdpbi9TYW1wbGUgVGl0bGUubW90aVxTYW1wbGUgVGl0bGVeRkZNb3Rpb25FZmZlY3TSDxARElgkY2xhc3Nlc1okY2xhc3NuYW1loxITFF8QE05TTXV0YWJsZURpY3Rpb25hcnlcTlNEaWN0aW9uYXJ5WE5TT2JqZWN00xYXGBkaHlYkY2xhc3NXTlMua2V5c1pOUy5vYmplY3RzgAejGxwdgAGAAoADox8gIYAEgAWABtEjJFRyb290gAgSAAGGoAAIABEAGwAkACkAMgBEAE4AVABdAGkAdACpALYAxQDKANMA3gDiAPgBBQEOARUBHAEkAS8BMQE1ATcBOQE7AT8BQQFDAUUBSAFNAU8AAAAAAAACAQAAAAAAAAAmAAAAAAAAAAAAAAAAAAABVA==
    """)!

    private static let builtinBlob = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGHiFZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKnBwgJCgsME1UkbnVsbFhlZmZlY3RJRFtkaXNwbGF5TmFtZV8QD0ZGSGVDb2xvckVmZmVjdGKYnIJy0g0ODxBYJGNsYXNzZXNaJGNsYXNzbmFtZaMQERJfEBNOU011dGFibGVEaWN0aW9uYXJ5XE5TRGljdGlvbmFyeVhOU09iamVjdNMUFRYXGBtWJGNsYXNzV05TLmtleXNaTlMub2JqZWN0c4AFohkagAGAAqIcHYADgATRHyBUcm9vdIAGEgABhqAACAARABsAJAApADIARABMAFIAWwBnAHkAfgCDAIwAlwCbALEAvgDHAM4A1QDdAOgA6gDtAO8A8QD0APYA+AD7AQABAgAAAAAAAAIBAAAAAAAAACIAAAAAAAAAAAAAAAAAAAEH
    """)!

    private static let noNameBlob = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGGh1ZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKlBwgJChFVJG51bGxccmVsYXRpdmVQYXRoVzAxRXZlbnTSCwwNDlgkY2xhc3Nlc1okY2xhc3NuYW1low4PEF8QE05TTXV0YWJsZURpY3Rpb25hcnlcTlNEaWN0aW9uYXJ5WE5TT2JqZWN00xITFBUWGFYkY2xhc3NXTlMua2V5c1pOUy5vYmplY3RzgAOhF4ABoRmAAtEbHFRyb290gAQSAAGGoAgRGyQpMkRKUF1lanN+gpilrrW8xM/R09XX2dzh4wAAAAAAAAEBAAAAAAAAAB4AAAAAAAAAAAAAAAAAAADo
    """)!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPBundleScanTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
    }

    // MARK: - 夹具

    /// 按真实库结构建一个 .fcpbundle
    private func makeBundle(
        name: String = "测试库.fcpbundle",
        events: [(folder: String, nameBlob: Data?, projects: [(folder: String, nameBlob: Data?, blobs: [Data])])]
    ) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>catalogVersion</key><string>1193; 12.3 (450152)</string>
        </dict></plist>
        """.write(to: bundle.appendingPathComponent("CurrentVersion.plist"), atomically: true, encoding: .utf8)

        try makeDatabase(
            at: bundle.appendingPathComponent("CurrentVersion.flexolibrary"),
            rows: events.map { ("FFEventRecord", $0.nameBlob) }
        )

        for event in events {
            let eventDir = bundle.appendingPathComponent(event.folder, isDirectory: true)
            try fm.createDirectory(at: eventDir, withIntermediateDirectories: true)
            try makeDatabase(
                at: eventDir.appendingPathComponent("CurrentVersion.fcpevent"),
                rows: [("FFMediaEventProject", event.nameBlob)]
            )

            for project in event.projects {
                let projectDir = eventDir.appendingPathComponent(project.folder, isDirectory: true)
                try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
                var rows: [(String, Data?)] = [("FFMediaEventProject", project.nameBlob)]
                rows += project.blobs.map { ("FFMotionEffect", $0) }
                try makeDatabase(
                    at: projectDir.appendingPathComponent("CurrentVersion.fcpevent"),
                    rows: rows
                )
            }
        }
        return bundle
    }

    private func makeDatabase(at url: URL, rows: [(String, Data?)]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw XCTSkip("无法创建夹具数据库")
        }
        defer { sqlite3_close(database) }

        try exec(database, "CREATE TABLE ZCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZTYPE TEXT, ZIDENTIFIER TEXT)")
        try exec(database, "CREATE TABLE ZCOLLECTIONMD (Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZDICTIONARYDATA BLOB)")

        for (index, row) in rows.enumerated() {
            var collection: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                database,
                "INSERT INTO ZCOLLECTION (Z_PK, ZTYPE, ZIDENTIFIER) VALUES (?, ?, ?)",
                -1, &collection, nil
            ), SQLITE_OK)
            sqlite3_bind_int(collection, 1, Int32(index + 1))
            sqlite3_bind_text(collection, 2, row.0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(collection, 3, UUID().uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(collection), SQLITE_DONE)
            sqlite3_finalize(collection)

            guard let blob = row.1 else { continue }
            var metadata: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                database,
                "INSERT INTO ZCOLLECTIONMD (Z_PK, ZCOLLECTION, ZDICTIONARYDATA) VALUES (?, ?, ?)",
                -1, &metadata, nil
            ), SQLITE_OK)
            sqlite3_bind_int(metadata, 1, Int32(index + 1))
            sqlite3_bind_int(metadata, 2, Int32(index + 1))
            _ = blob.withUnsafeBytes { buffer in
                sqlite3_bind_blob(metadata, 3, buffer.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            XCTAssertEqual(sqlite3_step(metadata), SQLITE_DONE)
            sqlite3_finalize(metadata)
        }
    }

    private func exec(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw XCTSkip("夹具数据库建表失败：\(String(cString: sqlite3_errmsg(database)))")
        }
    }

    @discardableResult
    private func makePlugin(named name: String) throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent("用户/标题", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        </dict></plist>
        """.write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(PluginItem(path: dir.path, source: .userEffects))
    }

    private func makeViewModel() -> PluginViewModel {
        PluginViewModel(storageRootOverride: root) { _ in
            AdminRunResult(succeeded: false, message: "测试未注入管理员执行器")
        }
    }

    // MARK: - 解析

    func testReadsSingleEventSingleProject() async throws {
        let plugin = try makePlugin(named: "Sample Plugin")
        let bundle = try makeBundle(events: [
            (folder: "01Event", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob, Self.builtinBlob])
            ])
        ])

        let viewModel = makeViewModel()
        viewModel.plugins = [plugin]
        let result = try await viewModel.scanProject(at: bundle)

        let library = try XCTUnwrap(result.bundle)
        XCTAssertEqual(library.events.count, 1)
        XCTAssertEqual(library.projectCount, 1)
        XCTAssertEqual(library.events[0].name, "活动A")
        XCTAssertEqual(library.events[0].projects[0].name, "R1")

        let uids = library.events[0].projects[0].references.uids
        XCTAssertTrue(uids.contains("~/Titles.localized/Sample Plugin/Sample Title.moti"))
        XCTAssertFalse(uids.contains("FFHeColorEffect"), "内置效果不应被当成插件引用")

        XCTAssertTrue(result.parsed)
        XCTAssertEqual(result.usedPaths, [plugin.path], "库里的效果路径应匹配到已安装插件")
        XCTAssertTrue(viewModel.isProjectProtected(plugin))
    }

    func testReadsMultipleEventsAndProjects() async throws {
        let bundle = try makeBundle(events: [
            (folder: "01A", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob]),
                (folder: "R2", nameBlob: Self.projectBlob, blobs: [])
            ]),
            (folder: "02B", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob])
            ])
        ])

        let result = try await makeViewModel().scanProject(at: bundle)
        let library = try XCTUnwrap(result.bundle)
        XCTAssertEqual(library.events.count, 2)
        XCTAssertEqual(library.projectCount, 3)
        XCTAssertEqual(Set(library.allProjects.map(\.id)), ["01A/R1", "01A/R2", "02B/R1"])
    }

    func testEmptyProjectAloneBlocksDisable() async throws {
        let used = try makePlugin(named: "Sample Plugin")
        let unused = try makePlugin(named: "另一个插件")
        let bundle = try makeBundle(events: [
            (folder: "01A", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob]),
                (folder: "R2", nameBlob: Self.projectBlob, blobs: [])
            ])
        ])

        let viewModel = makeViewModel()
        viewModel.plugins = [used, unused]
        _ = try await viewModel.scanProject(at: bundle)

        // 只看空工程：没有引用，不能给出「未使用」清单
        viewModel.toggleBundleProject("01A/R1")
        XCTAssertEqual(viewModel.projectScan?.bundle?.wholeLibrary, false)
        XCTAssertEqual(viewModel.projectScan?.bundle?.selectedProjectIDs, ["01A/R2"])
        XCTAssertNotNil(viewModel.projectScan?.warning)
        XCTAssertFalse(viewModel.projectScan?.parsed ?? true)
        XCTAssertTrue(viewModel.projectUnusedCandidates().isEmpty)
    }

    func testMissingDisplayNameFallsBackToFolderName() async throws {
        let bundle = try makeBundle(events: [
            (folder: "01Event", nameBlob: Self.noNameBlob, projects: [
                (folder: "R1", nameBlob: Self.noNameBlob, blobs: [Self.effectBlob])
            ])
        ])

        let result = try await makeViewModel().scanProject(at: bundle)
        let library = try XCTUnwrap(result.bundle)
        XCTAssertEqual(library.events[0].name, "01Event", "没有 displayName 时退回目录名")
        XCTAssertEqual(library.events[0].projects[0].name, "R1")
        XCTAssertNil(library.events[0].warning)
    }

    func testCorruptLibraryIsRejectedWithReadableMessage() async throws {
        let bundle = root.appendingPathComponent("坏库.fcpbundle", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "这不是数据库".write(
            to: bundle.appendingPathComponent("CurrentVersion.flexolibrary"),
            atomically: true,
            encoding: .utf8
        )
        try "<?xml version=\"1.0\"?><plist><dict><key>catalogVersion</key><string>1193; 12.3</string></dict></plist>"
            .write(to: bundle.appendingPathComponent("CurrentVersion.plist"), atomically: true, encoding: .utf8)

        do {
            _ = try await makeViewModel().scanProject(at: bundle)
            XCTFail("损坏的库必须报错，不能输出猜测清单")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(message.contains("读不懂"), "错误文案要明确说明读不懂，实际是 \(message)")
            XCTAssertTrue(message.contains("导出 XML"), "应给出 XML 兜底")
        }
    }

    func testScanDoesNotModifyOriginalLibrary() async throws {
        let bundle = try makeBundle(events: [
            (folder: "01A", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob])
            ])
        ])
        let watched = [
            bundle.appendingPathComponent("CurrentVersion.flexolibrary"),
            bundle.appendingPathComponent("01A/CurrentVersion.fcpevent"),
            bundle.appendingPathComponent("01A/R1/CurrentVersion.fcpevent")
        ]
        let before = try watched.map { url -> (Date, UInt64) in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (values.contentModificationDate ?? .distantPast, UInt64(values.fileSize ?? 0))
        }

        _ = try await makeViewModel().scanProject(at: bundle)

        for (index, url) in watched.enumerated() {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            XCTAssertEqual(values.contentModificationDate, before[index].0, "\(url.lastPathComponent) 的修改时间不能变")
            XCTAssertEqual(UInt64(values.fileSize ?? 0), before[index].1, "\(url.lastPathComponent) 不能被写入")
        }
    }

    // MARK: - scan-project（命令行预演 / 执行）

    /// 预演只读：插件和库都不能被动，也不产生批次记录
    func testScanPreviewLeavesPluginAndLibraryUntouched() async throws {
        let used = try makePlugin(named: "Sample Plugin")
        let unused = try makePlugin(named: "没被用到的插件")
        let bundle = try makeBundle(events: [
            (folder: "01A", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob])
            ])
        ])

        let viewModel = makeViewModel()
        viewModel.plugins = [used, unused]
        _ = try await viewModel.scanProject(at: bundle)

        XCTAssertEqual(viewModel.projectUnusedCandidates().map(\.name), [unused.name])
        XCTAssertTrue(fm.fileExists(atPath: unused.path), "预演不能移动插件")
        XCTAssertTrue(fm.fileExists(atPath: used.path), "用到的插件更不能动")
        XCTAssertTrue(viewModel.projectBatches.isEmpty, "预演不能写批次记录")
    }

    /// --yes 真正执行：写入批次记录，并且能按批次恢复
    func testDisableUnusedWritesBatchAndRestores() async throws {
        let used = try makePlugin(named: "Sample Plugin")
        let unused = try makePlugin(named: "没被用到的插件")
        let bundle = try makeBundle(events: [
            (folder: "01A", nameBlob: Self.eventBlob, projects: [
                (folder: "R1", nameBlob: Self.projectBlob, blobs: [Self.effectBlob])
            ])
        ])

        let viewModel = makeViewModel()
        viewModel.plugins = [used, unused]
        _ = try await viewModel.scanProject(at: bundle)

        let summary = await viewModel.disableProjectUnused()
        XCTAssertEqual(summary.disabled.map(\.name), [unused.name])
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: unused.path), "未使用的插件应被停用")
        XCTAssertTrue(fm.fileExists(atPath: used.path), "用到的插件不能被停用")

        let batch = try XCTUnwrap(summary.batch, "停用后必须记入批次")
        XCTAssertEqual(batch.projectPath, bundle.path)
        XCTAssertEqual(batch.entries.map(\.pluginName), [unused.name])
        XCTAssertEqual(batch.pendingCount, 1)

        // 换一个实例读盘，确认批次真的落盘了
        let reopened = makeViewModel()
        let stored = try XCTUnwrap(reopened.projectBatches.first { $0.id == batch.id })
        XCTAssertEqual(stored.pendingCount, 1)

        let outcome = await reopened.restoreProjectBatch(stored.id)
        XCTAssertEqual(outcome.restored, [unused.name])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: unused.path), "恢复后插件必须回到原位置")
    }
}
