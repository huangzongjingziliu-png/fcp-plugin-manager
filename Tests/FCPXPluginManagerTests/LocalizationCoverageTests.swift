import XCTest
import Foundation
@testable import FCPXPluginManager

/// 本地化自动检查。
///
/// 以中文原文为 key 的做法有个天然坑：查不到英文时会静默回退成中文，
/// 界面看起来「有字」，但英文模式里混着中文。这里直接扫源码兜住：
/// 1) 所有 `T("…")` 的 key 都必须在英文表里；
/// 2) 英文值不能再含中文；
/// 3) 中英文占位符数量必须一致（否则参数会错位）；
/// 4) 界面常用的 Text/Button/Label/help 等不能直接写中文字面量。
///
/// CLI（CLIRunner.swift）是单独的命令行入口，不随界面切语言，不做检查。
final class LocalizationCoverageTests: XCTestCase {

    private static let sourceDirectory: URL = {
        // #filePath 指向本文件，向上一级是测试目录，再上两级是包根目录
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FCPXPluginManager", isDirectory: true)
    }()

    private static let excludedFiles: Set<String> = ["Localization.swift", "CLIRunner.swift"]

    private static var sourceFiles: [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter {
            $0.pathExtension == "swift" && !excludedFiles.contains($0.lastPathComponent)
        }
    }

    private static let cjk = try! NSRegularExpression(pattern: "[\\u4e00-\\u9fff]")

    private func containsCJK(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.cjk.firstMatch(in: text, range: range) != nil
    }

    /// 把源码里的字面量内容还原成运行时的字符串（处理 \n、\" 等转义）
    private static func decode(_ raw: String) -> String {
        var result = ""
        let iterator = Array(raw)
        var i = 0
        while i < iterator.count {
            if iterator[i] == "\\", i + 1 < iterator.count {
                let next = iterator[i + 1]
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(next)
                }
                i += 2
            } else {
                result.append(iterator[i])
                i += 1
            }
        }
        return result
    }

    /// 抽出所有 `T("…")` 里紧跟左括号的第一个字符串字面量
    private func tKeys(in source: String) -> [(line: Int, raw: String)] {
        let pattern = #"\bT\(\s*"((?:[^"\\]|\\.)*)""#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            let raw = ns.substring(with: match.range(at: 1))
            let line = source.prefix(upTo: source.index(source.startIndex, offsetBy: match.range.location))
                .filter { $0 == "\n" }.count + 1
            return (line, raw)
        }
    }

    private func placeholderCount(_ text: String) -> Int {
        ["%@", "%lld", "%d"].reduce(0) { count, token in
            count + text.components(separatedBy: token).count - 1
        }
    }

    // MARK: - 1. 所有 T() 都有英文条目

    func testEveryTLiteralHasEnglishTranslation() {
        var missing: [String] = []
        for file in Self.sourceFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for key in tKeys(in: source) {
                let text = Self.decode(key.raw)
                guard containsCJK(text) else { continue }
                if Localization.englishText(for: text) == nil {
                    missing.append("\(file.lastPathComponent):\(key.line)  \(text)")
                }
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "以下界面文案缺少英文翻译，请在 Localization.swift 的 english 表里补上：\n" + missing.joined(separator: "\n")
        )
    }

    // MARK: - 2. 英文里不能残留中文

    func testEnglishValuesContainNoChinese() {
        var polluted: [String] = []
        for file in Self.sourceFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for key in tKeys(in: source) {
                let text = Self.decode(key.raw)
                guard containsCJK(text), let english = Localization.englishText(for: text) else { continue }
                if containsCJK(english) {
                    polluted.append("\(file.lastPathComponent):\(key.line)  \(text)  →  \(english)")
                }
            }
        }
        XCTAssertTrue(polluted.isEmpty, "英文翻译里残留中文：\n" + polluted.joined(separator: "\n"))
    }

    // MARK: - 3. 占位符数量一致

    func testPlaceholderCountsMatch() {
        var mismatched: [String] = []
        for file in Self.sourceFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for key in tKeys(in: source) {
                let text = Self.decode(key.raw)
                guard let english = Localization.englishText(for: text) else { continue }
                let expected = placeholderCount(text)
                let actual = placeholderCount(english)
                if expected != actual {
                    mismatched.append("\(file.lastPathComponent):\(key.line)  中文 \(expected) 个 / 英文 \(actual) 个：\(text) → \(english)")
                }
            }
        }
        XCTAssertTrue(mismatched.isEmpty, "中英文占位符数量不一致，参数会错位：\n" + mismatched.joined(separator: "\n"))
    }

    // MARK: - 4. 界面控件不能直接写中文字面量

    func testNoDirectChineseLiteralsInUIBuilders() {
        // 容易直接写中文的界面入口；命中就说明忘了套 T()
        let pattern = #"\b(Text|Button|Label|TextField|help|navigationTitle|alert)\(\s*(Text\(\s*)?"((?:[^"\\]|\\.)*)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        var offenders: [String] = []

        for file in Self.sourceFiles {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = source as NSString
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: match.range(at: 3))
                guard containsCJK(Self.decode(raw)) else { continue }
                let line = source.prefix(upTo: source.index(source.startIndex, offsetBy: match.range.location))
                    .filter { $0 == "\n" }.count + 1
                offenders.append("\(file.lastPathComponent):\(line)  \(Self.decode(raw))")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "这些界面文案没有走 T()，英文模式下会残留中文：\n" + offenders.joined(separator: "\n")
        )
    }
}
