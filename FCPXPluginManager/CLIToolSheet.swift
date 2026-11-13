import SwiftUI
import AppKit

/// CLI 的安装位置（~/bin/fcpplugin）。放成文件级常量，避免主线程隔离限制。
private let cliInstallURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("bin/fcpplugin")

/// 「命令行工具…」面板：告诉用户 App 内置了 CLI，检查安装状态，并给出常用命令。
struct CLIToolSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var status = CLIToolStatus()
    @State private var isChecking = true
    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection
                    pathSection
                    examplesSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        .task { await refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(T("命令行工具"))
                    .font(.system(size: 17, weight: .semibold))
                Text(T("同一个 App 内置的命令行，供脚本或 AI agent 调用，不需要另外安装。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("当前状态"))
                .font(.system(size: 13, weight: .semibold))

            statusRow(
                ok: status.installed,
                title: status.installed
                    ? T("已安装：~/bin/fcpplugin")
                    : T("尚未安装到 ~/bin/fcpplugin"),
                detail: status.installed
                    ? (status.versionMatches
                        ? T("版本 %@，与 App 一致", AppInfo.version)
                        : T("版本不一致（%@），建议重新安装", status.reportedVersion ?? T("未知")))
                    : nil
            )

            statusRow(
                ok: status.onPath,
                title: status.onPath
                    ? T("~/bin 已在 PATH 中")
                    : T("~/bin 不在 PATH 中，需要手动加一行"),
                detail: nil
            )

            HStack(spacing: 10) {
                Button {
                    Task { await install() }
                } label: {
                    Text(status.installed && status.versionMatches
                         ? T("已是最新版本")
                         : T("一键安装到 ~/bin"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling || (status.installed && status.versionMatches))

                if isInstalling {
                    ProgressView().controlSize(.small)
                }
                if let message = installMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func statusRow(ok: Bool, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("PATH 设置"))
                .font(.system(size: 13, weight: .semibold))
            Text(T("把这一行加到 ~/.zshrc 末尾，然后重开终端（本工具不会自动改写你的 shell 配置）："))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            codeRow(
                id: "path",
                text: #"export PATH="$HOME/bin:$PATH""#,
                copyLabel: T("复制")
            )
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("常用命令"))
                .font(.system(size: 13, weight: .semibold))
            Text(T("每条都可以直接粘贴到终端；一定要带 --cli，否则会启动图形界面。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.examples, id: \.self) { command in
                    codeRow(id: command, text: command, copyLabel: T("复制"))
                }
            }
        }
    }

    private func codeRow(id: String, text: String, copyLabel: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copiedID = id
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if copiedID == id { copiedID = nil }
                }
            } label: {
                Text(copiedID == id ? T("已复制") : copyLabel)
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(T("改文件的命令默认只预演，加 --yes 才执行；系统级插件只输出 sudo 命令，不自行提权。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(T("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    /// 面板里展示的命令示例。所有示例都必须带 --cli，否则会启动图形界面。
    static let examples: [String] = [
        "fcpplugin --cli list --json",
        "fcpplugin --cli list --category transitions",
        #"fcpplugin --cli disable --path "<插件名或路径>""#,
        "fcpplugin --cli enable --all --yes",
        #"fcpplugin --cli scan-project --path "~/Movies/Project.fcpxml""#,
        #"fcpplugin --cli scan-project --path "~/Movies/Library.fcpbundle" --json"#
    ]

    @MainActor
    private func refresh() async {
        isChecking = true
        status = await CLIToolStatus.detect(at: cliInstallURL)
        isChecking = false
    }

    @MainActor
    private func install() async {
        isInstalling = true
        installMessage = nil
        defer { isInstalling = false }

        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let binary = Bundle.main.executableURL else {
                return T("找不到 App 主程序")
            }
            let fm = FileManager.default
            let directory = cliInstallURL.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: cliInstallURL.path) {
                    try fm.removeItem(at: cliInstallURL)
                }
                try fm.copyItem(at: binary, to: cliInstallURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliInstallURL.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let result {
            installMessage = T("安装失败：%@", result)
        } else {
            installMessage = T("已安装到 ~/bin/fcpplugin")
        }
        status = await CLIToolStatus.detect(at: cliInstallURL)
    }
}

/// CLI 安装状态：只读检测，不改任何文件。
struct CLIToolStatus {
    var installed = false
    var versionMatches = false
    var onPath = false
    var reportedVersion: String?

    static func detect(at url: URL) async -> CLIToolStatus {
        await Task.detached(priority: .userInitiated) { () -> CLIToolStatus in
            var status = CLIToolStatus()
            let fm = FileManager.default
            status.installed = fm.isExecutableFile(atPath: url.path)

            if status.installed {
                status.reportedVersion = runVersion(at: url)
                status.versionMatches = status.reportedVersion == AppInfo.version
            }
            status.onPath = shellPathContainsUserBin()
            return status
        }.value
    }

    /// 运行 `fcpplugin --cli --version`，读回版本号
    private static func runVersion(at url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--cli", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        } catch {
            return nil
        }
    }

    /// 判断 ~/bin 是否已经在 PATH：先看当前进程，再读常见 shell 配置。
    /// 只读，不改写任何配置。
    private static func shellPathContainsUserBin() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userBin = "\(home)/bin"

        if let path = ProcessInfo.processInfo.environment["PATH"],
           path.split(separator: ":").contains(where: { $0 == userBin || $0 == "~/bin" }) {
            return true
        }

        let configs = [".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".profile"]
        for name in configs {
            let file = URL(fileURLWithPath: home).appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                guard line.contains("PATH") else { continue }
                if line.contains("$HOME/bin") || line.contains("${HOME}/bin")
                    || line.contains(userBin) || line.contains("~/bin") {
                    return true
                }
            }
        }
        return false
    }
}
