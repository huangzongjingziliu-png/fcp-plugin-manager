import XCTest
@testable import FCPXPluginManager

/// 命令行工具面板与版本号：界面示例必须与真实 CLI 一致，版本号格式必须可被脚本解析。
@MainActor
final class CLIToolTests: XCTestCase {
    func testAppVersionIsSemver() {
        let parts = AppInfo.version.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "版本号应为 主.次.修订，实际：\(AppInfo.version)")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && Int($0) != nil },
                      "版本号每段都必须是数字，实际：\(AppInfo.version)")
    }

    func testEveryExampleStartsWithCLIFlag() {
        for command in CLIToolSheet.examples {
            XCTAssertTrue(command.hasPrefix("fcpplugin --cli "),
                          "示例必须带 --cli，否则会启动图形界面：\(command)")
        }
    }

    func testExamplesCoverRequiredCommands() {
        let examples = CLIToolSheet.examples
        XCTAssertTrue(examples.contains("fcpplugin --cli list --json"))
        XCTAssertTrue(examples.contains("fcpplugin --cli list --category transitions"))
        XCTAssertTrue(examples.contains(where: { $0.hasPrefix("fcpplugin --cli disable --path") }))
        XCTAssertTrue(examples.contains("fcpplugin --cli enable --all --yes"))
        XCTAssertTrue(examples.contains(where: { $0.contains(" --cli scan-project --path ") }))
    }

    func testMissingBinaryIsReportedAsNotInstalled() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("不存在的-fcpplugin-\(UUID().uuidString)")
        let status = await CLIToolStatus.detect(at: missing)
        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.versionMatches)
        XCTAssertNil(status.reportedVersion)
    }
}
