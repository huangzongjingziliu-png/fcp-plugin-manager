import Foundation

/// 版本号单一来源：`Scripts/build_app.sh` 会从这里读取并写进 Info.plist，
/// 命令行的 `--version` 也用它，保证 App 与 CLI 报的一致。
enum AppInfo {
    static let version = "1.6.8"
}
