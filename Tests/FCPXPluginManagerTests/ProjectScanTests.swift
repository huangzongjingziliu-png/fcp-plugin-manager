import XCTest
@testable import FCPXPluginManager

/// 工程扫描 + 保护名单测试。
/// XML 样本按 Final Cut Pro 真实导出的 FCPXML 结构写：
/// 效果在 <resources> 里声明（id + name + uid），时间线用 ref 引用，
/// uid 可能是模板绝对路径（含百分号编码），也可能是 FxPlug:<包标识>。
/// 全部使用临时目录，不读真实插件目录。
@MainActor
final class ProjectScanTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPProjectScanTests-\(UUID().uuidString)", isDirectory: true)
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
        bundleIdentifier: String? = nil
    ) throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Motion Templates.localized", isDirectory: true)
            .appendingPathComponent(source.shortLocation, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "v1".write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        if let bundleIdentifier {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(bundleIdentifier)</string>
                <key>CFBundleShortVersionString</key>
                <string>2.3</string>
            </dict>
            </plist>
            """
            try plist.write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(PluginItem(path: dir.path, source: source))
    }

    private func makeViewModel() -> PluginViewModel {
        PluginViewModel(storageRootOverride: root) { _ in
            AdminRunResult(succeeded: false, message: "测试未注入管理员执行器")
        }
    }

    /// 真实结构：资源声明 effect，时间线上通过 effect 元素引用
    private func fcpxml(
        projectName: String,
        effects: [(name: String, uid: String)],
        extraUnknownEffects: [(name: String, uid: String)] = []
    ) -> String {
        var resources = ""
        var timeline = ""
        var index = 2
        for effect in effects + extraUnknownEffects {
            let escapedUID = effect.uid
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let escapedName = effect.name
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            resources += """
                    <effect id="r\(index)" name="\(escapedName)" uid="\(escapedUID)"/>
            """
            timeline += """
                                        <effect ref="r\(index)" name="\(escapedName)" uid="\(escapedUID)"/>
            """
            index += 1
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                <format id="r1" name="FFVideoFormat1080p25" frameDuration="100/2500s" width="1920" height="1080"/>
        \(resources)
            </resources>
            <library>
                <event name="测试事件">
                    <project name="\(projectName)">
                        <sequence format="r1" duration="120s" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <clip offset="0s" duration="60s" name="主片段">
                                    <video>
        \(timeline)
                                    </video>
                                </clip>
                                <title offset="0s" duration="30s" name="字幕">
                                    <text>你好</text>
                                </title>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
    }

    // MARK: - XML 解析

    func testParsesRealisticFCPXMLStructure() throws {
        let plugin = try makePlugin(named: "我的调色")
        let xml = fcpxml(
            projectName: "宣传片 V3",
            effects: [
                (name: "我的调色", uid: plugin.path + ".moef"),
                (name: "Basic Title", uid: "/Library/Application Support/Final Cut Pro/Templates.localized/Titles.localized/Basic Title.localized/Basic Title.moti")
            ]
        )
        let url = root.appendingPathComponent("宣传片.fcpxml")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let scanned = try FCPProjectScanner.scan(url: url)
        XCTAssertEqual(scanned.references.projectName, "宣传片 V3")
        XCTAssertTrue(scanned.references.uids.contains(plugin.path + ".moef"))
        XCTAssertTrue(scanned.references.names.contains("我的调色"))
        XCTAssertEqual(scanned.references.count, 4, "两个资源 + 两个时间线引用，按集合去重后 uid 2 个、name 2 个")
    }

    func testPercentEncodedUIDIsDecoded() throws {
        let plugin = try makePlugin(named: "中文 效果")
        let encoded = URL(fileURLWithPath: plugin.path).absoluteString
        XCTAssertTrue(encoded.contains("%"), "样本应当带百分号编码，才能验证解码")
        let xml = fcpxml(projectName: "编码测试", effects: [(name: "中文 效果", uid: encoded)])
        let url = root.appendingPathComponent("encoded.fcpxml")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let scanned = try FCPProjectScanner.scan(url: url)
        XCTAssertTrue(
            scanned.references.uids.contains { $0.contains("中文 效果") },
            "uid 应当已经百分号解码，实际是 \(scanned.references.uids)"
        )
    }

    func testEmptyProjectReturnsNoReferences() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                <format id="r1" name="FFVideoFormat1080p25" frameDuration="100/2500s" width="1920" height="1080"/>
            </resources>
            <library>
                <event name="空工程">
                    <project name="纯剪辑无效果">
                        <sequence format="r1" duration="10s">
                            <spine>
                                <clip offset="0s" duration="10s"><video/></clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
        let url = root.appendingPathComponent("empty.fcpxml")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let scanned = try FCPProjectScanner.scan(url: url)
        XCTAssertTrue(scanned.references.isEmpty)
        XCTAssertEqual(scanned.references.projectName, "纯剪辑无效果")
    }

    // MARK: - 匹配

    func testMatchesPluginByAbsolutePathUID() throws {
        let plugin = try makePlugin(named: "路径匹配")
        let references = FCPProjectReferences(uids: [plugin.path + ".moef"])
        XCTAssertTrue(PluginMatcher.isUsed(plugin, references: references))
    }

    func testMatchesPluginByFxPlugBundleIdentifier() throws {
        let plugin = try makePlugin(
            named: "厂商特效",
            source: .userPlugIns,
            bundleIdentifier: "com.vendor.supereffect"
        )
        let references = FCPProjectReferences(uids: ["FxPlug:com.vendor.supereffect"])
        XCTAssertTrue(PluginMatcher.isUsed(plugin, references: references))
    }

    func testMatchesPluginByNameWhenUIDHasNoPath() throws {
        let plugin = try makePlugin(named: "名字匹配")
        let references = FCPProjectReferences(uids: ["名字匹配.moef"], names: [])
        XCTAssertTrue(PluginMatcher.isUsed(plugin, references: references))

        let nameOnly = FCPProjectReferences(uids: [], names: ["名字匹配"])
        XCTAssertTrue(PluginMatcher.isUsed(plugin, references: nameOnly))
    }

    func testDoesNotMatchDifferentPlugin() throws {
        let plugin = try makePlugin(named: "调色A")
        let references = FCPProjectReferences(uids: ["/somewhere/调色B.moef"], names: ["调色B"])
        XCTAssertFalse(PluginMatcher.isUsed(plugin, references: references))
    }

    func testUnmatchedReferencesAreReported() throws {
        let plugin = try makePlugin(named: "已安装效果")
        let references = FCPProjectReferences(
            uids: [plugin.path + ".moef", "/other/machine/缺失效果.moef"],
            names: []
        )
        let unmatched = PluginMatcher.unmatchedReferences(references, plugins: [plugin])
        XCTAssertEqual(unmatched, ["缺失效果"])
    }

    func testNormalizeStripsKnownExtensions() {
        XCTAssertEqual(PluginMatcher.normalize("Effects.localized"), "effects")
        XCTAssertEqual(PluginMatcher.normalize("Basic Title.localized/Basic Title.moti"), "basic title/basic title")
        XCTAssertEqual(PluginMatcher.lastComponent(".../Titles.localized/Basic Title.moti"), "basic title")
    }

    // MARK: - .fcpbundle 只读尽力解析

    func testBundleWithoutXMLThrowsNeedsExport() throws {
        let bundle = root.appendingPathComponent("没有XML.fcpbundle", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Event.fcpevent", isDirectory: true),
                               withIntermediateDirectories: true)
        try "not xml".write(to: bundle.appendingPathComponent("Event.fcpevent/notes.txt"),
                            atomically: true, encoding: .utf8)

        do {
            _ = try FCPProjectScanner.scan(url: bundle)
            XCTFail("没有 XML 时应该要求用户导出")
        } catch let error as ProjectScanError {
            guard case .needsExport = error else {
                return XCTFail("应抛出 needsExport，实际是 \(error)")
            }
        }
    }

    func testBundleWithEmbeddedXMLIsParsed() throws {
        let plugin = try makePlugin(named: "包内效果")
        let bundle = root.appendingPathComponent("带XML.fcpbundle", isDirectory: true)
        let event = bundle.appendingPathComponent("Event.fcpevent", isDirectory: true)
        try fm.createDirectory(at: event, withIntermediateDirectories: true)
        let xml = fcpxml(projectName: "包内工程", effects: [(name: "包内效果", uid: plugin.path + ".moef")])
        try xml.write(to: event.appendingPathComponent("CurrentVersion.fcpxml"), atomically: true, encoding: .utf8)

        let scanned = try FCPProjectScanner.scan(url: bundle)
        XCTAssertEqual(scanned.references.projectName, "包内工程")
        XCTAssertFalse(scanned.references.isEmpty)
    }

    func testUnsupportedFileTypeThrows() throws {
        let url = root.appendingPathComponent("随便.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        do {
            _ = try FCPProjectScanner.scan(url: url)
            XCTFail("不支持的类型应该报错")
        } catch let error as ProjectScanError {
            guard case .unsupportedType = error else {
                return XCTFail("应抛出 unsupportedType，实际是 \(error)")
            }
        }
    }

    // MARK: - 工程扫描 → 保护名单

    func testScanProjectProtectsUsedPluginsAndListsUnused() async throws {
        let used = try makePlugin(named: "工程在用")
        let unused = try makePlugin(named: "工程没用")
        let appleUnused = try makePlugin(named: "Apple没用", source: .systemEffects, bundleIdentifier: "com.apple.filter.Test")
        let thirdPartyGlobal = try makePlugin(named: "第三方全局", source: .systemEffects, bundleIdentifier: "com.redgiant.test")

        let viewModel = makeViewModel()
        viewModel.plugins = [used, unused, appleUnused, thirdPartyGlobal]

        let url = root.appendingPathComponent("工程.fcpxml")
        try fcpxml(projectName: "我的工程", effects: [(name: "工程在用", uid: used.path + ".moef")])
            .write(to: url, atomically: true, encoding: .utf8)

        let result = try await viewModel.scanProject(at: url)
        XCTAssertTrue(result.parsed)
        XCTAssertEqual(result.projectName, "我的工程")
        XCTAssertEqual(result.usedPaths, [used.path])
        XCTAssertEqual(viewModel.projectProtectedPaths, [used.path])

        XCTAssertTrue(viewModel.isProtected(used))
        XCTAssertFalse(viewModel.isProtected(unused))

        let candidates = viewModel.projectUnusedCandidates()
        XCTAssertEqual(
            Set(candidates.map(\.path)),
            [unused.path, thirdPartyGlobal.path],
            "只跳过 Apple 自带；第三方不论装在哪都参与，工程在用的自动保护"
        )

        let withApple = viewModel.projectUnusedCandidates(includeApple: true)
        XCTAssertEqual(
            Set(withApple.map(\.path)),
            [unused.path, thirdPartyGlobal.path, appleUnused.path]
        )
    }

    func testScanProjectWithNoReferencesGivesWarningAndDoesNotProtectAnything() async throws {
        let plugin = try makePlugin(named: "不该被保护")
        let viewModel = makeViewModel()
        viewModel.plugins = [plugin]

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                <format id="r1" name="FFVideoFormat1080p25" frameDuration="100/2500s"/>
            </resources>
            <library><event name="e"><project name="空工程"><sequence format="r1"><spine/></sequence></project></event></library>
        </fcpxml>
        """
        let url = root.appendingPathComponent("空.fcpxml")
        try xml.write(to: url, atomically: true, encoding: .utf8)

        let result = try await viewModel.scanProject(at: url)
        XCTAssertFalse(result.parsed)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(viewModel.projectProtectedPaths.isEmpty)
        XCTAssertTrue(viewModel.projectUnusedCandidates().isEmpty, "没解析出来时不能给出「未使用清单」")
    }

    // MARK: - 保护名单与批量候选

    func testBatchCandidatesSkipAppleAndProtectedByDefault() throws {
        let user = try makePlugin(named: "用户插件")
        let favorite = try makePlugin(named: "收藏插件")
        let apple = try makePlugin(named: "Apple插件", source: .systemEffects, bundleIdentifier: "com.apple.filter.Test")
        let thirdPartyGlobal = try makePlugin(named: "第三方全局", source: .systemEffects, bundleIdentifier: "com.redgiant.test")

        let viewModel = makeViewModel()
        viewModel.plugins = [user, favorite, apple, thirdPartyGlobal]
        viewModel.favorites = [favorite.path]

        let defaultCandidates = viewModel.batchDisableCandidates(in: .all)
        XCTAssertEqual(Set(defaultCandidates.targets.map(\.path)), [user.path, thirdPartyGlobal.path])
        XCTAssertEqual(defaultCandidates.skippedApple, 1)
        XCTAssertEqual(defaultCandidates.skippedProtected, 1)

        let withApple = viewModel.batchDisableCandidates(in: .all, includeApple: true)
        XCTAssertEqual(Set(withApple.targets.map(\.path)), [user.path, apple.path, thirdPartyGlobal.path])
        XCTAssertEqual(withApple.skippedProtected, 1)
    }

    func testScanningAnotherProjectReplacesProjectProtection() async throws {
        let first = try makePlugin(named: "工程A效果")
        let second = try makePlugin(named: "工程B效果")
        let viewModel = makeViewModel()
        viewModel.plugins = [first, second]

        let urlA = root.appendingPathComponent("A.fcpxml")
        try fcpxml(projectName: "工程A", effects: [(name: "工程A效果", uid: first.path + ".moef")])
            .write(to: urlA, atomically: true, encoding: .utf8)
        _ = try await viewModel.scanProject(at: urlA)
        XCTAssertEqual(viewModel.projectProtectedPaths, [first.path])

        let urlB = root.appendingPathComponent("B.fcpxml")
        try fcpxml(projectName: "工程B", effects: [(name: "工程B效果", uid: second.path + ".moef")])
            .write(to: urlB, atomically: true, encoding: .utf8)
        _ = try await viewModel.scanProject(at: urlB)
        XCTAssertEqual(viewModel.projectProtectedPaths, [second.path], "保护名单应跟随当前工程，不累积旧工程")
        XCTAssertTrue(viewModel.projectUnusedCandidates().contains { $0.path == first.path })
    }

    func testFavoritePersistsAcrossViewModelInstances() throws {
        let plugin = try makePlugin(named: "要记住的收藏")
        let first = makeViewModel()
        first.plugins = [plugin]
        first.toggleFavorite(plugin)
        XCTAssertTrue(first.isFavorite(plugin))

        let second = makeViewModel()
        XCTAssertTrue(second.isFavorite(plugin), "收藏应写入 Protection/protection.json 并在下次启动恢复")
    }

    func testClearProjectScanReleasesProjectProtection() async throws {
        let used = try makePlugin(named: "临时工程在用")
        let viewModel = makeViewModel()
        viewModel.plugins = [used]

        let url = root.appendingPathComponent("临时.fcpxml")
        try fcpxml(projectName: "临时工程", effects: [(name: "临时工程在用", uid: used.path + ".moef")])
            .write(to: url, atomically: true, encoding: .utf8)
        _ = try await viewModel.scanProject(at: url)
        XCTAssertTrue(viewModel.isProjectProtected(used))

        viewModel.clearProjectScan()
        XCTAssertNil(viewModel.projectScan)
        XCTAssertFalse(viewModel.isProjectProtected(used))
        XCTAssertTrue(
            viewModel.batchDisableCandidates(in: .all).targets.contains { $0.path == used.path },
            "清空工程扫描后，这个插件应重新回到可批量停用的候选里"
        )
    }
}
