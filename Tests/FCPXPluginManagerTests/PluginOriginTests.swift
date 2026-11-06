import XCTest
@testable import FCPXPluginManager

/// 插件来源判断回归测试。
/// 规则：来源看「谁做的」（包标识 / 签名），安装位置只决定要不要管理员授权。
/// 全部使用临时目录，不读真实插件目录。
@MainActor
final class PluginOriginTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("FCPPluginOriginTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fm.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    private func makePlugin(
        named name: String,
        source: PluginSource,
        bundleIdentifier: String? = nil
    ) throws -> PluginItem {
        let dir = root
            .appendingPathComponent("Templates.localized", isDirectory: true)
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
            </dict>
            </plist>
            """
            try plist.write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(PluginItem(path: dir.path, source: source))
    }

    private func makeViewModel() -> PluginViewModel {
        PluginViewModel(storageRootOverride: root.appendingPathComponent("Storage", isDirectory: true)) { _ in
            AdminRunResult(succeeded: false, message: "测试未注入管理员执行器")
        }
    }

    // MARK: - 1. Apple 标识排除

    func testAppleBundleIdentifierIsDetectedAndExcludedFromBatch() throws {
        let apple = try makePlugin(named: "Apple滤镜", source: .systemEffects, bundleIdentifier: "com.apple.filter.Test")
        let thirdParty = try makePlugin(named: "第三方滤镜", source: .userEffects, bundleIdentifier: "com.redgiant.test")

        XCTAssertEqual(apple.origin, .apple)
        XCTAssertEqual(thirdParty.origin, .thirdParty)

        let viewModel = makeViewModel()
        viewModel.plugins = [apple, thirdParty]

        let candidates = viewModel.batchDisableCandidates(in: .all)
        XCTAssertEqual(candidates.targets.map(\.path), [thirdParty.path], "Apple 自带不能进入一键禁用")
        XCTAssertEqual(candidates.skippedApple, 1)
    }

    // MARK: - 2. 第三方全局安装照样能停用

    func testThirdPartyInstalledForAllUsersCanBeDisabled() async throws {
        let global = try makePlugin(named: "第三方全局", source: .systemEffects, bundleIdentifier: "com.redgiant.test")
        XCTAssertTrue(global.isSystemLevel, "装在 /Library 下，写文件需要管理员授权")
        XCTAssertEqual(global.origin, .thirdParty, "来源仍是第三方，不能因为位置就叫系统插件")

        let viewModel = makeViewModel()
        viewModel.plugins = [global]
        XCTAssertTrue(viewModel.batchDisableCandidates(in: .all).targets.contains { $0.path == global.path })

        switch await viewModel.disablePlugin(global) {
        case .needAuthentication(let item, _):
            XCTAssertEqual(item.originalPath, global.path)
        case .disabled:
            XCTFail("所有用户安装的第三方插件不能被静默移动，应要求管理员授权")
        case .failure(let message):
            XCTFail("第三方全局插件应能停用（待授权），实际失败：\(message)")
        }
    }

    // MARK: - 3. 来源未知按第三方处理

    func testUnknownOriginParticipatesInBatchAndIsReportedAsUnknown() throws {
        let unknown = try makePlugin(named: "没有元数据的模板", source: .systemEffects)
        XCTAssertEqual(unknown.origin, .unknown, "读不到包标识也读不到签名，不能猜成 Apple")

        let viewModel = makeViewModel()
        viewModel.plugins = [unknown]
        let candidates = viewModel.batchDisableCandidates(in: .all)
        XCTAssertEqual(candidates.targets.map(\.path), [unknown.path], "来源未知按第三方处理，参与一键禁用")
        XCTAssertEqual(candidates.skippedApple, 0)
    }
}
